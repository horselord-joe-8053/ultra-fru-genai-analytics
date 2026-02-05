#!/bin/bash
# Service status check dispatcher (ECS/EKS running status, basic API health)
# Delegates to container-type-specific status check functions
# Usage: source check-service-status.sh
#        check_service_status <container-type> <environment>
# Note: container-type should be 'ecs' or 'eks' (set via CONTAINER_TYPE environment variable)
#
# This script dispatches to:
#   - ecs/verification/check-service-status.sh::check_ecs_service_status() for ECS
#   - eks/verification/check-service-status.sh::check_eks_pod_status() for EKS

# Helper function to check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Basic API health check (quick, no retry)
check_api_health_basic() {
    local api_url="${1:-${API_URL:-}}"
    
    if [ -z "$api_url" ]; then
        return 0  # Skip if no API URL
    fi
    
    if ! command_exists curl; then
        log_warning "curl not available; cannot check API health"
        return 1
    fi
    
    log_info "Checking API health endpoint..."
    if curl -sf "$api_url/health" >/dev/null 2>&1; then
        log_success "API is responding at $api_url/health"
        
        # Get detailed health status
        local health_response
        health_response=$(curl -sf "$api_url/health" 2>/dev/null || echo "{}")
        if echo "$health_response" | grep -q '"status":"ok"'; then
            log_success "API health check passed"
        fi
    else
        log_warning "API is not responding yet (may still be deploying)"
        log_info "Wait a few minutes and try: curl $api_url/health"
    fi
}

# Main function to check service status (dispatcher)
check_service_status() {
    local container_type="${1:-${CONTAINER_TYPE:-ecs}}"  # Accept container type directly
    local environment="${2:-${ENVIRONMENT:-dev}}"
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local repo_root="${REPO_ROOT:-$(cd "$script_dir/../../.." && pwd)}"
    
    # Default to ecs if not specified
    container_type="${container_type:-ecs}"
    
    # Check ECS service status
    if [ "$container_type" = "ecs" ]; then
        if [ -f "$repo_root/module_infra_kubetypes/nonkube/aws/verification/check-service-status.sh" ]; then
            # shellcheck source=/dev/null
            source "$repo_root/module_infra_kubetypes/nonkube/aws/verification/check-service-status.sh"
            check_ecs_service_status "$environment"
        else
            log_warning "ECS service status script not found at: $repo_root/module_infra_kubetypes/nonkube/aws/verification/check-service-status.sh"
        fi
    fi
    
    # Check EKS pod status
    if [ "$container_type" = "eks" ]; then
        if [ -f "$repo_root/module_infra_kubetypes/kube/aws/verification/check-service-status.sh" ]; then
            # shellcheck source=/dev/null
            source "$repo_root/module_infra_kubetypes/kube/aws/verification/check-service-status.sh"
            check_eks_pod_status
        else
            log_warning "EKS service status script not found at: $repo_root/module_infra_kubetypes/kube/aws/verification/check-service-status.sh"
        fi
    fi
    
    # Basic API health check (shared across both container types)
    check_api_health_basic
}

# Main execution (if run standalone)
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    # Source logger if not already sourced
    if [ -z "${log_info:-}" ]; then
        SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        source "$REPO_ROOT/lib/logger.sh" 2>/dev/null || true
    fi
    
    check_service_status "$@"
else
    # If sourced, just define the functions
    true  # Functions are already defined above
fi

