#!/bin/bash
# Diagnostic dispatcher for troubleshooting deployment failures
# Delegates to container-type-specific diagnostic functions
# Usage: source diagnose-failures.sh
#        diagnose_api_failure
#
# This script dispatches to:
#   - ecs/verification/diagnose-api-failure.sh::ecs_diagnose_api_failure() for ECS
#   - eks/verification/diagnose-api-failure.sh::eks_diagnose_api_failure() for EKS

# Helper function to check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Diagnose API service failures (dispatcher function)
# Delegates to container-type-specific diagnostic functions
diagnose_api_failure() {
    local container_type="${CONTAINER_TYPE:-ecs}"
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local repo_root="${REPO_ROOT:-$(cd "$script_dir/../../.." && pwd)}"
    
    if [ "$container_type" = "ecs" ]; then
        # Source ECS-specific diagnostic function
        if [ -f "$repo_root/module_infra_kubetypes/nonkube/aws/verification/diagnose-api-failure.sh" ]; then
            # shellcheck source=/dev/null
            source "$repo_root/module_infra_kubetypes/nonkube/aws/verification/diagnose-api-failure.sh"
            ecs_diagnose_api_failure
        else
            log_warning "ECS diagnostic script not found at: $repo_root/module_infra_kubetypes/nonkube/aws/verification/diagnose-api-failure.sh"
            return 1
        fi
    elif [ "$container_type" = "eks" ]; then
        # Source EKS-specific diagnostic function
        if [ -f "$repo_root/module_infra_kubetypes/kube/aws/verification/diagnose-api-failure.sh" ]; then
            # shellcheck source=/dev/null
            source "$repo_root/module_infra_kubetypes/kube/aws/verification/diagnose-api-failure.sh"
            eks_diagnose_api_failure
        else
            log_warning "EKS diagnostic script not found at: $repo_root/module_infra_kubetypes/kube/aws/verification/diagnose-api-failure.sh"
            return 1
        fi
    else
        log_warning "Unknown container type: $container_type (expected 'ecs' or 'eks')"
        return 1
    fi
}

# Main execution (if run standalone)
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    # Source logger if not already sourced
    if [ -z "${log_info:-}" ]; then
        SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        source "$REPO_ROOT/lib/logger.sh" 2>/dev/null || true
    fi
    
    diagnose_api_failure
else
    # If sourced, just define the functions
    true  # Functions are already defined above
fi

