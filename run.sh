#!/usr/bin/env bash
# Root entrypoint: delegate to orchestration/run.sh
# Usage: ./run.sh <local|aws> <kube|nonkube> [env] [options...]
set -e
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export REPO_ROOT
exec "$REPO_ROOT/orchestration/run.sh" "$@"
