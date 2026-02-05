#!/usr/bin/env bash
# =============================================================================
# Top-level run dispatcher: ./orchestration/run.sh <local|aws> <kube|nonkube> [env] [options...]
# =============================================================================
# Delegates to orchestration/local/run.sh or orchestration/aws/run.sh.
#
# Modes:
#   local nonkube   → Local Docker Compose (default)
#   local kube      → Local Kubernetes (minikube/kind)
#   aws nonkube [env] → AWS ECS (env: dev|prod, default dev)
#   aws kube [env]    → AWS EKS (env: dev|prod, default dev)
#
# Goal: ./run.sh aws kube dev --preempt runs problem-free. Preempt = teardown
# (EKS + ECS + shared infra) then deploy. Option B implemented: Secrets Manager
# is in infrastructure-longterm (never destroyed); infrastructure destroy runs in one pass.
#
# Pass-through: --preempt, --skip-build, --skip-data-lake, etc.
# Usage: ./orchestration/run.sh [local|aws] [kube|nonkube] [dev|prod] [options...]
# =============================================================================

set -e
ORCH_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$ORCH_SCRIPT_DIR/.." && pwd)}"
export REPO_ROOT

source "$REPO_ROOT/lib/logger.sh"
source "$REPO_ROOT/orchestration/common/env/load-env.sh"
load_env_file 2>/dev/null || true

log_info "### start of orchestration/run.sh ###"

PROVIDER="${1:-}"
ROUTE="${2:-}"
shift 2 2>/dev/null || true
REMAINING=("$@")

show_usage() {
    echo "Usage: $0 <local|aws> <kube|nonkube> [env] [options...]"
    echo "  local nonkube   → Local Docker Compose (default)"
    echo "  local kube      → Local Kubernetes (minikube/kind)"
    echo "  aws nonkube [env] → AWS ECS (env: dev|prod, default dev)"
    echo "  aws kube [env]    → AWS EKS (env: dev|prod, default dev)"
    echo "Pass-through options (e.g. --preempt, --skip-data-lake) are forwarded to the target script."
    log_info "### end of orchestration/run.sh ###"
    exit 0
}

case "$PROVIDER" in
    help|-h|--help) show_usage ;;
    local)
        case "${ROUTE:-nonkube}" in
            kube|nonkube) ;;
            *) log_error "Invalid route for local: $ROUTE (use kube or nonkube)"; log_info "### end of orchestration/run.sh ###"; exit 1 ;;
        esac
        set +e
        "$REPO_ROOT/orchestration/local/run.sh" --container-type "${ROUTE:-nonkube}" "${REMAINING[@]}"
        _rc=$?
        set -e
        log_info "### end of orchestration/run.sh ###"
        exit $_rc
        ;;
    aws)
        ENV="${REMAINING[0]:-dev}"
        if [[ "$ENV" == dev || "$ENV" == prod ]]; then
            REST=("${REMAINING[@]:1}")
        else
            ENV="dev"
            REST=("${REMAINING[@]}")
        fi
        case "${ROUTE:-nonkube}" in
            nonkube) CT="ecs" ;;
            kube)    CT="eks" ;;
            *) log_error "Invalid route for aws: $ROUTE (use kube or nonkube)"; log_info "### end of orchestration/run.sh ###"; exit 1 ;;
        esac
        set +e
        "$REPO_ROOT/orchestration/aws/run.sh" deploy --container-type "$CT" "$ENV" "${REST[@]}"
        _rc=$?
        set -e
        log_info "### end of orchestration/run.sh ###"
        exit $_rc
        ;;
    "")
        log_error "Missing provider. Use: $0 <local|aws> <kube|nonkube> [env] [options...]"
        show_usage
        ;;
    *)
        log_error "Unknown provider: $PROVIDER (use local or aws)"
        log_info "### end of orchestration/run.sh ###"
        exit 1
        ;;
esac
