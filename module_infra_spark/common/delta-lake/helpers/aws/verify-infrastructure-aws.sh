#!/bin/bash
# Verify AWS S3 Delta table exists
# Gets S3 bucket info from Terraform and verifies Delta table

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../../../../../.." && pwd)}"
source "$REPO_ROOT/orchestration/shared/logger.sh"
source "$REPO_ROOT/orchestration/shared/load-env.sh"

ENVIRONMENT="${ENVIRONMENT:-dev}"

# Get S3 bucket info from Terraform outputs
if [ -z "$S3_BUCKET_ID" ]; then
    INFRASTRUCTURE_DIR="$REPO_ROOT/module_infra_basic/aws/environments/$ENVIRONMENT/infrastructure"
    if [ -d "$INFRASTRUCTURE_DIR" ]; then
        cd "$INFRASTRUCTURE_DIR"
        S3_BUCKET_ID=$(AWS_PROFILE="${AWS_PROFILE:-admin}" terragrunt output -raw s3_data_bucket_id 2>/dev/null || echo "")
        S3_DELTA_PATH=$(AWS_PROFILE="${AWS_PROFILE:-admin}" terragrunt output -raw s3_delta_table_path 2>/dev/null || echo "")
        cd "$REPO_ROOT"
    fi
fi

if [ -z "$S3_BUCKET_ID" ]; then
    log_error "Failed to get S3 bucket information from Terraform"
    exit 1
fi

# Verify S3 bucket is accessible
if ! aws s3 ls "s3://$S3_BUCKET_ID" --profile "${AWS_PROFILE:-admin}" >/dev/null 2>&1; then
    log_error "S3 bucket does not exist or is not accessible: $S3_BUCKET_ID"
    exit 1
fi

# Verify Delta table exists in S3 (uses Python helper)
if [ -n "$S3_DELTA_PATH" ]; then
    DELTA_TABLE_NAME="${DELTA_TABLE_NAME:-fru_sales}"
    DELTA_TABLE_PATH="$S3_DELTA_PATH/$DELTA_TABLE_NAME"
    
    if ! "$REPO_ROOT/module_infra_spark/common/delta-lake/helpers/check-delta-table-exists.sh" "$DELTA_TABLE_PATH" "s3" "true" "false" 2>/dev/null; then
        log_error "Delta table does not exist at: $DELTA_TABLE_PATH"
        exit 1
    fi
    
    log_success "Delta table verified at: $DELTA_TABLE_PATH"
fi

