#!/usr/bin/env bash
# Top-level teardown dispatcher: ./orchestration/teardown.sh <local|aws> <kube|nonkube|all> [env] [options...]
# For aws, "all" destroys EKS + ECS + shared infra.

set -e
ORCH_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$ORCH_SCRIPT_DIR/.." && pwd)}"
export REPO_ROOT

source "$REPO_ROOT/orchestration/shared/logger.sh"
source "$REPO_ROOT/orchestration/shared/load-env.sh"
load_env_file 2>/dev/null || true

PROVIDER="${1:-}"
ROUTE="${2:-}"
shift 2 2>/dev/null || true
REMAINING=("$@")

show_usage() {
    echo "Usage: $0 <local|aws> <kube|nonkube|all> [env] [options...]"
    echo "  local nonkube   → Teardown local Docker Compose"
    echo "  local kube      → Teardown local Kubernetes"
    echo "  aws nonkube [env] → Teardown AWS ECS only (env: dev|prod)"
    echo "  aws kube [env]    → Teardown AWS EKS only"
    echo "  aws all [env]     → Teardown AWS EKS + ECS + shared infra"
    echo "Options: --force, --dry-run, etc. forwarded to target script."
    exit 0
}

case "$PROVIDER" in
    help|-h|--help) show_usage ;;
    local)
        case "${ROUTE:-nonkube}" in
            kube|nonkube) ;;
            all) ROUTE="nonkube" ;;
            *) log_error "Invalid route for local: $ROUTE"; exit 1 ;;
        esac
        exec "$REPO_ROOT/run_scripts/main_application_scripts/local/shared/resources_cleanup/teardown-resources-all.sh" --container-type "${ROUTE:-nonkube}" "${REMAINING[@]}"
        ;;
    aws)
        ENV="${REMAINING[0]:-dev}"
        if [[ "$ENV" == dev || "$ENV" == prod || "$ENV" == staging ]]; then
            REST=("${REMAINING[@]:1}")
        else
            ENV="dev"
            REST=("${REMAINING[@]}")
        fi
        case "${ROUTE:-}" in
            nonkube) CT="ecs" ;;
            kube)    CT="eks" ;;
            all)     CT="all" ;;
            *) log_error "Invalid route for aws: $ROUTE (use kube, nonkube, or all)"; exit 1 ;;
        esac
        exec "$REPO_ROOT/run_scripts/main_application_scripts/aws/shared/resources_cleanup/teardown-resources-all.sh" "$ENV" --container-type "$CT" "${REST[@]}"
        ;;
    "")
        log_error "Missing provider. Use: $0 <local|aws> <kube|nonkube|all> [env] [options...]"
        show_usage
        ;;
    *)
        log_error "Unknown provider: $PROVIDER (use local or aws)"
        exit 1
        ;;
esac
