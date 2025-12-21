#!/bin/bash
# Fetch deployment information from Terraform outputs
# Exports: ALB_DNS, CLOUDFRONT_DOMAIN, ECS_*, EKS_*, API_URL, FRONTEND_URL
# Usage: source fetch-deployment-info.sh <deployment-type> <environment> [api_url] [frontend_url] [dry-run]

# Get parameters
DEPLOYMENT_TYPE="${1:-${DEPLOYMENT_TYPE:-ecs-full}}"
ENVIRONMENT="${2:-${ENVIRONMENT:-dev}}"
API_URL="${3:-${API_URL:-}}"
FRONTEND_URL="${4:-${FRONTEND_URL:-}}"
DRY_RUN="${5:-${DRY_RUN:-false}}"

# Helper function to check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Fetch actual values from Terraform outputs (if not dry-run)
fetch_terraform_outputs() {
    if [ "$DRY_RUN" = "true" ]; then
        return 0
    fi
    
    # Initialize variables to empty (in case fetch fails)
    ALB_DNS=""
    CLOUDFRONT_DOMAIN=""
    ECS_CLUSTER_ID=""
    ECS_CLUSTER_NAME=""
    ECS_SERVICE_NAME=""
    EKS_CLUSTER_NAME=""
    K8S_SERVICE_IP=""
    K8S_INGRESS_HOST=""
    
    TERRAFORM_DIR="$REPO_ROOT/infra/terraform/environments/$ENVIRONMENT"
    
    # Fetch ECS/ALB outputs
    if [ "$DEPLOYMENT_TYPE" = "ecs-full" ] || [ "$DEPLOYMENT_TYPE" = "ecs" ]; then
        APP_DIR="$TERRAFORM_DIR/application"
        if [ -d "$APP_DIR" ] && command_exists terragrunt; then
            ORIG_DIR=$(pwd)
            cd "$APP_DIR" 2>/dev/null || return 0
            # Try to read outputs; on failure, log a warning instead of silently ignoring
            if ! ALB_DNS=$(terragrunt output -raw alb_dns_name 2>/dev/null); then
                ALB_DNS=""
                log_warning "Could not read Terraform output 'alb_dns_name' via terragrunt; API URL may be unavailable"
            fi
            if ! CLOUDFRONT_DOMAIN=$(terragrunt output -raw cloudfront_domain_name 2>/dev/null); then
                CLOUDFRONT_DOMAIN=""
                log_warning "Could not read Terraform output 'cloudfront_domain_name' via terragrunt; frontend URL may be unavailable"
            fi
            if ! ECS_CLUSTER_ID=$(terragrunt output -raw ecs_cluster_id 2>/dev/null); then
                ECS_CLUSTER_ID=""
                log_warning "Could not read Terraform output 'ecs_cluster_id' via terragrunt; ECS hints may be limited"
            fi
            if ! ECS_SERVICE_NAME=$(terragrunt output -raw ecs_service_name 2>/dev/null); then
                ECS_SERVICE_NAME=""
                log_warning "Could not read Terraform output 'ecs_service_name' via terragrunt; ECS hints may be limited"
            fi
            cd "$ORIG_DIR" 2>/dev/null || true
            
            # Extract cluster name from ARN if needed
            if [ -n "$ECS_CLUSTER_ID" ]; then
                ECS_CLUSTER_NAME=$(echo "$ECS_CLUSTER_ID" | awk -F'/' '{print $NF}' || echo "")
            fi
            
            # Set API_URL and FRONTEND_URL if not already set
            if [ -z "$API_URL" ] && [ -n "$ALB_DNS" ]; then
                API_URL="http://$ALB_DNS"
            fi
            if [ -z "$FRONTEND_URL" ] && [ -n "$CLOUDFRONT_DOMAIN" ]; then
                FRONTEND_URL="https://$CLOUDFRONT_DOMAIN"
            fi
        fi
    fi
    
    # Fetch EKS outputs
    if [ "$DEPLOYMENT_TYPE" = "eks-full" ] || [ "$DEPLOYMENT_TYPE" = "eks" ]; then
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
}

# Main execution (if run standalone)
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    # Source logger if not already sourced
    if [ -z "${log_info:-}" ]; then
        SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        source "$SCRIPT_DIR/../../common/logger.sh" 2>/dev/null || true
    fi
    
    fetch_terraform_outputs
else
    # If sourced, just define the function
    fetch_terraform_outputs
fi

