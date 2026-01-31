#!/bin/bash
# Update CloudFront with EKS Ingress ALB (EKS Helper Script)
# ===========================================================
# This script updates a CloudFront distribution to point API paths to the ALB
# created by a Kubernetes Ingress resource. The Ingress automatically creates
# an ALB via the AWS Load Balancer Controller.
#
# **Container Type**: EKS-specific (uses kubectl to get Ingress ALB DNS)
# **Location**: run_scripts/main_application_scripts/aws/eks/helpers/
#
# What it does:
#   1. Waits for Ingress ALB DNS to be available (via kubectl)
#   2. Updates CloudFront distribution origin to use the ALB DNS
#   3. Configures cache behaviors for API paths (/query, /analytics, /query/stream)
#
# Usage (standalone):
#   ./update-cloudfront-loadbalancer.sh [ingress-name] [namespace] [cloudfront-distribution-id]
#
# Usage (from another script):
#   "$REPO_ROOT/run_scripts/main_application_scripts/aws/eks/helpers/update-cloudfront-loadbalancer.sh" \
#     "$ingress_name" "$namespace" "$cf_dist_id"
#
# Example:
#   ./update-cloudfront-loadbalancer.sh fru-api-ingress default E33TA1D0OAYUNR
#
# Prerequisites:
#   - kubectl configured and pointing to EKS cluster
#   - Ingress resource exists and AWS Load Balancer Controller is installed
#   - CloudFront distribution ID available (from Terraform or argument)
#   - AWS CLI configured with CloudFront permissions

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
    log_warning "CloudFront distribution ID not found. Skipping automatic CloudFront update."
    log_warning "You can manually wire CloudFront to the EKS LoadBalancer later if needed."
    # Do not fail the overall deployment just because CloudFront wiring is unavailable.
    exit 0
fi

log_info "Waiting for Ingress ALB to be ready..."
log_info "Ingress: $INGRESS_NAME (namespace: $NAMESPACE)"
log_info "CloudFront Distribution: $CF_DIST_ID"

# Wait for Ingress ALB DNS (with timeout)
# Note: Ingress creates ALB automatically via AWS Load Balancer Controller
TIMEOUT=300  # 5 minutes (ALB creation can take 2-3 minutes)
INTERVAL=10  # Check every 10 seconds
ELAPSED=0
LB_DNS=""

while [ $ELAPSED -lt $TIMEOUT ]; do
    # Get ALB DNS from Ingress (not Service - Service is ClusterIP)
    LB_DNS=$(kubectl get ingress -n "$NAMESPACE" "$INGRESS_NAME" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
    
    if [ -n "$LB_DNS" ] && [ "$LB_DNS" != "null" ]; then
        log_success "Ingress ALB DNS found: $LB_DNS"
        break
    fi
    
    if [ $((ELAPSED % 30)) -eq 0 ]; then
        log_info "Still waiting for Ingress ALB... (${ELAPSED}s / ${TIMEOUT}s)"
    fi
    
    sleep $INTERVAL
    ELAPSED=$((ELAPSED + INTERVAL))
done

if [ -z "$LB_DNS" ] || [ "$LB_DNS" = "null" ]; then
    log_error "Timeout: Ingress ALB DNS not available after ${TIMEOUT} seconds"
    log_info "Check Ingress status: kubectl get ingress -n $NAMESPACE $INGRESS_NAME"
    log_info "Note: ALB is created automatically by AWS Load Balancer Controller when Ingress is applied"
    exit 1
fi

log_info "Updating CloudFront distribution with LoadBalancer DNS..."
log_info "LoadBalancer DNS: $LB_DNS"

# Get current CloudFront distribution config
log_info "Fetching current CloudFront configuration..."
CF_CONFIG=$(aws cloudfront get-distribution-config --id "$CF_DIST_ID" --profile "${AWS_PROFILE:-admin}" 2>/dev/null || {
    log_error "Failed to fetch CloudFront distribution config"
    exit 1
})

ETAG=$(echo "$CF_CONFIG" | jq -r '.ETag')
CF_DIST_CONFIG=$(echo "$CF_CONFIG" | jq -r '.DistributionConfig')

# Update or add LoadBalancer origin in CloudFront config
log_info "Updating LoadBalancer origin in CloudFront config..."
ORIGIN_ID="ALB-fru-dev-eks"  # Match Terraform's api_origin_id format
UPDATED_CONFIG=$(echo "$CF_DIST_CONFIG" | jq --arg lb_dns "$LB_DNS" --arg origin_id "$ORIGIN_ID" '
  # Check if ALB/LB origin already exists
  . as $config |
  if ($config.Origins.Items | map(select(.Id | startswith("ALB-") or startswith("LB-"))) | length > 0) then
    # Update existing ALB/LB origin
    $config | .Origins.Items = (.Origins.Items | map(
      if (.Id | startswith("ALB-") or startswith("LB-")) then
        .DomainName = $lb_dns
      else
        .
      end
    ))
  else
    # Add new LoadBalancer origin
    $config | .Origins.Items += [{
      "Id": $origin_id,
      "DomainName": $lb_dns,
      "CustomOriginConfig": {
        "HTTPPort": 80,
        "HTTPSPort": 443,
        "OriginProtocolPolicy": "http-only",
        "OriginSslProtocols": {
          "Quantity": 1,
          "Items": ["TLSv1.2"]
        },
        "OriginReadTimeout": 60,
        "OriginKeepaliveTimeout": 5
      }
    }] |
    .Origins.Quantity = (.Origins.Items | length)
  end |
  # Add ordered cache behaviors for API routes if they don't exist
  if (.OrderedCacheBehaviors.Quantity == 0) then
    .OrderedCacheBehaviors.Quantity = 3 |
    .OrderedCacheBehaviors.Items = [
      {
        "PathPattern": "/query",
        "TargetOriginId": $origin_id,
        "ForwardedValues": {
          "QueryString": true,
          "Cookies": {"Forward": "all"}
        },
        "TrustedSigners": {"Enabled": false, "Quantity": 0},
        "ViewerProtocolPolicy": "redirect-to-https",
        "MinTTL": 0,
        "DefaultTTL": 0,
        "MaxTTL": 0,
        "Compress": true,
        "AllowedMethods": {
          "Quantity": 7,
          "Items": ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"],
          "CachedMethods": {"Quantity": 2, "Items": ["GET", "HEAD"]}
        }
      },
      {
        "PathPattern": "/analytics",
        "TargetOriginId": $origin_id,
        "ForwardedValues": {
          "QueryString": true,
          "Cookies": {"Forward": "all"}
        },
        "TrustedSigners": {"Enabled": false, "Quantity": 0},
        "ViewerProtocolPolicy": "redirect-to-https",
        "MinTTL": 0,
        "DefaultTTL": 0,
        "MaxTTL": 0,
        "Compress": true,
        "AllowedMethods": {
          "Quantity": 3,
          "Items": ["GET", "HEAD", "OPTIONS"],
          "CachedMethods": {"Quantity": 2, "Items": ["GET", "HEAD"]}
        }
      },
      {
        "PathPattern": "/query/stream",
        "TargetOriginId": $origin_id,
        "ForwardedValues": {
          "QueryString": true,
          "Cookies": {"Forward": "all"}
        },
        "TrustedSigners": {"Enabled": false, "Quantity": 0},
        "ViewerProtocolPolicy": "redirect-to-https",
        "MinTTL": 0,
        "DefaultTTL": 0,
        "MaxTTL": 0,
        "Compress": true,
        "AllowedMethods": {
          "Quantity": 3,
          "Items": ["GET", "HEAD", "OPTIONS"],
          "CachedMethods": {"Quantity": 2, "Items": ["GET", "HEAD"]}
        }
      }
    ]
  else
    # Update existing cache behaviors to use new origin
    .OrderedCacheBehaviors.Items = (.OrderedCacheBehaviors.Items | map(
      if (.PathPattern == "/query" or .PathPattern == "/analytics" or .PathPattern == "/query/stream") then
        .TargetOriginId = $origin_id
      else
        .
      end
    ))
  end
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
log_info "LoadBalancer DNS: $LB_DNS"
log_info "Note: CloudFront changes take 5-15 minutes to propagate globally"
log_info "Check status: aws cloudfront get-distribution --id $CF_DIST_ID --profile ${AWS_PROFILE:-admin}"

