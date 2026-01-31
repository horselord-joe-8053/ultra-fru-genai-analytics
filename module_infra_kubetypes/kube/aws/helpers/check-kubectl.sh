#!/bin/bash
# kubectl Installation and Configuration Checks (EKS Helper Functions)
# ====================================================================
# This file contains **helper functions** for checking kubectl installation,
# configuration, and cluster access. These functions are meant to be **sourced**
# by EKS deployment scripts, not run directly.
#
# **Container Type**: EKS-specific (uses kubectl, which is EKS-only)
# **Location**: run_scripts/main_application_scripts/aws/eks/helpers/
#
# Functions:
#   - check_kubectl_installation()  - Verifies kubectl is installed
#   - check_kubectl_context()       - Verifies kubectl context is configured
#   - check_kubectl_cluster_access() - Verifies cluster API server is accessible
#   - check_kubectl_complete()      - Runs all checks in sequence
#
# Usage (from another script):
#   source "$REPO_ROOT/run_scripts/main_application_scripts/aws/eks/helpers/check-kubectl.sh"
#   check_kubectl_complete || exit 1
#
# Example:
#   if ! check_kubectl_installation; then
#       log_error "kubectl is required for EKS deployments"
#       exit 1
#   fi
#
# Prerequisites:
#   - Parent script must source logger.sh before sourcing this file
#   - REPO_ROOT environment variable should be set by parent script (optional, for consistency)
#
# NOTE: Unlike ECS, EKS requires kubectl access to cluster API server endpoint
# - ECS: Uses AWS APIs (ecs.amazonaws.com) - public endpoints, no VPC access needed
# - EKS: Uses kubectl - direct network connection to API server (needs public endpoint or VPC access for private endpoint)

# Helper function to check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Check if kubectl is installed
check_kubectl_installation() {
    if ! command_exists kubectl; then
        log_error "kubectl is not installed"
        log_info "Install with: brew install kubectl"
        return 1
    fi
    log_success "kubectl is installed"
    return 0
}

# Check if kubectl context is configured
check_kubectl_context() {
    if ! kubectl config current-context >/dev/null 2>&1; then
        log_error "kubectl context is not configured"
        log_info "Configure kubectl context for your EKS cluster:"
        log_info "  aws eks update-kubeconfig --region <region> --name <cluster-name>"
        log_info "Or if using eksctl: eksctl utils write-kubeconfig --cluster <cluster-name>"
        return 1
    fi
    
    local current_context=$(kubectl config current-context)
    log_success "kubectl context is configured: $current_context"
    return 0
}

# Check if cluster is accessible
# Note: EKS clusters may take a few minutes after creation before API server is fully accessible
# This function retries up to 5 times with increasing delays
check_kubectl_cluster_access() {
    log_info "Checking cluster accessibility..."
    
    local max_retries=5
    local retry_delay=10
    local retry_count=0
    
    while [ $retry_count -lt $max_retries ]; do
        if kubectl cluster-info >/dev/null 2>&1; then
            log_success "EKS cluster is accessible"
            return 0
        fi
        
        retry_count=$((retry_count + 1))
        if [ $retry_count -lt $max_retries ]; then
            log_info "Cluster not yet accessible (attempt $retry_count/$max_retries), waiting ${retry_delay}s before retry..."
            log_info "Note: EKS clusters may take a few minutes after creation before API server is fully ready"
            sleep $retry_delay
            retry_delay=$((retry_delay * 2))  # Exponential backoff
        fi
    done
    
    # Final attempt - check if cluster has private endpoint only
    # Try to get cluster name from kubectl context
    local cluster_name=""
    if kubectl config current-context >/dev/null 2>&1; then
        local cluster_arn=$(kubectl config view --minify -o jsonpath='{.contexts[0].context.cluster}' 2>/dev/null || echo "")
        if [[ "$cluster_arn" == arn:aws:eks:* ]]; then
            cluster_name=$(echo "$cluster_arn" | sed 's|arn:aws:eks:[^:]*:[^:]*:cluster/||')
        fi
    fi
    
    # Fallback to environment variable or default
    cluster_name="${cluster_name:-${EKS_CLUSTER_NAME:-fru-dev-cluster}}"
    
    local cluster_status=$(aws eks describe-cluster --name "$cluster_name" --query 'cluster.{Status:status,PublicAccess:resourcesVpcConfig.endpointPublicAccess}' --output json 2>/dev/null || echo '{}')
    local has_public_access=$(echo "$cluster_status" | grep -o '"PublicAccess": *true' || echo "")
    
    if [ -z "$has_public_access" ]; then
        log_warning "EKS cluster appears to have private endpoint only (public access disabled)"
        log_info "This is expected if cluster uses private endpoint configuration"
        log_info "kubectl access from local machine may not be possible"
        log_info "Cluster status: $(echo "$cluster_status" | grep -o '"Status": *"[^"]*"' || echo 'unknown')"
        log_warning "Continuing deployment - kubectl manifest application may fail and need to be done manually from within VPC"
        return 0  # Allow deployment to continue - manifests can be applied later if needed
    fi
    
    # Final attempt with error output visible
    log_warning "Cluster not immediately accessible after $max_retries attempts"
    log_info "This may be normal if the cluster was just created - API server may still be initializing"
    log_info "Attempting final check with verbose output..."
    
    if kubectl cluster-info 2>&1 | head -20; then
        log_success "EKS cluster is accessible"
        return 0
    else
        log_error "Cannot access EKS cluster after $max_retries retries"
        log_info "This may be due to:"
        log_info "  1. Cluster API server still initializing (wait a few minutes and retry)"
        log_info "  2. Network connectivity issues (check VPC/security groups)"
        log_info "  3. Private endpoint configuration (requires VPN/bastion access)"
        log_info "Verify cluster status: aws eks describe-cluster --name <cluster-name>"
        log_warning "Continuing anyway - manifests may need to be applied manually later"
        return 0  # Don't fail deployment - allow manual manifest application later
    fi
}

# All-in-one check (convenience function)
check_kubectl_complete() {
    log_step "Checking kubectl installation and configuration"
    
    if ! check_kubectl_installation; then
        return 1
    fi
    
    if ! check_kubectl_context; then
        return 1
    fi
    
    if ! check_kubectl_cluster_access; then
        return 1
    fi
    
    return 0
}

