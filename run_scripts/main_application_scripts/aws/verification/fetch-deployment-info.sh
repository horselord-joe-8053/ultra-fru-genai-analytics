#!/bin/bash
# Fetch deployment information from Terraform outputs
# Exports: ALB_DNS, CLOUDFRONT_DOMAIN, ECS_*, EKS_*, API_URL, FRONTEND_URL
# Usage: source fetch-deployment-info.sh <environment> [dry-run]
# Note: CONTAINER_TYPE must be set via environment variable (from run.sh --container-type parameter)

# Get parameters
# CONTAINER_TYPE is used (set via environment variable from run.sh)
ENVIRONMENT="${2:-${ENVIRONMENT:-dev}}"
DRY_RUN="${3:-${DRY_RUN:-false}}"

# Determine container type from CONTAINER_TYPE (exported by run.sh)
CONTAINER_TYPE="${CONTAINER_TYPE:-ecs}"  # Default to ecs if not set

# Helper function to check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Fetch actual values from Terraform outputs (if not dry-run)
fetch_terraform_outputs() {
    if [ "$DRY_RUN" = "true" ]; then
        return 0
    fi
    
    # Debug: Verify variables are visible inside fetch_terraform_outputs()
    if command -v log_info >/dev/null 2>&1; then
        log_info "Inside fetch_terraform_outputs():"
        log_info "  TF_STATE_BUCKET=[${TF_STATE_BUCKET:-NOT SET}]"
        log_info "  AWS_PROFILE=[${AWS_PROFILE:-NOT SET}]"
        log_info "  REPO_ROOT=[${REPO_ROOT:-NOT SET}]"
        log_info "  ENVIRONMENT=[${ENVIRONMENT:-NOT SET}]"
    fi
    
    # Check if critical variables are already set - if so, skip expensive terragrunt/AWS CLI calls
    # This provides significant performance savings when function is called multiple times
    # Optimization: Check if API_URL is set (most critical) OR if container-type-specific variables are set
    # This is more lenient than requiring ALL variables, since some may be optional (e.g., CLOUDFRONT_DOMAIN)
    local container_type="${CONTAINER_TYPE:-ecs}"
    local skip_fetch=false
    
    # Check if API_URL is set (works for both ECS and EKS)
    if [ -n "${API_URL:-}" ]; then
        skip_fetch=true
    elif [ "$container_type" = "ecs" ] && 
         [ -n "${ALB_DNS:-}" ] && [ -n "${ECS_CLUSTER_ID:-}" ] && [ -n "${ECS_SERVICE_NAME:-}" ]; then
        # ECS variables are set
        skip_fetch=true
    elif [ "$container_type" = "eks" ] && 
         [ -n "${K8S_INGRESS_HOST:-}" ] && [ -n "${EKS_CLUSTER_NAME:-}" ]; then
        # EKS variables are set
        skip_fetch=true
    fi
    
    if [ "$skip_fetch" = true ]; then
        if command -v log_info >/dev/null 2>&1; then
            log_info "Deployment variables already set, skipping expensive terragrunt/AWS CLI calls"
            log_info "  API_URL=[${API_URL:-NOT SET}]"
            if [ "$container_type" = "ecs" ]; then
                log_info "  ALB_DNS=[${ALB_DNS:-NOT SET}]"
                log_info "  ECS_CLUSTER_ID=[${ECS_CLUSTER_ID:-NOT SET}]"
            elif [ "$container_type" = "eks" ]; then
                log_info "  K8S_INGRESS_HOST=[${K8S_INGRESS_HOST:-NOT SET}]"
                log_info "  EKS_CLUSTER_NAME=[${EKS_CLUSTER_NAME:-NOT SET}]"
            fi
            log_info "  CLOUDFRONT_DOMAIN=[${CLOUDFRONT_DOMAIN:-NOT SET}]"
        fi
        # Ensure derived variables are set
        if [ "$container_type" = "ecs" ]; then
            if [ -n "$ECS_CLUSTER_ID" ] && [ -z "${ECS_CLUSTER_NAME:-}" ]; then
                ECS_CLUSTER_NAME=$(echo "$ECS_CLUSTER_ID" | awk -F'/' '{print $NF}' || echo "")
            fi
            if [ -n "$ALB_DNS" ] && [ -z "${API_URL:-}" ]; then
                API_URL="http://$ALB_DNS"
            fi
        fi
        if [ -n "$CLOUDFRONT_DOMAIN" ] && [ -z "${FRONTEND_URL:-}" ]; then
            FRONTEND_URL="https://$CLOUDFRONT_DOMAIN"
        fi
        return 0
    fi
    
    # Initialize variables to empty (only if not already set)
    ALB_DNS="${ALB_DNS:-}"
    CLOUDFRONT_DOMAIN="${CLOUDFRONT_DOMAIN:-}"
    ECS_CLUSTER_ID="${ECS_CLUSTER_ID:-}"
    ECS_CLUSTER_NAME="${ECS_CLUSTER_NAME:-}"
    ECS_SERVICE_NAME="${ECS_SERVICE_NAME:-}"
    EKS_CLUSTER_NAME="${EKS_CLUSTER_NAME:-}"
    K8S_SERVICE_IP="${K8S_SERVICE_IP:-}"
    K8S_INGRESS_HOST="${K8S_INGRESS_HOST:-}"
    
    # Calculate REPO_ROOT if not set (fallback for standalone execution)
    # From verification/ directory: go up 3 levels (verification -> aws -> main_application_scripts -> run_scripts -> repo root)
    if [ -z "${REPO_ROOT:-}" ]; then
        local script_dir
        script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        REPO_ROOT="$(cd "$script_dir/../../.." && pwd)"
    fi
    
    TERRAFORM_DIR="$REPO_ROOT/module_infra_basic/aws/environments/$ENVIRONMENT"
    
    # Dispatch to container-type-specific deployment info fetching functions
    local container_type="${CONTAINER_TYPE:-ecs}"
    
    if [ "$container_type" = "ecs" ]; then
        if [ -f "$REPO_ROOT/run_scripts/main_application_scripts/aws/ecs/verification/fetch-deployment-info-ecs.sh" ]; then
            # shellcheck source=/dev/null
            source "$REPO_ROOT/run_scripts/main_application_scripts/aws/ecs/verification/fetch-deployment-info-ecs.sh"
            fetch_ecs_deployment_info
        else
            log_warning "ECS deployment info script not found at: $REPO_ROOT/run_scripts/main_application_scripts/aws/ecs/verification/fetch-deployment-info-ecs.sh"
        fi
    elif [ "$container_type" = "eks" ]; then
        if [ -f "$REPO_ROOT/module_infra_kube/aws/verification/fetch-deployment-info-eks.sh" ]; then
            # shellcheck source=/dev/null
            source "$REPO_ROOT/module_infra_kube/aws/verification/fetch-deployment-info-eks.sh"
            fetch_eks_deployment_info
        else
            log_warning "EKS deployment info script not found at: $REPO_ROOT/module_infra_kube/aws/verification/fetch-deployment-info-eks.sh"
        fi
    else
        log_warning "Unknown container type: $container_type (expected 'ecs' or 'eks')"
    fi
    
    # Export all variables for use by other scripts
    export ALB_DNS
    export CLOUDFRONT_DOMAIN
    export ECS_CLUSTER_ID
    export ECS_CLUSTER_NAME
    export ECS_SERVICE_NAME
    export EKS_CLUSTER_NAME
    export K8S_SERVICE_IP
    export K8S_INGRESS_HOST
    export API_URL
    export FRONTEND_URL
    
    # Write to cache if USE_CACHED_AWS_VAL is set (always update cache to keep it fresh)
    # This is called from test scripts, so check if cache utilities are available
    if [[ "${USE_CACHED_AWS_VAL:-false}" == "true" ]] && [ -n "${REPO_ROOT:-}" ]; then
        local cache_script="${REPO_ROOT}/module_test_verification/common_sh/test_cache.sh"
        if [ -f "$cache_script" ]; then
            # shellcheck source=/dev/null
            source "$cache_script" 2>/dev/null || true
            
            if command -v write_cache_value >/dev/null 2>&1; then
                local aws_region="${AWS_REGION:-us-east-1}"
                local environment="${ENVIRONMENT:-dev}"
                local container_type="${CONTAINER_TYPE:-ecs}"
                
                # Write base variables to cache (non-fatal)
                write_cache_value "ALB_DNS" "$environment" "$container_type" "$aws_region" "${ALB_DNS:-}" "" || true
                write_cache_value "CLOUDFRONT_DOMAIN" "$environment" "$container_type" "$aws_region" "${CLOUDFRONT_DOMAIN:-}" "" || true
                write_cache_value "ECS_CLUSTER_ID" "$environment" "$container_type" "$aws_region" "${ECS_CLUSTER_ID:-}" "" || true
                write_cache_value "ECS_SERVICE_NAME" "$environment" "$container_type" "$aws_region" "${ECS_SERVICE_NAME:-}" "" || true
            fi
        fi
    fi
}

# This script is always sourced (never run standalone), so automatically call fetch_terraform_outputs()
# All callers use: source "$SCRIPT_DIR/fetch-deployment-info.sh" ...
fetch_terraform_outputs

