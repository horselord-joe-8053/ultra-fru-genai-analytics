#!/bin/bash
# Diagnostic script to check which S3 bucket the frontend is currently using
# Usage: ./reference_check_frontend_bucket.sh [--environment dev|prod]
#
# This script provides a comprehensive analysis by checking:
# 1. Terraform outputs (what Terraform says should be used)
# 2. CloudFront distribution origins (what CloudFront is actually using)
# 3. Bucket contents (which bucket has the latest frontend files)
# 4. Deployment script configuration (what deploy-frontend.sh would use)
#
# Use this script to diagnose frontend bucket issues or verify which bucket
# is actually serving the frontend application.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Script is in: run_scripts/main_application_scripts/aws/shared/cli/resource-check/
# Need to go up 6 levels to reach repo root
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../../../../../.." && pwd)}"
source "$REPO_ROOT/run_scripts/shared/logger.sh"
source "$REPO_ROOT/run_scripts/shared/load-env.sh"

AWS_PROFILE="${AWS_PROFILE:-admin}"
AWS_REGION="${AWS_REGION:-us-east-1}"
ENVIRONMENT="${ENVIRONMENT:-dev}"
PROJECT_NAME="fru"

# Get AWS account ID (using centralized resolution)
if [ -z "${AWS_ACCOUNT_ID:-}" ]; then
    source "$REPO_ROOT/run_scripts/shared/load-image-identifiers.sh"
    load_image_identifiers "aws" || exit 1
fi
# Use AWS_ACCOUNT_ID directly (no need for separate ACCOUNT_ID variable)

log_step "Frontend Bucket Checker"
log_info "Environment: $ENVIRONMENT"
log_info "Account ID: $AWS_ACCOUNT_ID"
log_info "Region: $AWS_REGION"
echo ""

# ============================================================================
# 1. Check Terraform Outputs
# ============================================================================
log_step "1. Terraform Outputs"
TERRAFORM_DIR="$REPO_ROOT/infra/terraform/providers/aws/environments/$ENVIRONMENT"
# Check ecs by default (for ECS deployments)
# For EKS, use eks
CONTAINER_TYPE="${CONTAINER_TYPE:-ecs}"
if [ "$CONTAINER_TYPE" = "eks" ]; then
    APP_DIR="$TERRAFORM_DIR/eks"
else
    APP_DIR="$TERRAFORM_DIR/ecs"
fi

terraform_bucket=""
if [ -d "$APP_DIR" ] && command -v terragrunt >/dev/null 2>&1; then
    ORIG_DIR=$(pwd)
    cd "$APP_DIR" 2>/dev/null || {
        log_warning "Could not access Terraform application directory"
        terraform_bucket="N/A (directory not accessible)"
    }
    if [ -z "$terraform_bucket" ] || [ "$terraform_bucket" != "N/A" ]; then
        terraform_bucket=$(terragrunt output -raw s3_bucket_id 2>/dev/null || echo "N/A (no output)")
    fi
    cd "$ORIG_DIR" 2>/dev/null || true
else
    terraform_bucket="N/A (terragrunt not found or directory missing)"
fi

if [ "$terraform_bucket" != "N/A"* ]; then
    log_success "  Terraform-managed bucket: $terraform_bucket"
else
    log_warning "  Terraform output: $terraform_bucket"
fi
echo ""

# ============================================================================
# 2. Check CloudFront Distribution Origins
# ============================================================================
log_step "2. CloudFront Distribution Origins"

# Find CloudFront distributions for this project
cloudfront_dists=$(aws cloudfront list-distributions --profile "$AWS_PROFILE" \
    --query "DistributionList.Items[?Comment=='${PROJECT_NAME}-${ENVIRONMENT}-frontend' || contains(Comment, '${PROJECT_NAME}-${ENVIRONMENT}')].{Id:Id,Comment:Comment}" \
    --output json 2>/dev/null || echo "[]")

dist_count=$(echo "$cloudfront_dists" | "$PYTHON_CMD" -c "import sys, json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")

if [ "$dist_count" -eq 0 ]; then
    log_warning "  No CloudFront distributions found for this project"
else
    log_info "  Found $dist_count CloudFront distribution(s):"
    echo "$cloudfront_dists" | "$PYTHON_CMD" -c "
import sys, json
dists = json.load(sys.stdin)
for dist in dists:
    print(f\"    - {dist['Id']} ({dist.get('Comment', 'N/A')})\")
" 2>/dev/null || log_info "    (Unable to parse)"
    
    # Get S3 origins from the first distribution
    first_dist_id=$(echo "$cloudfront_dists" | "$PYTHON_CMD" -c "import sys, json; dists=json.load(sys.stdin); print(dists[0]['Id'] if dists else '')" 2>/dev/null || echo "")
    
    if [ -n "$first_dist_id" ]; then
        log_info ""
        log_info "  Checking S3 origins for distribution: $first_dist_id"
        dist_config=$(aws cloudfront get-distribution-config --id "$first_dist_id" --profile "$AWS_PROFILE" --output json 2>/dev/null || echo "{}")
        
        s3_origins=$(echo "$dist_config" | "$PYTHON_CMD" -c "
import sys, json
try:
    config = json.load(sys.stdin)
    dist_config = config.get('DistributionConfig', {})
    origins = dist_config.get('Origins', {}).get('Items', [])
    for origin in origins:
        domain = origin.get('DomainName', '')
        origin_id = origin.get('Id', '')
        if 's3' in domain.lower() or origin_id.startswith('S3-'):
            # Extract bucket name from domain
            bucket = domain.split('.')[0] if '.' in domain else domain
            print(f\"    S3 Origin: {bucket} (origin-id: {origin_id})\")
            print(f\"    Domain: {domain}\")
except:
    pass
" 2>/dev/null || echo "")
        
        if [ -n "$s3_origins" ]; then
            log_info "$s3_origins"
        else
            log_warning "    No S3 origins found in CloudFront distribution"
        fi
    fi
fi
echo ""

# ============================================================================
# 3. Check Bucket Contents
# ============================================================================
log_step "3. Bucket Contents Check"

# Check Terraform-managed bucket (legacy single name and per-container-type names)
terraform_bucket_name="${PROJECT_NAME}-${ENVIRONMENT}-frontend-${AWS_ACCOUNT_ID}"
legacy_bucket_name="fru-frontend-bucket"

buckets_to_check=()
if [ "$terraform_bucket" != "N/A"* ] && [ -n "$terraform_bucket" ]; then
    buckets_to_check+=("$terraform_bucket")
fi
buckets_to_check+=("$terraform_bucket_name" "$legacy_bucket_name")

log_info "  Checking bucket contents and last modified dates:"
for bucket in "${buckets_to_check[@]}"; do
    if [ -z "$bucket" ] || [ "$bucket" = "N/A"* ]; then
        continue
    fi
    
    # Check if bucket exists
    if aws s3 ls --profile "$AWS_PROFILE" "s3://$bucket" >/dev/null 2>&1; then
        object_count=$(aws s3 ls "s3://$bucket" --profile "$AWS_PROFILE" --recursive 2>/dev/null | wc -l | tr -d ' ')
        
        # Get last modified file
        last_modified=$(aws s3 ls "s3://$bucket" --profile "$AWS_PROFILE" --recursive 2>/dev/null | sort -k1,2 | tail -1 || echo "")
        last_modified_date=$(echo "$last_modified" | awk '{print $1" "$2}' || echo "N/A")
        last_modified_file=$(echo "$last_modified" | awk '{print $4}' || echo "N/A")
        
        # Check if index.html exists
        has_index=$(aws s3 ls "s3://$bucket/index.html" --profile "$AWS_PROFILE" 2>/dev/null | wc -l | tr -d ' ')
        index_status=""
        if [ "$has_index" -gt 0 ]; then
            index_status="✓ has index.html"
        else
            index_status="✗ missing index.html"
        fi
        
        log_info "    [$bucket]"
        log_info "      Objects: $object_count"
        log_info "      Last modified: $last_modified_date ($last_modified_file)"
        log_info "      Status: $index_status"
        
        if [ "$bucket" = "$legacy_bucket_name" ]; then
            log_warning "      ⚠ LEGACY BUCKET (fallback in deploy-frontend.sh)"
        fi
        if [ "$bucket" = "$terraform_bucket_name" ]; then
            log_info "      ✓ TERRAFORM-MANAGED BUCKET"
        fi
    else
        log_info "    [$bucket] - Does not exist"
    fi
done
echo ""

# ============================================================================
# 4. Check Deployment Script Behavior
# ============================================================================
log_step "4. Deployment Script Behavior"
log_info "  What deploy-frontend.sh would use:"

if [ "$terraform_bucket" != "N/A"* ] && [ -n "$terraform_bucket" ]; then
    log_success "    Primary: $terraform_bucket (from Terraform output)"
    log_info "    Fallback: $legacy_bucket_name (if Terraform output unavailable)"
else
    log_warning "    Primary: N/A (Terraform output not available)"
    log_warning "    Fallback: $legacy_bucket_name (would be used)"
fi
echo ""

# ============================================================================
# Summary
# ============================================================================
log_step "Summary"
echo ""

# Determine which bucket is likely in use
likely_bucket=""
if [ "$terraform_bucket" != "N/A"* ] && [ -n "$terraform_bucket" ]; then
    likely_bucket="$terraform_bucket"
    log_success "✓ Most likely bucket in use: $likely_bucket"
    log_info "  (Terraform-managed, should be used by CloudFront)"
elif aws s3 ls --profile "$AWS_PROFILE" "s3://$terraform_bucket_name" >/dev/null 2>&1; then
    likely_bucket="$terraform_bucket_name"
    log_success "✓ Most likely bucket in use: $likely_bucket"
    log_info "  (Terraform-managed bucket exists, even if output not available)"
elif aws s3 ls --profile "$AWS_PROFILE" "s3://$legacy_bucket_name" >/dev/null 2>&1; then
    likely_bucket="$legacy_bucket_name"
    log_warning "⚠ Most likely bucket in use: $likely_bucket"
    log_warning "  (Legacy bucket - consider migrating to Terraform-managed bucket)"
else
    log_error "✗ No frontend buckets found!"
fi

echo ""
log_info "Recommendations:"
if [ -n "$likely_bucket" ] && [ "$likely_bucket" = "$legacy_bucket_name" ]; then
    log_warning "  - Migrate to Terraform-managed bucket: $terraform_bucket_name"
    log_info "  - Update deploy-frontend.sh to remove legacy fallback"
    log_info "  - After migration, you can safely delete: $legacy_bucket_name"
elif [ -n "$likely_bucket" ] && [ "$likely_bucket" = "$terraform_bucket_name" ]; then
    log_success "  - Using Terraform-managed bucket (recommended)"
    if aws s3 ls --profile "$AWS_PROFILE" "s3://$legacy_bucket_name" >/dev/null 2>&1; then
        log_info "  - Legacy bucket $legacy_bucket_name can be deleted if not needed"
    fi
fi
