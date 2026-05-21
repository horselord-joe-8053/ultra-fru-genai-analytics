#!/bin/bash
# Attach IAM inline policy for ec2:ReleaseAddress so the removal script can release
# Elastic IPs that fail with AuthFailure. Run once (e.g. before remove-all-aws-resources.sh).
# Usage: ./ensure-release-address-policy.sh [--profile PROFILE] [--dry-run]
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../../../.." && pwd)}"
source "$REPO_ROOT/orchestration/common/env/load-python-env.sh"
exec "$PYTHON_CMD" "$SCRIPT_DIR/ensure-release-address-policy.py" "$@"
