#!/bin/bash

# Improved IP range fetcher - Configuration-driven approach
# This version is much simpler and more maintainable

set -euo pipefail

# Configuration: Define providers and their endpoints
declare -A PROVIDERS=(
    ["aws"]="https://ip-ranges.amazonaws.com/ip-ranges.json"
    ["google"]="https://www.gstatic.com/ipranges/cloud.json"
    ["cloudflare"]="https://api.cloudflare.com/client/v4/ips"
    ["oracle"]="https://docs.oracle.com/en-us/iaas/tools/public_ip_ranges.json"
    ["microsoft"]="https://download.microsoft.com/download/7/1/D/71D86715-5596-4529-9B13-DA13A5DE5B63/ServiceTags_Public_20240930.json"
)

# JSON path expressions for each provider (jq expressions)
declare -A JSON_PATHS=(
    ["aws"]=".prefixes[].ip_prefix"
    ["google"]=".prefixes[].ipv4Prefix"
    ["cloudflare"]=".result.ipv4_cidrs[]"
    ["oracle"]=".. | objects | .cidr? // empty"
    ["microsoft"]=".values[].properties.addressPrefixes[]?"
)

# Alternative endpoints that don't use JSON
declare -A ALT_ENDPOINTS=(
    ["tor"]="https://check.torproject.org/exit-addresses"
    ["linode"]="https://geoip.linode.com/"
    ["scaleway"]="https://www.scaleway.com/en/docs/account/reference-content/scaleway-network-information/"
)

# Alternative parsers for non-JSON endpoints
declare -A ALT_PARSERS=(
    ["tor"]="awk '/^ExitAddress/ {print \$2}'"
    ["linode"]="grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]+'"
    ["scaleway"]="grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]+'"
)

# Global configuration
TMP_DIR=$(mktemp -d)
OUTPUT_DIR="."
TIMEOUT=30
MAX_RETRIES=3
VERBOSE=false
AGGREGATE=false
SELECTED_PROVIDERS=""

# Cleanup function
cleanup() {
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

# Logging functions
log_info() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] INFO: $*" >&2
}

log_error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2
}

log_debug() {
    [[ "$VERBOSE" == "true" ]] && echo "[$(date '+%Y-%m-%d %H:%M:%S')] DEBUG: $*" >&2
}

# Validate IP range format (basic validation)
is_valid_ip_range() {
    local range="$1"
    [[ "$range" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$ ]]
}

# Fetch with retry mechanism
fetch_with_retry() {
    local url="$1"
    local output="$2"
    local attempt=1
    
    while [[ $attempt -le $MAX_RETRIES ]]; do
        log_debug "Attempt $attempt to fetch: $url"
        if curl -s --fail --max-time "$TIMEOUT" "$url" -o "$output"; then
            return 0
        fi
        log_debug "Attempt $attempt failed, retrying..."
        sleep $((attempt * 2))
        ((attempt++))
    done
    return 1
}

# Fetch JSON-based provider
fetch_json_provider() {
    local provider="$1"
    local url="${PROVIDERS[$provider]}"
    local json_path="${JSON_PATHS[$provider]}"
    local output_file="$OUTPUT_DIR/dread_${provider}.txt"
    local temp_json="$TMP_DIR/${provider}.json"
    
    log_info "Fetching $provider IP ranges..."
    
    if ! fetch_with_retry "$url" "$temp_json"; then
        log_error "Failed to fetch $provider data after $MAX_RETRIES attempts"
        return 1
    fi
    
    # Validate JSON
    if ! jq -e . "$temp_json" >/dev/null 2>&1; then
        log_error "Invalid JSON received for $provider"
        return 1
    fi
    
    # Extract IP ranges using jq
    if ! jq -r "$json_path" "$temp_json" 2>/dev/null | \
         grep -v ':' | \
         grep '/' | \
         sort -u > "$output_file"; then
        log_error "Failed to parse IP ranges for $provider"
        return 1
    fi
    
    # Validate extracted ranges
    local valid_count=0
    local total_count=0
    while IFS= read -r range; do
        ((total_count++))
        if is_valid_ip_range "$range"; then
            ((valid_count++))
        else
            log_debug "Invalid IP range detected: $range"
        fi
    done < "$output_file"
    
    log_info "$provider: Extracted $valid_count valid ranges out of $total_count total"
    return 0
}

# Fetch alternative provider (non-JSON)
fetch_alt_provider() {
    local provider="$1"
    local url="${ALT_ENDPOINTS[$provider]}"
    local parser="${ALT_PARSERS[$provider]}"
    local output_file="$OUTPUT_DIR/dread_${provider}.txt"
    local temp_data="$TMP_DIR/${provider}.data"
    
    log_info "Fetching $provider IP ranges..."
    
    if ! fetch_with_retry "$url" "$temp_data"; then
        log_error "Failed to fetch $provider data after $MAX_RETRIES attempts"
        return 1
    fi
    
    # Parse using the specified parser
    if ! eval "$parser" < "$temp_data" | sort -u > "$output_file"; then
        log_error "Failed to parse IP ranges for $provider"
        return 1
    fi
    
    local count=$(wc -l < "$output_file")
    log_info "$provider: Extracted $count IP ranges"
    return 0
}

# Create aggregated output
create_aggregate() {
    local aggregate_file="$OUTPUT_DIR/dread_all_ranges.txt"
    log_info "Creating aggregated output..."
    
    cat "$OUTPUT_DIR"/dread_*.txt 2>/dev/null | \
        sort -u | \
        grep -E '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$' > "$aggregate_file"
    
    local total_count=$(wc -l < "$aggregate_file")
    log_info "Aggregated $total_count unique IP ranges from all providers"
}

# Show usage information
show_usage() {
    cat << EOF
Usage: $0 [OPTIONS] [PROVIDERS...]

Fetch IP ranges from cloud providers and infrastructure services.

OPTIONS:
    -h, --help          Show this help message
    -v, --verbose       Enable verbose output
    -a, --aggregate     Create aggregated output file with all ranges
    -o, --output DIR    Output directory (default: current directory)
    -t, --timeout SEC   Request timeout in seconds (default: 30)
    -r, --retries NUM   Max retry attempts (default: 3)
    --list-providers    List available providers

PROVIDERS:
    If no providers specified, all will be fetched.
    Available: $(printf '%s ' "${!PROVIDERS[@]}" "${!ALT_ENDPOINTS[@]}" | tr ' ' '\n' | sort | tr '\n' ' ')

EXAMPLES:
    $0                          # Fetch all providers
    $0 aws google               # Fetch only AWS and Google
    $0 -a -v cloudflare         # Fetch Cloudflare with verbose output and aggregation
    $0 --output /tmp --aggregate # Fetch all to /tmp and create aggregate

OUTPUT:
    Creates separate files: dread_PROVIDER.txt for each provider
    With --aggregate: also creates dread_all_ranges.txt
EOF
}

# List available providers
list_providers() {
    echo "JSON-based providers:"
    printf '  %s\n' "${!PROVIDERS[@]}" | sort
    echo
    echo "Alternative providers:"
    printf '  %s\n' "${!ALT_ENDPOINTS[@]}" | sort
}

# Parse command line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                show_usage
                exit 0
                ;;
            -v|--verbose)
                VERBOSE=true
                shift
                ;;
            -a|--aggregate)
                AGGREGATE=true
                shift
                ;;
            -o|--output)
                OUTPUT_DIR="$2"
                shift 2
                ;;
            -t|--timeout)
                TIMEOUT="$2"
                shift 2
                ;;
            -r|--retries)
                MAX_RETRIES="$2"
                shift 2
                ;;
            --list-providers)
                list_providers
                exit 0
                ;;
            -*)
                echo "Unknown option: $1" >&2
                show_usage >&2
                exit 1
                ;;
            *)
                SELECTED_PROVIDERS="$SELECTED_PROVIDERS $1"
                shift
                ;;
        esac
    done
}

# Main execution function
main() {
    parse_args "$@"
    
    # Create output directory if it doesn't exist
    mkdir -p "$OUTPUT_DIR"
    
    # Determine which providers to fetch
    local providers_to_fetch
    if [[ -n "$SELECTED_PROVIDERS" ]]; then
        providers_to_fetch="$SELECTED_PROVIDERS"
    else
        providers_to_fetch="$(printf '%s ' "${!PROVIDERS[@]}" "${!ALT_ENDPOINTS[@]}")"
    fi
    
    log_info "Starting IP range fetching process..."
    log_debug "Output directory: $OUTPUT_DIR"
    log_debug "Timeout: ${TIMEOUT}s, Max retries: $MAX_RETRIES"
    
    local success_count=0
    local total_count=0
    
    # Process each provider
    for provider in $providers_to_fetch; do
        ((total_count++))
        
        if [[ -n "${PROVIDERS[$provider]:-}" ]]; then
            # JSON-based provider
            if fetch_json_provider "$provider"; then
                ((success_count++))
            fi
        elif [[ -n "${ALT_ENDPOINTS[$provider]:-}" ]]; then
            # Alternative provider
            if fetch_alt_provider "$provider"; then
                ((success_count++))
            fi
        else
            log_error "Unknown provider: $provider"
        fi
    done
    
    # Create aggregate if requested
    [[ "$AGGREGATE" == "true" ]] && create_aggregate
    
    log_info "Process completed: $success_count/$total_count providers succeeded"
    
    # Summary
    echo
    echo "=== SUMMARY ==="
    for file in "$OUTPUT_DIR"/dread_*.txt; do
        if [[ -f "$file" ]]; then
            local count=$(wc -l < "$file")
            echo "$(basename "$file"): $count ranges"
        fi
    done
}

# Run main function if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi