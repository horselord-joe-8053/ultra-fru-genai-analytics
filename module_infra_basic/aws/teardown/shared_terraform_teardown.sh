#!/bin/bash
# Call terraform/teardown.sh for infrastructure layer only (VPC, Aurora, IAM).
# Usage: ./shared_terraform_teardown.sh <ENVIRONMENT> [--dry-run] [--force]
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
TF_SCRIPT="$REPO_ROOT/orchestration/terraform/teardown.sh"
ENVIRONMENT="${1:-dev}"
[ "${PREEMPT:-false}" = "true" ] && export PREEMPT=true
[ -f "$TF_SCRIPT" ] || { echo "Error: $TF_SCRIPT not found"; exit 1; }
if [ "${2:-}" = "--dry-run" ]; then
    echo "[DRY-RUN] Would run: $TF_SCRIPT $ENVIRONMENT infrastructure"
    exit 0
fi
exec "$TF_SCRIPT" "$ENVIRONMENT" "infrastructure"
