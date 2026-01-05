#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../../../.." && pwd)"
source "$SCRIPT_DIR/../../../logger.sh"
source "$SCRIPT_DIR/../../../load-env.sh"

ENVIRONMENT="${ENVIRONMENT:-dev}"
MODE="${DATA_LAKE_SETUP_MODE:-standalone}"
INFRASTRUCTURE_DIR="$REPO_ROOT/infra/terraform/environments/$ENVIRONMENT/infrastructure"

if [ ! -d "$INFRASTRUCTURE_DIR" ]; then
    log_error "Infrastructure Terraform directory not found: $INFRASTRUCTURE_DIR"
    exit 1
fi

cd "$INFRASTRUCTURE_DIR"

if [ "$MODE" = "standalone" ]; then
    if AWS_PROFILE="${AWS_PROFILE:-admin}" terragrunt output s3_data_bucket_id >/dev/null 2>&1; then
        S3_BUCKET_ID=$(AWS_PROFILE="${AWS_PROFILE:-admin}" terragrunt output -raw s3_data_bucket_id 2>/dev/null || echo "")
        S3_BUCKET_ARN=$(AWS_PROFILE="${AWS_PROFILE:-admin}" terragrunt output -raw s3_data_bucket_arn 2>/dev/null || echo "")
        S3_DELTA_PATH=$(AWS_PROFILE="${AWS_PROFILE:-admin}" terragrunt output -raw s3_delta_table_path 2>/dev/null || echo "")
        VARS_FILE="${TMPDIR:-/tmp}/data-lake-vars-$$"
        echo "export S3_BUCKET_ID=\"$S3_BUCKET_ID\"" > "$VARS_FILE"
        echo "export S3_BUCKET_ARN=\"$S3_BUCKET_ARN\"" >> "$VARS_FILE"
        echo "export S3_DELTA_PATH=\"$S3_DELTA_PATH\"" >> "$VARS_FILE"
        echo "$VARS_FILE"
        exit 0
    fi
    ACCOUNT_ID=$(aws sts get-caller-identity --profile "${AWS_PROFILE:-admin}" --query Account --output text 2>/dev/null || echo "")
    if [ -n "$ACCOUNT_ID" ]; then
        BUCKET_NAME="fru-${ENVIRONMENT}-analytics-data-${ACCOUNT_ID}"
        if aws s3 ls "s3://${BUCKET_NAME}" --profile "${AWS_PROFILE:-admin}" >/dev/null 2>&1; then
            S3_BUCKET_ID="$BUCKET_NAME"
            S3_BUCKET_ARN="arn:aws:s3:::${BUCKET_NAME}"
            S3_DELTA_PATH="s3://${BUCKET_NAME}/delta"
            VARS_FILE="${TMPDIR:-/tmp}/data-lake-vars-$$"
            echo "export S3_BUCKET_ID=\"$S3_BUCKET_ID\"" > "$VARS_FILE"
            echo "export S3_BUCKET_ARN=\"$S3_BUCKET_ARN\"" >> "$VARS_FILE"
            echo "export S3_DELTA_PATH=\"$S3_DELTA_PATH\"" >> "$VARS_FILE"
            echo "$VARS_FILE"
            exit 0
        fi
    fi
fi

S3_BUCKET_ID=$(AWS_PROFILE="${AWS_PROFILE:-admin}" terragrunt output -raw s3_data_bucket_id 2>/dev/null || echo "")
S3_BUCKET_ARN=$(AWS_PROFILE="${AWS_PROFILE:-admin}" terragrunt output -raw s3_data_bucket_arn 2>/dev/null || echo "")
S3_DELTA_PATH=$(AWS_PROFILE="${AWS_PROFILE:-admin}" terragrunt output -raw s3_delta_table_path 2>/dev/null || echo "")
VARS_FILE="${TMPDIR:-/tmp}/data-lake-vars-$$"
echo "export S3_BUCKET_ID=\"$S3_BUCKET_ID\"" > "$VARS_FILE"
echo "export S3_BUCKET_ARN=\"$S3_BUCKET_ARN\"" >> "$VARS_FILE"
echo "export S3_DELTA_PATH=\"$S3_DELTA_PATH\"" >> "$VARS_FILE"
echo "$VARS_FILE"

