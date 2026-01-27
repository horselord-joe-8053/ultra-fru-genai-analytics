#!/bin/bash
# EKS-specific service status check functions
# Called indirectly via the common verification dispatcher in:
#   run_scripts/main_application_scripts/aws/verification/check-service-status.sh
#
# Purpose: Check EKS pod status (running pods, kubectl connectivity, etc.)
# Type: Helper library (meant to be sourced)
# Usage: source this file, then call check_eks_pod_status
#
# Prerequisites:
#   - logger.sh must be sourced by parent script
#   - kubectl must be installed and configured with valid kubeconfig
#   - Kubernetes cluster must be accessible

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../../../.." && pwd)}"

# Source shared logger if not already available
if ! command -v log_info >/dev/null 2>&1; then
    # shellcheck source=/dev/null
    source "$REPO_ROOT/run_scripts/shared/logger.sh" 2>/dev/null || true
fi

# Helper function to check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Check EKS pod status
check_eks_pod_status() {
    if ! command_exists kubectl; then
        log_warning "kubectl not available; cannot check EKS pod status"
        return 1
    fi
    
    # Check if kubectl context is set
    if ! kubectl config current-context >/dev/null 2>&1; then
        log_warning "kubectl context not configured"
        return 1
    fi
    
    log_success "kubectl context is configured"
    
    # Determine namespace from environment or discover from pods
    local namespace="${NAMESPACE:-}"
    if [ -z "$namespace" ]; then
        # Try to discover namespace from existing pods
        namespace=$(kubectl get pods -l app=fru-api -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null | head -1 || echo "")
        if [ -z "$namespace" ]; then
            namespace="default"
        fi
    fi
    
    # Check pod status
    log_info "Checking pod status in namespace: $namespace..."
    local pods_running pods_total
    pods_running=$(kubectl get pods -l app=fru-api -n "$namespace" --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d ' ')
    pods_total=$(kubectl get pods -l app=fru-api -n "$namespace" --no-headers 2>/dev/null | wc -l | tr -d ' ')
    
    if [ "$pods_running" -gt 0 ]; then
        log_success "Pods running: $pods_running/$pods_total"
    else
        log_warning "No pods running yet (may still be deploying)"
    fi
}

# Main execution (if run standalone)
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    check_eks_pod_status "$@"
fi
