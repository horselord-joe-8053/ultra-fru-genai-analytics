#!/bin/bash
# EKS-specific deployment information fetching
# Called indirectly via the common verification dispatcher in:
#   run_scripts/main_application_scripts/aws/verification/fetch-deployment-info.sh
#
# Purpose: Fetch EKS-specific deployment information from Terraform outputs and Kubernetes
# Type: Helper library (meant to be sourced)
# Usage: source this file, then call fetch_eks_deployment_info
#
# Prerequisites:
#   - logger.sh must be sourced by parent script
#   - TERRAFORM_DIR, ENVIRONMENT, REPO_ROOT must be set in parent scope
#   - terragrunt or kubectl must be available
#
# Sets variables in parent scope:
#   - EKS_CLUSTER_NAME: EKS cluster name
#   - CLOUDFRONT_DOMAIN: CloudFront distribution domain name
#   - K8S_SERVICE_IP: Kubernetes Service LoadBalancer hostname
#   - K8S_INGRESS_HOST: Kubernetes Ingress LoadBalancer hostname (NLB DNS)
#   - API_URL: API endpoint URL (http://$K8S_INGRESS_HOST or http://$K8S_SERVICE_IP)
#   - FRONTEND_URL: Frontend URL (https://$CLOUDFRONT_DOMAIN)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../../../.." && pwd)}"

# Source shared logger if not already available
if ! command -v log_info >/dev/null 2>&1; then
    # shellcheck source=/dev/null
    source "$REPO_ROOT/orchestration/common/logger.sh" 2>/dev/null || true
fi

# Helper function to check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Fetch EKS deployment information from Terraform outputs and Kubernetes
fetch_eks_deployment_info() {
    # TERRAFORM_DIR and ENVIRONMENT should be set by parent function
    local terraform_dir="${TERRAFORM_DIR:-}"
    
    if [ -z "$terraform_dir" ]; then
        log_warning "TERRAFORM_DIR not set, cannot fetch EKS deployment info"
        return 1
    fi
    
    # Fetch EKS cluster name from EKS terraform outputs
    local eks_dir="$terraform_dir/eks"
    if [ -d "$eks_dir" ] && command_exists terragrunt; then
        local orig_dir
        orig_dir=$(pwd)
        cd "$eks_dir" 2>/dev/null || return 0
        if [ -z "${EKS_CLUSTER_NAME:-}" ]; then
            log_info "Fetching Terraform output: cluster_name (from EKS module)"
            EKS_CLUSTER_NAME=$(terragrunt output -raw cluster_name 2>/dev/null || echo "")
            if [ -n "$EKS_CLUSTER_NAME" ]; then
                log_info "Output retrieved: cluster_name=$EKS_CLUSTER_NAME"
            else
                log_warning "Could not read Terraform output 'cluster_name' from EKS module"
            fi
        fi
        cd "$orig_dir" 2>/dev/null || true
    fi
    
    # Fetch CloudFront domain from eks terraform outputs (for EKS frontend)
    local app_dir="$terraform_dir/eks"
    if [ -d "$app_dir" ] && command_exists terragrunt; then
        local orig_dir
        orig_dir=$(pwd)
        cd "$app_dir" 2>/dev/null || return 0
        
        if [ -z "${CLOUDFRONT_DOMAIN:-}" ]; then
            log_info "Fetching Terraform output: cloudfront_domain_name (from eks module, for EKS)"
            # Fetch from eks module which has separate CloudFront distribution
            local terragrunt_error
            if ! CLOUDFRONT_DOMAIN=$(terragrunt output -raw cloudfront_domain_name 2>&1); then
                terragrunt_error="$CLOUDFRONT_DOMAIN"
                CLOUDFRONT_DOMAIN=""
                log_warning "Could not read Terraform output 'cloudfront_domain_name' via terragrunt (for EKS); frontend URL may be unavailable"
                if command -v log_info >/dev/null 2>&1 && [ -n "$terragrunt_error" ]; then
                    log_info "Terragrunt error: ${terragrunt_error:0:200}"
                fi
            else
                log_info "Output retrieved: cloudfront_domain_name=$CLOUDFRONT_DOMAIN"
            fi
        fi
        
        cd "$orig_dir" 2>/dev/null || true
    fi
    
    # Set FRONTEND_URL from discovered CloudFront domain
    if [ -n "$CLOUDFRONT_DOMAIN" ]; then
        FRONTEND_URL="https://$CLOUDFRONT_DOMAIN"
    fi
    
    # Try to get service endpoint from kubectl if available
    if command_exists kubectl && kubectl config current-context >/dev/null 2>&1; then
        # Determine namespace from environment or discover from pods
        local namespace="${NAMESPACE:-}"
        if [ -z "$namespace" ]; then
            # Try to discover namespace from existing pods
            namespace=$(kubectl get pods -l app=fru-api -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null | head -1 || echo "")
            if [ -z "$namespace" ]; then
                namespace="default"
            fi
        fi
        
        # Determine ingress name from environment or use default pattern
        local ingress_name="${INGRESS_NAME:-fru-api-ingress}"
        # Try namespace-specific ingress name pattern if namespace is not default
        if [ "$namespace" != "default" ]; then
            # Try namespace-specific ingress name first (e.g., fru-api-ingress-dev)
            if kubectl get ingress "fru-api-ingress-${namespace#fru-api-}" -n "$namespace" >/dev/null 2>&1; then
                ingress_name="fru-api-ingress-${namespace#fru-api-}"
            elif kubectl get ingress "fru-api-ingress" -n "$namespace" >/dev/null 2>&1; then
                ingress_name="fru-api-ingress"
            fi
        fi
        
        K8S_SERVICE_IP=$(kubectl get svc fru-api -n "$namespace" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
        K8S_INGRESS_HOST=$(kubectl get ingress "$ingress_name" -n "$namespace" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
        
        # EKS Ingress uses NGINX Ingress Controller, which creates an NLB (Network Load Balancer) on AWS.
        # NLBs use .elb.amazonaws.com DNS names and don't have SSL certificates by default
        # (unless configured with ACM), so always use HTTP. This matches ECS behavior for consistency.
        if [ -n "$K8S_INGRESS_HOST" ]; then
            API_URL="http://$K8S_INGRESS_HOST"
        elif [ -n "$K8S_SERVICE_IP" ]; then
            API_URL="http://$K8S_SERVICE_IP"
        fi
    fi
    
    return 0
}

# Main execution (if run standalone)
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    # Set up minimal environment for standalone execution
    if [ -z "${REPO_ROOT:-}" ]; then
        REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
    fi
    if [ -z "${TERRAFORM_DIR:-}" ]; then
        TERRAFORM_DIR="$REPO_ROOT/module_infra_kubetypes/kube/aws/terra/environments/${ENVIRONMENT:-dev}"
    fi
    fetch_eks_deployment_info
fi
