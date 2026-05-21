#!/usr/bin/env bash
# =============================================================================
# Root run entrypoint: ./run.sh <local|aws> <kube|nonkube> [env] [options...]
# =============================================================================
# Delegates to orchestration/run.sh. Supports:
#   local nonkube   → Local Docker Compose
#   local kube      → Local Kubernetes (minikube/kind)
#   aws nonkube [env] → AWS ECS (env: dev|prod, default dev)
#   aws kube [env]    → AWS EKS (env: dev|prod, default dev)
#
# Goal: ./run.sh aws kube dev --preempt should run problem-free (teardown then
# deploy). Preempt destroys EKS + ECS + shared infra (VPC, Aurora, IAM); then
# deploys only the requested type. See docs/DEPLOYMENT_ERRORS_AND_FIXES.md and
# docs/learned/TERRA_LEARNED.md for layers and subnet group / Secrets Manager.
#
# Options: --preempt (destroy before deploy), --skip-build, --skip-data-lake, etc.
# =============================================================================
set -e
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export REPO_ROOT
# shellcheck source=lib/logger.sh
source "$REPO_ROOT/lib/logger.sh" 2>/dev/null || true
command -v log_info >/dev/null 2>&1 || log_info() { echo "[INFO] $*"; }
log_info "### start of run.sh ###"
set +e
"$REPO_ROOT/orchestration/run.sh" "$@"
_rc=$?
set -e
log_info "### end of run.sh ###"
exit $_rc
