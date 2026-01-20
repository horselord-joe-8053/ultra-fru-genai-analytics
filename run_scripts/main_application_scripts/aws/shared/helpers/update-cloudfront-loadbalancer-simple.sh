#!/bin/bash
# Simplified: Update CloudFront via Terraform instead of AWS CLI
# This is cleaner - update Terraform variable and let Terraform manage CloudFront

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../../../../.." && pwd)}"
source "$REPO_ROOT/run_scripts/shared/logger.sh"

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
log_info "  cd infra/terraform/providers/aws/environments/dev/eks"
log_info "  terragrunt apply -var='alb_dns_name=$LB_DNS'"
log_info ""
log_info "Or update terragrunt.hcl:"
log_info "  alb_dns_name = \"$LB_DNS\""

