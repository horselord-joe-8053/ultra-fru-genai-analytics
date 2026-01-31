#!/bin/bash
# Verify Delta Lake setup
# Routes to local (filesystem) or AWS (S3) verification

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../../../../.." && pwd)}"
source "$REPO_ROOT/orchestration/shared/logger.sh"

VERIFY_METHOD="${VERIFY_METHOD:-filesystem}"

case "$VERIFY_METHOD" in
    filesystem)
        "$SCRIPT_DIR/helpers/local/verify-infrastructure-local.sh"
        ;;
    s3)
        "$SCRIPT_DIR/helpers/aws/verify-infrastructure-aws.sh"
        ;;
    *)
        log_error "Unknown verify method: $VERIFY_METHOD (must be 'filesystem' or 's3')"
        exit 1
        ;;
esac

