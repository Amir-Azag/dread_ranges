#!/bin/bash
exec 3>&1 4>&2

# UTC timestamp functie
time_stamp() { TZ=UTC date '+%Y-%m-%dT%H:%M:%SZ'; }

# Logging functies
log_info() { printf '[%s][%s] %s\n' "$(basename "$0")" "$(time_stamp)" "$*" >&3; }
log_error() { printf '[%s][%s] ERROR: %s\n' "$(basename "$0")" "$(time_stamp)" "$*" >&4; }

# Solaris platform niet ondersteund
uname | grep -qi 'SunOS' && {
    log_error "Solaris is niet ondersteund. Script stopt."
    exit 99
}

# Maak unieke tijdelijke map
rand_suffix() { awk 'BEGIN{srand();print int(rand()*32768)}'; }
TMP_DIR="$(mktemp -d "/tmp/.dread.$$.$(rand_suffix).XXXXXX")" || exit 1
[ -d "$TMP_DIR" ] || exit 1

# Opruimen bij afsluiten
cleanup() { rm -rf -- "$TMP_DIR"; }
trap 'cleanup' EXIT HUP INT QUIT TERM

# DNS resolutie check
check_dns() {
    getent hosts "$1" >/dev/null 2>&1 && return 0
    host "$1" >/dev/null 2>&1 && return 0
    return 1
}

# Algemene JSON IP range fetcher met retry
fetch_json_ips() {
    url="$1"
    output="$2"
    desc="$3"
    for attempt in 1 2 3; do
        curl -s --fail --max-time 10 "$url" -o "$TMP_DIR/response.json" && break
        sleep $((5 * attempt))
    done
    if [ ! -s "$TMP_DIR/response.json" ]; then
        log_error "Ophalen $desc mislukt."
        return 1
    fi
    if ! jq -e . "$TMP_DIR/response.json" >/dev/null 2>&1; then
        log_error "Ongeldige JSON voor $desc."
        return 1
    fi
    jq -r '.. | strings | select(test("^[0-9./]+$"))' "$TMP_DIR/response.json" | grep -v ':' | sort -Vu | grep "/" > "$output"
}

# Specifieke providers fetchers
fetch_cloudflare() {
    check_dns api.cloudflare.com || { log_error "Cloudflare DNS faal"; return; }
    log_info "Ophalen Cloudflare IP ranges..."
    curl -s --fail --max-time 10 "https://api.cloudflare.com/client/v4/ips" -o "$TMP_DIR/cloudflare.json" || return
    if ! jq -e . "$TMP_DIR/cloudflare.json" >/dev/null 2>&1; then
        log_error "Ongeldige JSON Cloudflare"
        return
    fi
    jq -r '.result.ipv4_cidrs[]' "$TMP_DIR/cloudflare.json" | sort -Vu > dread_cloudflare.txt
}

fetch_google() {
    check_dns www.gstatic.com || { log_error "Google DNS faal"; return; }
    log_info "Ophalen Google IP ranges..."
    curl -s --fail --max-time 10 "https://www.gstatic.com/ipranges/cloud.json" -o "$TMP_DIR/google.json" || return
    if ! jq -e . "$TMP_DIR/google.json" >/dev/null 2>&1; then
        log_error "Ongeldige JSON Google"
        return
    fi
    jq -r '.prefixes[].ipv4Prefix' "$TMP_DIR/google.json" | sort -Vu > dread_google.txt
}

fetch_aws() {
    check_dns ip-ranges.amazonaws.com || { log_error "AWS DNS faal"; return; }
    log_info "Ophalen AWS IP ranges..."
    curl -s --fail --max-time 10 "https://ip-ranges.amazonaws.com/ip-ranges.json" -o "$TMP_DIR/aws.json" || return
    if ! jq -e . "$TMP_DIR/aws.json" >/dev/null 2>&1; then
        log_error "Ongeldige JSON AWS"
        return
    fi
    jq -r '.prefixes[].ip_prefix' "$TMP_DIR/aws.json" | grep -v ':' | sort -Vu > dread_aws.txt
}

fetch_scaleway() {
    check_dns www.scaleway.com || { log_error "Scaleway DNS faal"; return; }
    log_info "Ophalen Scaleway IP ranges..."
    curl -s --fail --max-time 10 "https://www.scaleway.com/en/docs/account/reference-content/scaleway-network-information/#ipv4" | \
        grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]+' | sort -Vu > dread_scaleway.txt
}

fetch_linode() {
    check_dns speedtest.newark.linode.com || { log_error "Linode DNS faal"; return; }
    log_info "Ophalen Linode IP ranges..."
    curl -s --fail --max-time 10 "https://geoip.linode.com/" | \
        grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]+' | sort -Vu > dread_linode.txt
}

fetch_oracle() {
    check_dns docs.oracle.com || { log_error "Oracle DNS faal"; return; }
    log_info "Ophalen Oracle IP ranges..."
    curl -s --fail --max-time 10 "https://docs.oracle.com/en-us/iaas/tools/public_ip_ranges.json" -o "$TMP_DIR/oracle.json" || return
    if ! jq -e . "$TMP_DIR/oracle.json" >/dev/null 2>&1; then
        log_error "Ongeldige JSON Oracle"
        return
    fi
    jq -r '.. | objects | .cidr? // empty' "$TMP_DIR/oracle.json" | grep -v ':' | sort -Vu > dread_oracle.txt
}

fetch_tor() {
    check_dns check.torproject.org || { log_error "Tor project DNS faal"; return; }
    log_info "Ophalen Tor IP ranges..."
    curl -s --fail --max-time 10 "https://check.torproject.org/exit-addresses" | \
        awk '/^ExitAddress/ {print $2}' | sort -Vu > dread_tor.txt
}

fetch_microsoft() {
    log_info "Ophalen Microsoft IP ranges..."
    for ID in 56519 57063 57064 57062; do
        PAGE="https://www.microsoft.com/en-us/download/details.aspx?id=$ID"
        curl -s --fail "$PAGE" | sed -nE 's/.*<a href=["'"'"']([^"'"'"']*ServiceTags_[^"'"'"']*\.json)["'"'"'].*/\1/p' | \
            head -1 | while read -r URL; do
                curl -s --fail --max-time 20 "$URL" -o "$TMP_DIR/ms.json"
                if ! jq -e . "$TMP_DIR/ms.json" >/dev/null 2>&1; then
                    log_error "Ongeldige JSON Microsoft"
                    continue
                fi
                jq -r '.values[].properties.addressPrefixes[]?' "$TMP_DIR/ms.json" | grep -v ':' >> "$TMP_DIR/ms-ipv4.txt"
            done
    done
    sort -Vu "$TMP_DIR/ms-ipv4.txt" > dread_microsoft.txt
}

# Main functie
main() {
    log_info "Start verwerking IP-ranges..."
    fetch_google
    fetch_cloudflare
    fetch_aws
    fetch_scaleway
    fetch_linode
    fetch_oracle
    fetch_tor
    fetch_microsoft
    log_info "IP-range verwerking voltooid."
}

main "$@"
