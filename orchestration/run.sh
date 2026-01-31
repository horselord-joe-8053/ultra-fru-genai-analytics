#!/usr/bin/env bash
# Top-level run dispatcher: ./orchestration/run.sh <local|aws> <kube|nonkube> [env] [options...]
# Delegates to orchestration/local/run.sh or orchestration/aws/run.sh.

set -e
ORCH_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$ORCH_SCRIPT_DIR/.." && pwd)}"
export REPO_ROOT

source "$REPO_ROOT/orchestration/common/logger.sh"
source "$REPO_ROOT/orchestration/common/env/load-env.sh"
load_env_file 2>/dev/null || true

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
    exit 0
}

case "$PROVIDER" in
    help|-h|--help) show_usage ;;
    local)
        case "${ROUTE:-nonkube}" in
            kube|nonkube) ;;
            *) log_error "Invalid route for local: $ROUTE (use kube or nonkube)"; exit 1 ;;
        esac
        exec "$REPO_ROOT/orchestration/local/run.sh" --container-type "${ROUTE:-nonkube}" "${REMAINING[@]}"
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
            *) log_error "Invalid route for aws: $ROUTE (use kube or nonkube)"; exit 1 ;;
        esac
        exec "$REPO_ROOT/orchestration/aws/run.sh" deploy --container-type "$CT" "$ENV" "${REST[@]}"
        ;;
    "")
        log_error "Missing provider. Use: $0 <local|aws> <kube|nonkube> [env] [options...]"
        show_usage
        ;;
    *)
        log_error "Unknown provider: $PROVIDER (use local or aws)"
        exit 1
        ;;
esac
