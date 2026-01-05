#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
source "$SCRIPT_DIR/../logger.sh"

VERIFY_METHOD="${VERIFY_METHOD:-filesystem}"

case "$VERIFY_METHOD" in
    filesystem)
        "$SCRIPT_DIR/helpers/local/verify-infrastructure-local.sh"
        ;;
    s3)
        "$SCRIPT_DIR/helpers/aws/verify-infrastructure-aws.sh"
        ;;
    *)
        log_error "Unknown verify method: $VERIFY_METHOD"
        exit 1
        ;;
esac

