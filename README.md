# dread_ranges

Instantly retrieve up-to-date IPv4 ranges from popular cloud providers (AWS, Google, Cloudflare, etc). Useful for network security, firewall whitelists, monitoring, and threat intelligence.

## Features

- **Configuration-driven**: Easy to add new providers
- **Command-line interface**: Flexible options and filtering
- **Aggregation**: Combine all ranges into a single file
- **Validation**: IP range format validation
- **Robust**: Retry mechanism and proper error handling
- **Modular**: Clean, maintainable code

## Usage

### Basic usage
```bash
# Fetch all providers
./dread_ranges_improved.sh

# Fetch specific providers
./dread_ranges_improved.sh aws google cloudflare

# Show help
./dread_ranges_improved.sh --help
```

### Advanced options
```bash
# Create aggregated output with verbose logging
./dread_ranges_improved.sh --aggregate --verbose

# Custom output directory and timeout
./dread_ranges_improved.sh --output /tmp/ranges --timeout 60

# List available providers
./dread_ranges_improved.sh --list-providers
```

## Supported Providers

**JSON-based providers:**
- AWS
- Google Cloud
- Cloudflare  
- Microsoft Azure
- Oracle Cloud

**Alternative providers:**
- Tor exit nodes
- Linode
- Scaleway

## Output

Creates separate files for each provider:
- `dread_aws.txt`
- `dread_google.txt`
- `dread_cloudflare.txt`
- etc.

With `--aggregate` option, also creates:
- `dread_all_ranges.txt` (deduplicated ranges from all providers)

## Legacy Script

The original script `dread_retriever.sh` is still available but the improved version `dread_ranges_improved.sh` is recommended for new usage.

See [IMPROVEMENTS.md](IMPROVEMENTS.md) for detailed comparison.
