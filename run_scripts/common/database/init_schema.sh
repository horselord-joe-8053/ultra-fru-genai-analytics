#!/bin/bash
# Wrapper script to initialize database schema
# Routes to provider-specific implementation (local, aws, azure, gcp)
# Usage: ./init_schema.sh [provider] [additional-args...]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
source "$SCRIPT_DIR/../logger.sh"

# Detect provider from environment or context
detect_provider() {
    # If explicitly set, use it
    if [ -n "${CLOUD_PROVIDER:-}" ]; then
        echo "$CLOUD_PROVIDER"
        return 0
    fi
    
    # Auto-detect from script location context
    # If called from run_scripts/local/, provider is local
    # If called from run_scripts/aws/, provider is aws
    local caller_script="${BASH_SOURCE[1]:-}"
    if [[ "$caller_script" == *"/run_scripts/local/"* ]]; then
        echo "local"
        return 0
    elif [[ "$caller_script" == *"/run_scripts/aws/"* ]]; then
        echo "aws"
        return 0
    fi
    
    # Default to local if no context detected
    echo "local"
}

# Get provider (first argument or auto-detect)
PROVIDER="${1:-$(detect_provider)}"
shift || true  # Remove provider from arguments

# Route to provider-specific implementation
case "$PROVIDER" in
    local)
        source "$SCRIPT_DIR/init_schema_local.sh"
        init_schema_local "$@"
        ;;
    aws)
        source "$SCRIPT_DIR/init_schema_aws.sh"
        init_schema_aws "$@"
        ;;
    *)
        log_error "Unknown provider: $PROVIDER"
        log_error "Supported providers: local, aws"
        exit 1
        ;;
esac

