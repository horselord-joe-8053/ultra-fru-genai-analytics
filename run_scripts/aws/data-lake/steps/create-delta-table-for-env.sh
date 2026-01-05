#!/bin/bash
# AWS wrapper for creating Delta table in S3
# Sets up AWS-specific configuration and calls common script
# Called by: run_scripts/aws/data-lake/setup-and-verify.sh
# Receives: ENVIRONMENT, DRY_RUN, DATA_LAKE_SETUP_MODE, S3_DELTA_PATH from parent

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../../.." && pwd)"
source "$SCRIPT_DIR/../../../common/logger.sh"
source "$SCRIPT_DIR/../../../common/load-env.sh"

ENVIRONMENT="${ENVIRONMENT:-dev}"
DRY_RUN="${DRY_RUN:-false}"
MODE="${DATA_LAKE_SETUP_MODE:-standalone}"

# Get S3 Delta table path from infrastructure layer outputs if not already set
if [ -z "$S3_DELTA_PATH" ]; then
    INFRASTRUCTURE_DIR="$REPO_ROOT/infra/terraform/environments/$ENVIRONMENT/infrastructure"
    if [ -d "$INFRASTRUCTURE_DIR" ]; then
        cd "$INFRASTRUCTURE_DIR"
        S3_DELTA_PATH=$(AWS_PROFILE="${AWS_PROFILE:-admin}" terragrunt output -raw s3_delta_table_path 2>/dev/null || echo "")
        cd "$REPO_ROOT"
    fi
fi

if [ -z "$S3_DELTA_PATH" ]; then
    log_error "S3 Delta table path not available. Run setup-data-lake.sh first."
    exit 1
fi

# Append /fru_sales to S3_DELTA_PATH if not already present
if [[ "$S3_DELTA_PATH" != */fru_sales ]]; then
    S3_DELTA_PATH="${S3_DELTA_PATH}/fru_sales"
fi

# Extract bucket name
if [[ ! "$S3_DELTA_PATH" =~ ^s3://([^/]+)/(.+)$ ]]; then
    log_error "Invalid S3 Delta path format: $S3_DELTA_PATH"
    exit 1
fi
S3_BUCKET="${BASH_REMATCH[1]}"
S3_CSV_PATH="s3://${S3_BUCKET}/raw/fridge_sales_with_rating.csv"

# Get cluster and service names
CLUSTER_NAME="fru-${ENVIRONMENT}-cluster"
SERVICE_NAME="fru-${ENVIRONMENT}-api-service"

log_info "Cluster: $CLUSTER_NAME"
log_info "Service: $SERVICE_NAME"
log_info "CSV path: $S3_CSV_PATH"
log_info "Delta table path: $S3_DELTA_PATH"

# Require Delta Lake package from environment
if ! require_delta_lake_package; then
    exit 1
fi

# Convert s3:// to s3a:// for Spark (Spark uses s3a:// protocol)
S3A_CSV_PATH=$(echo "$S3_CSV_PATH" | sed 's|^s3://|s3a://|')
S3A_DELTA_PATH=$(echo "$S3_DELTA_PATH" | sed 's|^s3://|s3a://|')

log_info "Using s3a:// protocol for Spark"
log_info "  CSV path: $S3A_CSV_PATH"
log_info "  Delta path: $S3A_DELTA_PATH"

# Set up AWS-specific environment variables for common script
export SPARK_PACKAGES="$DELTA_LAKE_PACKAGE,org.apache.hadoop:hadoop-aws:3.3.4"
export PATH_CHECK_METHOD="s3"
export EXECUTION_METHOD="ecs_task"
export REPO_ROOT="$REPO_ROOT"
export MODE="$MODE"
export DRY_RUN="$DRY_RUN"
export CLUSTER_NAME="$CLUSTER_NAME"
export SERVICE_NAME="$SERVICE_NAME"
export AWS_PROFILE="${AWS_PROFILE:-admin}"
export AWS_REGION="${AWS_REGION:-us-east-1}"

# Call common script
"$REPO_ROOT/run_scripts/common/data-lake/create-delta-table.sh" \
    "$S3A_CSV_PATH" \
    "$S3A_DELTA_PATH"

