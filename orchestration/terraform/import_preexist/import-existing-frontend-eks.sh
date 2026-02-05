#!/bin/bash
#
# Import existing frontend-eks layer resources into Terraform state (CloudFront OAC, optionally S3, CloudFront distribution).
#
# PURPOSE:
#   When resources (e.g. CloudFront Origin Access Control) already exist in AWS but are not in
#   Terraform state (e.g. left after brutal teardown or partial destroy), apply fails with
#   "OriginAccessControlAlreadyExists" or similar. This script imports those resources so apply can succeed.
#
# Safe to run always: non-existent resources are skipped; already-in-state resources are skipped.
#
# USAGE:
#   ./import-existing-frontend-eks.sh [dev|prod] [project_name]
#
#   Examples:
#     ./import-existing-frontend-eks.sh dev
#     ./import-existing-frontend-eks.sh prod fru
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common/lib_import_common.sh"

import_parse_args "$@"
import_validate_env

FRONTEND_EKS_DIR="$REPO_ROOT/module_infra_frontend/aws/terra/environments/$ENVIRONMENT/frontend-eks"
AWS_PROFILE="${AWS_PROFILE:-admin}"
AWS_REGION="${AWS_REGION:-us-east-1}"

log_step "Importing existing frontend-eks resources into Terraform state"
log_info "Environment: $ENVIRONMENT  Project: $PROJECT_NAME"
log_info "Dir: $FRONTEND_EKS_DIR"

import_ensure_dir_and_cd "$FRONTEND_EKS_DIR" "frontend-eks"
import_init_soft

export AWS_PROFILE="${AWS_PROFILE:-admin}"

# 1. CloudFront Origin Access Control (OAC) - import by OAC ID (look up by name)
OAC_NAME="${PROJECT_NAME}-${ENVIRONMENT}-frontend-eks-oac"
OAC_ID=$(aws cloudfront list-origin-access-controls --profile "$AWS_PROFILE" \
    --query "OriginAccessControlList.Items[?Name=='$OAC_NAME'].Id | [0]" --output text 2>/dev/null || echo "")
OAC_WAS_IN_AWS=false
if [ -n "$OAC_ID" ] && [ "$OAC_ID" != "None" ]; then
    OAC_WAS_IN_AWS=true
    log_info "Importing aws_cloudfront_origin_access_control.frontend ($OAC_NAME, id=$OAC_ID)..."
    if ! import_one_resource "aws_cloudfront_origin_access_control.frontend" "$OAC_ID"; then
        log_error "OAC exists in AWS but import failed. Apply would fail with OriginAccessControlAlreadyExists."
        log_info "Fix: run this script from repo root with same AWS_PROFILE, or import manually: terragrunt import aws_cloudfront_origin_access_control.frontend $OAC_ID"
        exit 1
    fi
else
    log_info "  Skip OAC (not found in AWS): $OAC_NAME"
fi

# 2. S3 bucket - import by bucket name (if exists and not in state)
BUCKET_NAME="${PROJECT_NAME}-${ENVIRONMENT}-frontend-eks-$(aws sts get-caller-identity --profile "$AWS_PROFILE" --query Account --output text 2>/dev/null || echo '')"
if [ -n "$BUCKET_NAME" ] && [ "$BUCKET_NAME" != "${PROJECT_NAME}-${ENVIRONMENT}-frontend-eks-" ]; then
    if aws s3api head-bucket --bucket "$BUCKET_NAME" --profile "$AWS_PROFILE" 2>/dev/null; then
        log_info "Importing aws_s3_bucket.frontend ($BUCKET_NAME)..."
        import_one_resource "aws_s3_bucket.frontend" "$BUCKET_NAME"
    else
        log_info "  Skip S3 bucket (not found): $BUCKET_NAME"
    fi
fi

# 3. CloudFront distribution - import by distribution ID (look up by comment/tag)
CF_COMMENT="${PROJECT_NAME}-${ENVIRONMENT}-frontend-eks"
CF_ID=$(aws cloudfront list-distributions --profile "$AWS_PROFILE" \
    --query "DistributionList.Items[?Comment=='$CF_COMMENT'].Id | [0]" --output text 2>/dev/null || echo "")
if [ -n "$CF_ID" ] && [ "$CF_ID" != "None" ]; then
    log_info "Importing aws_cloudfront_distribution.frontend ($CF_ID)..."
    import_one_resource "aws_cloudfront_distribution.frontend" "$CF_ID"
else
    log_info "  Skip CloudFront distribution (not found for comment $CF_COMMENT)"
fi

# Verify: only fail if we found OAC in AWS and imported it, but it is not in state (use state list, not plan).
if [ "$OAC_WAS_IN_AWS" = true ]; then
    log_info "Verifying OAC is in state: terragrunt state list..."
    state_list="$(terragrunt state list -no-color 2>/dev/null || true)"
    if echo "$state_list" | grep -q "aws_cloudfront_origin_access_control.frontend"; then
        log_success "  OAC is in state; import verified."
    else
        log_error "OAC was imported but is not in state (state list does not show aws_cloudfront_origin_access_control.frontend)."
        log_error "This can happen if import ran in a different backend/cache than apply. Run from frontend-eks dir:"
        log_error "  cd $FRONTEND_EKS_DIR"
        log_error "  terragrunt import aws_cloudfront_origin_access_control.frontend $OAC_ID"
        log_error "Then re-run deploy."
        exit 1
    fi
else
    log_info "OAC was not in AWS; plan may show OAC will be created (expected). Skipping OAC verification."
fi

log_success "Frontend-eks import phase completed."
log_info "Run 'terragrunt plan' in $FRONTEND_EKS_DIR to verify, then 'terragrunt apply' to continue."
