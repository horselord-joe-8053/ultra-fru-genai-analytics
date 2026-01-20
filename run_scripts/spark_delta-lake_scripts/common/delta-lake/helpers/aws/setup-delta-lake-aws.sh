#!/bin/bash
# Get S3 bucket info from Terraform outputs
# Outputs variables to temp file for caller to source

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../../../.." && pwd)"
source "$REPO_ROOT/run_scripts/shared/logger.sh"

ENVIRONMENT="${ENVIRONMENT:-dev}"
INFRASTRUCTURE_DIR="$REPO_ROOT/infra/terraform/providers/aws/environments/$ENVIRONMENT/infrastructure"

if [ ! -d "$INFRASTRUCTURE_DIR" ]; then
    log_error "Infrastructure Terraform directory not found: $INFRASTRUCTURE_DIR"
    exit 1
fi

cd "$INFRASTRUCTURE_DIR"

# Get S3 bucket info from Terraform outputs
S3_BUCKET_ID=$(AWS_PROFILE="${AWS_PROFILE:-admin}" terragrunt output -raw s3_data_bucket_id 2>/dev/null || echo "")
S3_BUCKET_ARN=$(AWS_PROFILE="${AWS_PROFILE:-admin}" terragrunt output -raw s3_bucket_arn 2>/dev/null || echo "")
S3_DELTA_PATH=$(AWS_PROFILE="${AWS_PROFILE:-admin}" terragrunt output -raw s3_delta_table_path 2>/dev/null || echo "")

# Fallback: Try to detect bucket from AWS account if Terraform output fails
if [ -z "$S3_BUCKET_ID" ]; then
    ACCOUNT_ID=$(aws sts get-caller-identity --profile "${AWS_PROFILE:-admin}" --query Account --output text 2>/dev/null || echo "")
    if [ -n "$ACCOUNT_ID" ]; then
        BUCKET_NAME="fru-${ENVIRONMENT}-analytics-data-${ACCOUNT_ID}"
        if aws s3 ls "s3://${BUCKET_NAME}" --profile "${AWS_PROFILE:-admin}" >/dev/null 2>&1; then
            S3_BUCKET_ID="$BUCKET_NAME"
            S3_BUCKET_ARN="arn:aws:s3:::${BUCKET_NAME}"
            S3_DELTA_PATH="s3://${BUCKET_NAME}/delta"
        fi
    fi
fi

# Output variables to temp file (caller will source this)
VARS_FILE="${TMPDIR:-/tmp}/data-lake-vars-$$"
echo "export S3_BUCKET_ID=\"$S3_BUCKET_ID\"" > "$VARS_FILE"
echo "export S3_BUCKET_ARN=\"$S3_BUCKET_ARN\"" >> "$VARS_FILE"
echo "export S3_DELTA_PATH=\"$S3_DELTA_PATH\"" >> "$VARS_FILE"
echo "$VARS_FILE"
