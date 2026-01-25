#!/bin/bash
# Verify Running Versions
# Phase 6: Standalone script to verify current running versions match expected
# Usage: verify-running-versions.sh [--namespace <ns>] [--deployment <name>] [--environment <env>]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../../../../.." && pwd)}"

# Source logger
if [ -f "$REPO_ROOT/run_scripts/shared/logger.sh" ]; then
    source "$REPO_ROOT/run_scripts/shared/logger.sh"
else
    log_info() { echo "[INFO] $*"; }
    log_success() { echo "[SUCCESS] $*"; }
    log_warning() { echo "[WARNING] $*"; }
    log_error() { echo "[ERROR] $*"; }
fi

# Source drift detection
if [ -f "$SCRIPT_DIR/detect-version-drift.sh" ]; then
    source "$SCRIPT_DIR/detect-version-drift.sh"
else
    log_error "detect-version-drift.sh not found"
    exit 1
fi

main() {
    local namespace="default"
    local deployment_name="fru-api"
    local environment="dev"
    
    # Parse arguments
    while [ $# -gt 0 ]; do
        case "$1" in
            --namespace|-n)
                namespace="$2"
                shift 2
                ;;
            --deployment|-d)
                deployment_name="$2"
                shift 2
                ;;
            --environment|-e)
                environment="$2"
                shift 2
                ;;
            --help|-h)
                echo "Usage: $0 [--namespace <ns>] [--deployment <name>] [--environment <env>]"
                echo ""
                echo "Verifies that running Kubernetes pods match expected deployment state."
                echo ""
                echo "Options:"
                echo "  --namespace, -n    Kubernetes namespace (default: default)"
                echo "  --deployment, -d  Deployment name (default: fru-api)"
                echo "  --environment, -e Environment (default: dev)"
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                echo "Use --help for usage information"
                exit 1
                ;;
        esac
    done
    
    log_step "Verifying Running Versions"
    log_info "This script checks if running versions match the last deployment state"
    echo ""
    
    detect_version_drift "$namespace" "$deployment_name" "$environment"
    local exit_code=$?
    
    echo ""
    if [ $exit_code -eq 0 ]; then
        log_success "All versions are consistent!"
    else
        log_warning "Version inconsistencies detected - see warnings above"
        exit 1
    fi
}

main "$@"
