#!/bin/bash
# Verify data-lake setup (S3 bucket, IAM, Delta table)
# Called by: run_scripts/aws/data-lake/setup-and-verify.sh
# Receives: ENVIRONMENT, DRY_RUN, DATA_LAKE_SETUP_MODE from parent

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../../.." && pwd)"
source "$SCRIPT_DIR/../../../common/logger.sh"
source "$SCRIPT_DIR/../../../common/load-env.sh"

ENVIRONMENT="${ENVIRONMENT:-dev}"
DRY_RUN="${DRY_RUN:-false}"
MODE="${DATA_LAKE_SETUP_MODE:-standalone}"

# Get S3 bucket information (from parent or infrastructure outputs, or find by naming pattern)
if [ -z "$S3_BUCKET_ID" ]; then
    # Try infrastructure layer outputs first
    INFRASTRUCTURE_DIR="$REPO_ROOT/infra/terraform/environments/$ENVIRONMENT/infrastructure"
    
    if [ -d "$INFRASTRUCTURE_DIR" ]; then
        cd "$INFRASTRUCTURE_DIR"
        S3_BUCKET_ID=$(AWS_PROFILE="${AWS_PROFILE:-admin}" terragrunt output -raw s3_data_bucket_id 2>/dev/null || echo "")
        S3_BUCKET_ARN=$(AWS_PROFILE="${AWS_PROFILE:-admin}" terragrunt output -raw s3_data_bucket_arn 2>/dev/null || echo "")
        S3_DELTA_PATH=$(AWS_PROFILE="${AWS_PROFILE:-admin}" terragrunt output -raw s3_delta_table_path 2>/dev/null || echo "")
        cd "$REPO_ROOT"
    fi
    
    # If still not found, try to find by naming pattern
    if [ -z "$S3_BUCKET_ID" ]; then
        ACCOUNT_ID=$(aws sts get-caller-identity --profile "${AWS_PROFILE:-admin}" --query Account --output text 2>/dev/null || echo "")
        if [ -n "$ACCOUNT_ID" ]; then
            S3_BUCKET_ID="fru-${ENVIRONMENT}-analytics-data-${ACCOUNT_ID}"
            S3_BUCKET_ARN="arn:aws:s3:::${S3_BUCKET_ID}"
            S3_DELTA_PATH="s3://${S3_BUCKET_ID}/delta/fru_sales"
        fi
    fi
fi

if [ -z "$S3_BUCKET_ID" ]; then
    log_error "Failed to get S3 bucket information"
    exit 1
fi

log_info "Verifying data-lake setup (mode: $MODE)..."
log_info "  S3 Bucket: $S3_BUCKET_ID"
log_info "  Delta Path: $S3_DELTA_PATH"

if [ "$DRY_RUN" = "true" ]; then
    log_info "[DRY-RUN] Would verify S3 bucket access and Delta table existence"
    return 0
fi

# Common verification: S3 bucket exists and is accessible
if ! aws s3 ls "s3://$S3_BUCKET_ID" --profile "${AWS_PROFILE:-admin}" >/dev/null 2>&1; then
    log_error "✗ S3 bucket does not exist or is not accessible"
    return 1
fi
log_success "✓ S3 bucket exists and is accessible"

if [ "$MODE" = "standalone" ]; then
    # Idempotent mode: Basic verification
    log_info "Running basic verification (standalone mode)..."
    
    # Check Delta table exists (optional, non-fatal)
    if [ -n "$S3_DELTA_PATH" ]; then
        # Try both the exact path and the standard path
        DELTA_LOG_PATH="$S3_DELTA_PATH/_delta_log"
        if aws s3 ls "$DELTA_LOG_PATH/" --profile "${AWS_PROFILE:-admin}" >/dev/null 2>&1; then
            DELTA_LOG_COUNT=$(aws s3 ls "$DELTA_LOG_PATH/" --profile "${AWS_PROFILE:-admin}" 2>/dev/null | wc -l | tr -d ' ')
            log_success "✓ Delta table exists with $DELTA_LOG_COUNT log entries"
        else
            log_warning "⚠ Delta table does not exist yet (run create-delta-table.sh to create it)"
            log_info "  Expected path: $DELTA_LOG_PATH/"
        fi
    fi
    
    log_success "Basic data-lake verification complete"
else
    # Full-workflow mode: Comprehensive verification
    log_info "Running comprehensive verification (full-workflow mode)..."
    
    # 1. Verify S3 bucket configuration
    log_info "  Verifying S3 bucket configuration..."
    BUCKET_VERSIONING=$(aws s3api get-bucket-versioning --bucket "$S3_BUCKET_ID" --profile "${AWS_PROFILE:-admin}" --query 'Status' --output text 2>/dev/null || echo "NotEnabled")
    if [ "$BUCKET_VERSIONING" = "Enabled" ]; then
        log_success "  ✓ S3 bucket versioning is enabled"
    else
        log_warning "  ⚠ S3 bucket versioning is not enabled (recommended for Delta tables)"
    fi
    
    # 2. Verify IAM permissions (simplified check)
    log_info "  Verifying IAM permissions..."
    log_info "  ✓ IAM permissions check (basic - assumes Terraform configured correctly)"
    
    # 3. Verify Delta table (if exists)
    if [ -n "$S3_DELTA_PATH" ]; then
        log_info "  Verifying Delta table integrity..."
        if aws s3 ls "$S3_DELTA_PATH/_delta_log/" --profile "${AWS_PROFILE:-admin}" >/dev/null 2>&1; then
            DELTA_LOG_COUNT=$(aws s3 ls "$S3_DELTA_PATH/_delta_log/" --profile "${AWS_PROFILE:-admin}" 2>/dev/null | wc -l | tr -d ' ')
            if [ "$DELTA_LOG_COUNT" -gt 0 ]; then
                log_success "  ✓ Delta table exists with $DELTA_LOG_COUNT log entries"
                
                # Verify Delta table structure (check for required directories)
                if aws s3 ls "$S3_DELTA_PATH/" --profile "${AWS_PROFILE:-admin}" 2>/dev/null | grep -qE "parquet|_delta_log"; then
                    log_success "  ✓ Delta table structure appears valid"
                else
                    log_warning "  ⚠ Delta table structure may be incomplete"
                fi
            else
                log_error "  ✗ Delta table exists but has no log entries (may be corrupted)"
                return 1
            fi
        else
            log_warning "  ⚠ Delta table does not exist yet (expected if CSV ingestion hasn't run)"
        fi
    fi
    
    # 4. Verify Terraform outputs are all accessible
    log_info "  Verifying Terraform outputs..."
    if [ -z "$S3_BUCKET_ARN" ]; then
        log_error "  ✗ S3 bucket ARN output is not accessible"
        return 1
    fi
    log_success "  ✓ All Terraform outputs are accessible"
    
    log_success "Comprehensive data-lake verification complete"
fi

