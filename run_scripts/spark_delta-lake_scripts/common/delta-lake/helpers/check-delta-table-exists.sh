#!/bin/bash
# Check if Delta table exists (uses Python helper for consistency)
#
# Usage: check-delta-table-exists.sh <PATH> <METHOD> [IS_ECS] [IS_EKS]
#   PATH: Path to Delta table (filesystem or S3)
#   METHOD: "filesystem" or "s3"
#   IS_ECS: "true" or "false" (optional, auto-detected from METHOD)
#   IS_EKS: "true" or "false" (optional, defaults to false)
#
# Returns: 0 if exists, 1 if not

set -e

PATH_TO_CHECK="$1"
METHOD="${2:-filesystem}"
IS_ECS="${3:-false}"
IS_EKS="${4:-false}"

if [ -z "$PATH_TO_CHECK" ]; then
    echo "Error: Path required" >&2
    exit 1
fi

# Auto-detect AWS deployment from method
if [ "$METHOD" = "s3" ] && [ "$IS_ECS" = "false" ]; then
    IS_ECS="true"
fi

# Use Python helper (single source of truth for verification logic)
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../../../.." && pwd)}"
python3 -c "
import sys
sys.path.insert(0, '$REPO_ROOT')
from spark_jobs.utils.verify_delta_table import verify_delta_table_exists
is_ecs = '$IS_ECS'.lower() == 'true'
is_eks = '$IS_EKS'.lower() == 'true'
result = verify_delta_table_exists('$PATH_TO_CHECK', '$REPO_ROOT', is_ecs, is_eks)
sys.exit(0 if result else 1)
" 2>/dev/null

