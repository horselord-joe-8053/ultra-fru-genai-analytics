#!/bin/bash
# Update CloudFront with EKS Ingress ALB (EKS Helper Script - Legacy)
# =====================================================================
# This script updates a CloudFront distribution to point to the ALB created
# by a Kubernetes Ingress. This is a legacy/alternative version of
# update-cloudfront-loadbalancer.sh.
#
# **Container Type**: EKS-specific (uses kubectl to get Ingress ALB DNS)
# **Location**: run_scripts/main_application_scripts/aws/eks/helpers/
#
# NOTE: This script may be redundant with update-cloudfront-loadbalancer.sh.
# Consider using update-cloudfront-loadbalancer.sh instead, which has more
# comprehensive cache behavior configuration.
#
# Usage (standalone):
#   ./update-cloudfront-alb.sh [ingress-name] [namespace] [cloudfront-distribution-id]
#
# Example:
#   ./update-cloudfront-alb.sh fru-api-ingress default E33TA1D0OAYUNR
#
# Prerequisites:
#   - kubectl configured and pointing to EKS cluster
#   - Ingress resource exists and AWS Load Balancer Controller is installed
#   - CloudFront distribution ID available (from Terraform or argument)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../../../../.." && pwd)}"
source "$REPO_ROOT/orchestration/shared/logger.sh"

INGRESS_NAME="${1:-fru-api-ingress}"
NAMESPACE="${2:-default}"
CF_DIST_ID="${3:-}"

# Get CloudFront distribution ID from Terraform if not provided
if [ -z "$CF_DIST_ID" ]; then
    log_info "Getting CloudFront distribution ID from Terraform..."
    terraform_dir="${REPO_ROOT}/module_infra_kube/aws/environments/dev/eks"
    if [ -d "$terraform_dir" ] && command -v terragrunt >/dev/null 2>&1; then
        # Try to get distribution ID directly
        CF_DIST_ID=$(cd "$terraform_dir" && AWS_PROFILE="${AWS_PROFILE:-admin}" terragrunt output -raw cloudfront_distribution_id 2>/dev/null || echo "")
        
        # If not available, look up by domain name
        if [ -z "$CF_DIST_ID" ]; then
            CF_DOMAIN=$(cd "$terraform_dir" && AWS_PROFILE="${AWS_PROFILE:-admin}" terragrunt output -raw cloudfront_domain_name 2>/dev/null || echo "")
            if [ -n "$CF_DOMAIN" ]; then
                log_info "Looking up CloudFront distribution ID by domain name: $CF_DOMAIN"
                CF_DIST_ID=$(aws cloudfront list-distributions --profile "${AWS_PROFILE:-admin}" --query "DistributionList.Items[?DomainName=='${CF_DOMAIN}'].Id" --output text 2>/dev/null || echo "")
            fi
        fi
    fi
fi

if [ -z "$CF_DIST_ID" ]; then
    log_error "CloudFront distribution ID not found. Please provide as argument or ensure Terraform outputs are available."
    exit 1
fi

log_info "Waiting for Ingress ALB to be ready..."
log_info "Ingress: $INGRESS_NAME (namespace: $NAMESPACE)"
log_info "CloudFront Distribution: $CF_DIST_ID"

# Wait for ALB DNS (with timeout)
TIMEOUT=600  # 10 minutes
INTERVAL=10  # Check every 10 seconds
ELAPSED=0
ALB_DNS=""

while [ $ELAPSED -lt $TIMEOUT ]; do
    ALB_DNS=$(kubectl get ingress -n "$NAMESPACE" "$INGRESS_NAME" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
    
    if [ -n "$ALB_DNS" ] && [ "$ALB_DNS" != "null" ]; then
        log_success "ALB DNS found: $ALB_DNS"
        break
    fi
    
    if [ $((ELAPSED % 30)) -eq 0 ]; then
        log_info "Still waiting for ALB... (${ELAPSED}s / ${TIMEOUT}s)"
    fi
    
    sleep $INTERVAL
    ELAPSED=$((ELAPSED + INTERVAL))
done

if [ -z "$ALB_DNS" ] || [ "$ALB_DNS" = "null" ]; then
    log_error "Timeout: ALB DNS not available after ${TIMEOUT} seconds"
    log_info "Check Ingress status: kubectl get ingress -n $NAMESPACE $INGRESS_NAME"
    exit 1
fi

log_info "Updating CloudFront distribution with ALB DNS..."
log_info "ALB DNS: $ALB_DNS"

# Get current CloudFront distribution config
log_info "Fetching current CloudFront configuration..."
CF_CONFIG=$(aws cloudfront get-distribution-config --id "$CF_DIST_ID" --profile "${AWS_PROFILE:-admin}" 2>/dev/null || {
    log_error "Failed to fetch CloudFront distribution config"
    exit 1
})

ETAG=$(echo "$CF_CONFIG" | jq -r '.ETag')
CF_DIST_CONFIG=$(echo "$CF_CONFIG" | jq -r '.DistributionConfig')

# Update ALB origin in CloudFront config
log_info "Updating ALB origin in CloudFront config..."
UPDATED_CONFIG=$(echo "$CF_DIST_CONFIG" | jq --arg alb_dns "$ALB_DNS" '
  .Origins.Items = (.Origins.Items | map(
    if .Id | startswith("ALB-") then
      .DomainName = $alb_dns
    else
      .
    end
  ))
')

# Update CloudFront distribution
log_info "Applying CloudFront configuration update..."
aws cloudfront update-distribution \
    --id "$CF_DIST_ID" \
    --if-match "$ETAG" \
    --distribution-config "$UPDATED_CONFIG" \
    --profile "${AWS_PROFILE:-admin}" > /dev/null 2>&1 || {
    log_error "Failed to update CloudFront distribution"
    exit 1
}

log_success "CloudFront distribution updated successfully!"
log_info "Distribution ID: $CF_DIST_ID"
log_info "ALB DNS: $ALB_DNS"
log_info "Note: CloudFront changes take 5-15 minutes to propagate globally"
log_info "Check status: aws cloudfront get-distribution --id $CF_DIST_ID --profile ${AWS_PROFILE:-admin}"

