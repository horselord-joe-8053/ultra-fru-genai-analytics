#!/usr/bin/env bash
# Root entrypoint: delegate to orchestration/teardown.sh
# Usage: ./teardown.sh <local|aws> <kube|nonkube|all> [env] [options...]
set -e
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export REPO_ROOT
exec "$REPO_ROOT/orchestration/teardown.sh" "$@"
