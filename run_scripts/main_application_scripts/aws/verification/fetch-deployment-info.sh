#!/bin/bash
# Fetch deployment information from Terraform outputs
# Exports: ALB_DNS, CLOUDFRONT_DOMAIN, ECS_*, EKS_*, API_URL, FRONTEND_URL
# Usage: source fetch-deployment-info.sh <deployment-type> <environment> [dry-run]

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
    # Optimization: Check if API_URL is set (most critical) OR if core ECS variables are set
    # This is more lenient than requiring ALL variables, since some may be optional (e.g., CLOUDFRONT_DOMAIN)
    if [ -n "${API_URL:-}" ] || 
       ([ -n "${ALB_DNS:-}" ] && [ -n "${ECS_CLUSTER_ID:-}" ] && [ -n "${ECS_SERVICE_NAME:-}" ]); then
        if command -v log_info >/dev/null 2>&1; then
            log_info "Deployment variables already set, skipping expensive terragrunt/AWS CLI calls"
            log_info "  API_URL=[${API_URL:-NOT SET}]"
            log_info "  ALB_DNS=[${ALB_DNS:-NOT SET}]"
            log_info "  CLOUDFRONT_DOMAIN=[${CLOUDFRONT_DOMAIN:-NOT SET}]"
            log_info "  ECS_CLUSTER_ID=[${ECS_CLUSTER_ID:-NOT SET}]"
        fi
        # Ensure derived variables are set
        if [ -n "$ECS_CLUSTER_ID" ] && [ -z "${ECS_CLUSTER_NAME:-}" ]; then
            ECS_CLUSTER_NAME=$(echo "$ECS_CLUSTER_ID" | awk -F'/' '{print $NF}' || echo "")
        fi
        if [ -n "$ALB_DNS" ] && [ -z "${API_URL:-}" ]; then
            API_URL="http://$ALB_DNS"
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
    
    TERRAFORM_DIR="$REPO_ROOT/infra/terraform/environments/$ENVIRONMENT"
    
    # Fetch ECS/ALB outputs (for ECS container type)
    if [ "${CONTAINER_TYPE:-ecs}" = "ecs" ]; then
        APP_DIR="$TERRAFORM_DIR/application"
        if [ -d "$APP_DIR" ] && command_exists terragrunt; then
            ORIG_DIR=$(pwd)
            cd "$APP_DIR" 2>/dev/null || return 0
            
            # Debug: Verify variables are still set before calling terragrunt
            if command -v log_info >/dev/null 2>&1; then
                log_info "About to run terragrunt in $APP_DIR:"
                log_info "  TF_STATE_BUCKET=[${TF_STATE_BUCKET:-NOT SET}]"
                log_info "  AWS_PROFILE=[${AWS_PROFILE:-NOT SET}]"
            fi
            
            # Try to read outputs; on failure, log a warning instead of silently ignoring
            # Note: Only fetch if not already set (skip expensive terragrunt calls if we already have the value)
            local terragrunt_error
            
            if [ -z "${ALB_DNS:-}" ]; then
                log_info "Fetching Terraform output: alb_dns_name"
                if ! ALB_DNS=$(terragrunt output -raw alb_dns_name 2>&1); then
                    terragrunt_error="$ALB_DNS"
                    ALB_DNS=""
                    log_warning "Could not read Terraform output 'alb_dns_name' via terragrunt; API URL may be unavailable"
                    if command -v log_info >/dev/null 2>&1 && [ -n "$terragrunt_error" ]; then
                        log_info "Terragrunt error: ${terragrunt_error:0:200}"
                    fi
                else
                    log_info "Output retrieved: alb_dns_name=$ALB_DNS"
                fi
            fi
            
            if [ -z "${CLOUDFRONT_DOMAIN:-}" ]; then
                log_info "Fetching Terraform output: cloudfront_domain_name"
                if ! CLOUDFRONT_DOMAIN=$(terragrunt output -raw cloudfront_domain_name 2>&1); then
                    terragrunt_error="$CLOUDFRONT_DOMAIN"
                    CLOUDFRONT_DOMAIN=""
                    log_warning "Could not read Terraform output 'cloudfront_domain_name' via terragrunt; frontend URL may be unavailable"
                    if command -v log_info >/dev/null 2>&1 && [ -n "$terragrunt_error" ]; then
                        log_info "Terragrunt error: ${terragrunt_error:0:200}"
                    fi
                else
                    log_info "Output retrieved: cloudfront_domain_name=$CLOUDFRONT_DOMAIN"
                fi
            fi
            
            if [ -z "${ECS_CLUSTER_ID:-}" ]; then
                log_info "Fetching Terraform output: ecs_cluster_id"
                if ! ECS_CLUSTER_ID=$(terragrunt output -raw ecs_cluster_id 2>&1); then
                    terragrunt_error="$ECS_CLUSTER_ID"
                    ECS_CLUSTER_ID=""
                    log_warning "Could not read Terraform output 'ecs_cluster_id' via terragrunt; ECS hints may be limited"
                    if command -v log_info >/dev/null 2>&1 && [ -n "$terragrunt_error" ]; then
                        log_info "Terragrunt error: ${terragrunt_error:0:200}"
                    fi
                else
                    log_info "Output retrieved: ecs_cluster_id=${ECS_CLUSTER_ID:0:100}..."
                fi
            fi
            
            if [ -z "${ECS_SERVICE_NAME:-}" ]; then
                log_info "Fetching Terraform output: ecs_service_name"
                if ! ECS_SERVICE_NAME=$(terragrunt output -raw ecs_service_name 2>&1); then
                    terragrunt_error="$ECS_SERVICE_NAME"
                    ECS_SERVICE_NAME=""
                    log_warning "Could not read Terraform output 'ecs_service_name' via terragrunt; ECS hints may be limited"
                    if command -v log_info >/dev/null 2>&1 && [ -n "$terragrunt_error" ]; then
                        log_info "Terragrunt error: ${terragrunt_error:0:200}"
                    fi
                else
                    log_info "Output retrieved: ecs_service_name=$ECS_SERVICE_NAME"
                fi
            fi
            cd "$ORIG_DIR" 2>/dev/null || true
            
            # Extract cluster name from ARN if needed
            if [ -n "$ECS_CLUSTER_ID" ]; then
                ECS_CLUSTER_NAME=$(echo "$ECS_CLUSTER_ID" | awk -F'/' '{print $NF}' || echo "")
            fi
            
            # Set API_URL and FRONTEND_URL from discovered values
            if [ -n "$ALB_DNS" ]; then
                API_URL="http://$ALB_DNS"
            fi
            if [ -n "$CLOUDFRONT_DOMAIN" ]; then
                FRONTEND_URL="https://$CLOUDFRONT_DOMAIN"
            fi
        fi

        # Fallback: if Terragrunt outputs are unavailable, try AWS CLI to infer ALB DNS
        if [ -z "$ALB_DNS" ] && command_exists aws; then
            log_info "Attempting to discover ECS cluster/service and ALB DNS via AWS CLI (fallback)..."

            # Find an ECS cluster whose ARN contains the environment name
            # Use same pattern as check-service-status.sh: let AWS CLI use defaults for region/profile
            ECS_CLUSTER_ID=$(aws ecs list-clusters \
                --query "clusterArns[?contains(@, '$ENVIRONMENT')]" \
                --output text 2>/dev/null | head -1 || echo "")

            if [ -n "$ECS_CLUSTER_ID" ] && [ "$ECS_CLUSTER_ID" != "None" ]; then
                ECS_CLUSTER_NAME=$(echo "$ECS_CLUSTER_ID" | awk -F'/' '{print $NF}' || echo "")
                log_info "Discovered ECS cluster via AWS CLI: $ECS_CLUSTER_NAME"

                # Find first service in that cluster
                local service_arn
                service_arn=$(aws ecs list-services \
                    --cluster "$ECS_CLUSTER_ID" \
                    --query "serviceArns[0]" \
                    --output text 2>/dev/null || echo "")

                if [ -n "$service_arn" ] && [ "$service_arn" != "None" ]; then
                    ECS_SERVICE_NAME=$(echo "$service_arn" | awk -F'/' '{print $NF}' || echo "")
                    log_info "Discovered ECS service via AWS CLI: $ECS_SERVICE_NAME"

                    # From the ECS service, get target group ARN
                    local target_group_arn
                    target_group_arn=$(aws ecs describe-services \
                        --cluster "$ECS_CLUSTER_ID" \
                        --services "$ECS_SERVICE_NAME" \
                        --query "services[0].loadBalancers[0].targetGroupArn" \
                        --output text 2>/dev/null || echo "")

                    if [ -n "$target_group_arn" ] && [ "$target_group_arn" != "None" ]; then
                        # From target group, get load balancer ARN
                        local lb_arn
                        lb_arn=$(aws elbv2 describe-target-groups \
                            --target-group-arns "$target_group_arn" \
                            --query "TargetGroups[0].LoadBalancerArns[0]" \
                            --output text 2>/dev/null || echo "")

                        if [ -n "$lb_arn" ] && [ "$lb_arn" != "None" ]; then
                            ALB_DNS=$(aws elbv2 describe-load-balancers \
                                --load-balancer-arns "$lb_arn" \
                                --query "LoadBalancers[0].DNSName" \
                                --output text 2>/dev/null || echo "")

                            if [ -n "$ALB_DNS" ] && [ "$ALB_DNS" != "None" ]; then
                                log_info "Discovered ALB DNS via AWS CLI fallback: $ALB_DNS"
                                API_URL="http://$ALB_DNS"
                            else
                                log_warning "AWS CLI fallback could not determine ALB DNS."
                            fi
                        fi
                    fi
                fi
            else
                log_warning "AWS CLI fallback could not find an ECS cluster for environment '$ENVIRONMENT'."
            fi
        fi
    fi
    
    # Fetch EKS outputs
    if [ "${CONTAINER_TYPE:-ecs}" = "eks" ]; then
        EKS_DIR="$TERRAFORM_DIR/eks"
        if [ -d "$EKS_DIR" ] && command_exists terragrunt; then
            ORIG_DIR=$(pwd)
            cd "$EKS_DIR" 2>/dev/null || return 0
            EKS_CLUSTER_NAME=$(terragrunt output -raw cluster_name 2>/dev/null || echo "")
            cd "$ORIG_DIR" 2>/dev/null || true
        fi
        
        # Try to get service endpoint from kubectl if available
        if command_exists kubectl && kubectl config current-context >/dev/null 2>&1; then
            K8S_SERVICE_IP=$(kubectl get svc fru-api -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
            K8S_INGRESS_HOST=$(kubectl get ingress fru-api-ingress -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
            
            if [ -n "$K8S_INGRESS_HOST" ]; then
                API_URL="https://$K8S_INGRESS_HOST"
            elif [ -n "$K8S_SERVICE_IP" ]; then
                API_URL="http://$K8S_SERVICE_IP"
            fi
        fi
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
        local cache_script="${REPO_ROOT}/test/common_sh/test_cache.sh"
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

# Main execution (if run standalone)
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    # Source logger if not already sourced
    if [ -z "${log_info:-}" ]; then
        SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        source "$REPO_ROOT/run_scripts/shared/logger.sh" 2>/dev/null || true
    fi
    
    fetch_terraform_outputs
else
    # If sourced, just define the function
    fetch_terraform_outputs
fi

