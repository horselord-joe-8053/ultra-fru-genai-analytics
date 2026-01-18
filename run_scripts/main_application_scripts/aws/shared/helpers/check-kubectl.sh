#!/bin/bash
# kubectl installation and configuration checks
# Usage: check_kubectl_installation, check_kubectl_context, check_kubectl_cluster_access, check_kubectl_complete

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
check_kubectl_cluster_access() {
    log_info "Checking cluster accessibility..."
    if ! kubectl cluster-info >/dev/null 2>&1; then
        log_error "Cannot access EKS cluster"
        log_info "Verify your AWS credentials and cluster configuration"
        log_info "Try: kubectl cluster-info"
        return 1
    fi
    log_success "EKS cluster is accessible"
    return 0
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

