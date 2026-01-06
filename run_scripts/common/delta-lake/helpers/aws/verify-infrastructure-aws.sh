#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../../../.." && pwd)"
source "$SCRIPT_DIR/../../../logger.sh"
source "$SCRIPT_DIR/../../../load-env.sh"

ENVIRONMENT="${ENVIRONMENT:-dev}"
MODE="${DATA_LAKE_SETUP_MODE:-standalone}"

if [ -z "$S3_BUCKET_ID" ]; then
    INFRASTRUCTURE_DIR="$REPO_ROOT/infra/terraform/environments/$ENVIRONMENT/infrastructure"
    if [ -d "$INFRASTRUCTURE_DIR" ]; then
        cd "$INFRASTRUCTURE_DIR"
        S3_BUCKET_ID=$(AWS_PROFILE="${AWS_PROFILE:-admin}" terragrunt output -raw s3_data_bucket_id 2>/dev/null || echo "")
        S3_DELTA_PATH=$(AWS_PROFILE="${AWS_PROFILE:-admin}" terragrunt output -raw s3_delta_table_path 2>/dev/null || echo "")
        cd "$REPO_ROOT"
    fi
fi

if [ -z "$S3_BUCKET_ID" ]; then
    log_error "Failed to get S3 bucket information"
    exit 1
fi

if ! aws s3 ls "s3://$S3_BUCKET_ID" --profile "${AWS_PROFILE:-admin}" >/dev/null 2>&1; then
    log_error "S3 bucket does not exist or is not accessible"
    exit 1
fi

if [ -n "$S3_DELTA_PATH" ]; then
    # S3_DELTA_PATH is s3://bucket/delta, append /fru_sales for the table name
    DELTA_TABLE_NAME="${DELTA_TABLE_NAME:-fru_sales}"
    DELTA_TABLE_PATH="$S3_DELTA_PATH/$DELTA_TABLE_NAME"
    
    # Use common helper to check if Delta table exists
    if ! "$SCRIPT_DIR/../check-delta-table-exists.sh" "$DELTA_TABLE_PATH" "s3" 2>/dev/null; then
        if [ "$MODE" = "standalone" ]; then
            # Standalone mode: exit silently if table doesn't exist (idempotent check)
            exit 0
        else
            # Full-workflow mode: fail if table doesn't exist
            log_error "Delta table does not exist at: $DELTA_TABLE_PATH"
            exit 1
        fi
    fi
    
    # Table exists
    log_info "Delta table verified at: $DELTA_TABLE_PATH"
fi

