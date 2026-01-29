#!/bin/bash
# Attach IAM inline policy for ec2:ReleaseAddress so the removal script can release
# Elastic IPs that fail with AuthFailure. Run once (e.g. before remove-all-aws-resources.sh).
# Usage: ./ensure-release-address-policy.sh [--profile PROFILE] [--dry-run]
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$SCRIPT_DIR/ensure-release-address-policy.py" "$@"
