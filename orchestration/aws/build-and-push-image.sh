#!/bin/bash
# Standalone: build Docker image and push to ECR (same as Phase 1 of full deploy).
# Usage: ./orchestration/aws/build-and-push-image.sh [dev|prod]
# From repo root: ./orchestration/aws/build-and-push-image.sh dev
#
# Requires: .env with AWS_* and ENVIRONMENT (or pass env as first arg).
# Optional: FORCE_REBUILD=true to rebuild even if image exists in ECR.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"

export REPO_ROOT
export ENVIRONMENT="${1:-${ENVIRONMENT:-dev}}"

# Load .env so AWS_PROFILE, ENVIRONMENT, etc. are set (same as full deploy)
if [ -f "$REPO_ROOT/.env" ]; then
    set -a
    # shellcheck source=/dev/null
    source "$REPO_ROOT/.env"
    set +a
fi

# Override ENVIRONMENT if passed as first arg
[ -n "${1:-}" ] && export ENVIRONMENT="$1"

"$REPO_ROOT/module_infra_basic/aws/build-push-ecr.sh"
