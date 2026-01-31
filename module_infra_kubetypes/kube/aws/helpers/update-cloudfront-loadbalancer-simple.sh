#!/bin/bash
# Update CloudFront via Terraform (EKS Helper Script - Simplified)
# =================================================================
# This script waits for a Kubernetes Service LoadBalancer to be ready and
# provides instructions for updating CloudFront via Terraform (instead of
# directly via AWS CLI). This is a simplified alternative to update-cloudfront-loadbalancer.sh.
#
# **Container Type**: EKS-specific (uses kubectl to get Service LoadBalancer DNS)
# **Location**: run_scripts/main_application_scripts/aws/eks/helpers/
#
# What it does:
#   1. Waits for Kubernetes Service LoadBalancer DNS to be available
#   2. Outputs instructions for updating Terraform with the ALB DNS
#   3. Does NOT directly update CloudFront (unlike update-cloudfront-loadbalancer.sh)
#
# Usage (standalone):
#   ./update-cloudfront-loadbalancer-simple.sh [service-name] [namespace]
#
# Example:
#   ./update-cloudfront-loadbalancer-simple.sh fru-api default
#
# Prerequisites:
#   - kubectl configured and pointing to EKS cluster
#   - Service with type LoadBalancer exists
#   - Terraform configuration ready to accept alb_dns_name variable

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../../../../.." && pwd)}"
source "$REPO_ROOT/orchestration/common/logger.sh"

SERVICE_NAME="${1:-fru-api}"
NAMESPACE="${2:-default}"

log_info "Waiting for LoadBalancer to be ready..."
log_info "Service: $SERVICE_NAME (namespace: $NAMESPACE)"

# Wait for LoadBalancer DNS (with timeout)
TIMEOUT=300  # 5 minutes
INTERVAL=10  # Check every 10 seconds
ELAPSED=0
LB_DNS=""

while [ $ELAPSED -lt $TIMEOUT ]; do
    LB_DNS=$(kubectl get svc -n "$NAMESPACE" "$SERVICE_NAME" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
    
    if [ -n "$LB_DNS" ] && [ "$LB_DNS" != "null" ]; then
        log_success "LoadBalancer DNS found: $LB_DNS"
        break
    fi
    
    if [ $((ELAPSED % 30)) -eq 0 ]; then
        log_info "Still waiting for LoadBalancer... (${ELAPSED}s / ${TIMEOUT}s)"
    fi
    
    sleep $INTERVAL
    ELAPSED=$((ELAPSED + INTERVAL))
done

if [ -z "$LB_DNS" ] || [ "$LB_DNS" = "null" ]; then
    log_error "Timeout: LoadBalancer DNS not available after ${TIMEOUT} seconds"
    log_info "Check Service status: kubectl get svc -n $NAMESPACE $SERVICE_NAME"
    exit 1
fi

log_info "LoadBalancer DNS: $LB_DNS"
log_info ""
log_info "To update CloudFront, run Terraform with alb_dns_name set:"
log_info "  cd module_infra_kubetypes/kube/aws/terra/environments/dev/eks"
log_info "  terragrunt apply -var='alb_dns_name=$LB_DNS'"
log_info ""
log_info "Or update terragrunt.hcl:"
log_info "  alb_dns_name = \"$LB_DNS\""

