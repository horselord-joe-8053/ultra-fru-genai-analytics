#!/bin/bash
# Setup Delta Lake infrastructure
# Routes to local (filesystem) or AWS (Terraform) implementation

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
source "$SCRIPT_DIR/../logger.sh"

SETUP_METHOD="${SETUP_METHOD:-filesystem}"

case "$SETUP_METHOD" in
    filesystem)
        "$SCRIPT_DIR/helpers/local/setup-delta-lake-local.sh"
        ;;
    terraform)
        "$SCRIPT_DIR/helpers/aws/setup-delta-lake-aws.sh"
        ;;
    *)
        log_error "Unknown setup method: $SETUP_METHOD (must be 'filesystem' or 'terraform')"
        exit 1
        ;;
esac

