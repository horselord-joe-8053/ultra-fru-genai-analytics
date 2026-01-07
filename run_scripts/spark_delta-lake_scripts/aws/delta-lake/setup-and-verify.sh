#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../../.." && pwd)"
source "$SCRIPT_DIR/../../../../common/logger.sh"
source "$SCRIPT_DIR/../../../../common/load-env.sh"

# Setup and verify Delta Lake for AWS (S3)
# All operations are idempotent (safe to run multiple times)
ENVIRONMENT="${ENVIRONMENT:-dev}"
DRY_RUN="${DRY_RUN:-false}"
export ENVIRONMENT
export DRY_RUN

log_step "Setting up and verifying data-lake infrastructure"

log_step "Step 1/3: Setting up data-lake infrastructure (S3 + IAM)"
if [ "$DRY_RUN" = "true" ]; then
    log_info "[DRY-RUN] Would run setup-delta-lake.sh"
else
    export SETUP_METHOD="terraform"
    VARS_FILE=$("$REPO_ROOT/run_scripts/spark_delta-lake_scripts/common/delta-lake/setup-delta-lake.sh" 2>&1 | tee /dev/stderr | tail -1)
    EXIT_CODE=${PIPESTATUS[0]}
    if [ $EXIT_CODE -ne 0 ]; then
        log_error "Step 1/3 FAILED: Delta-lake infrastructure setup failed"
        exit 1
    fi
    if [ -n "$VARS_FILE" ] && [ -f "$VARS_FILE" ]; then
        source "$VARS_FILE"
        rm -f "$VARS_FILE"
    fi
fi
log_success "Step 1/3 PASSED: Delta-lake infrastructure ready"

log_step "Step 2/3: Creating Delta table in S3"
if [ "$DRY_RUN" = "true" ]; then
    log_info "[DRY-RUN] Would run create-delta-table.sh"
else
    load_env_file || true
    CSV_PATH="${CSV_PATH:-s3://$S3_BUCKET_ID/raw/fridge_sales_with_rating.csv}"
    DELTA_TABLE_PATH="${S3_DELTA_PATH:-s3://$S3_BUCKET_ID/delta}/fru_sales"
    
    # Get Spark packages and convert paths using Python helpers
    PYTHON_HELPER_OUTPUT=$(python3 -c "
import sys
sys.path.insert(0, '$REPO_ROOT')
from spark_jobs.utils.spark_config import get_spark_packages, to_spark_path
csv_path = '$CSV_PATH'
delta_path = '$DELTA_TABLE_PATH'
print(f'{get_spark_packages(is_aws_deployment=True)}|{to_spark_path(csv_path)}|{to_spark_path(delta_path)}')
" 2>/dev/null)
    
    if [ -z "$PYTHON_HELPER_OUTPUT" ]; then
        log_error "Failed to get Spark config from Python helper"
        exit 1
    fi
    
    # Parse output: packages|csv_path|delta_path
    SPARK_PACKAGES=$(echo "$PYTHON_HELPER_OUTPUT" | cut -d'|' -f1)
    CSV_PATH=$(echo "$PYTHON_HELPER_OUTPUT" | cut -d'|' -f2)
    DELTA_TABLE_PATH=$(echo "$PYTHON_HELPER_OUTPUT" | cut -d'|' -f3)
    
    export PATH_CHECK_METHOD="s3"
    export EXECUTION_METHOD="ecs_task"
    export SPARK_PACKAGES
    export CLUSTER_NAME="fru-${ENVIRONMENT}-cluster"
    export SERVICE_NAME="fru-${ENVIRONMENT}-api-service"
    if ! "$REPO_ROOT/run_scripts/spark_delta-lake_scripts/common/delta-lake/create-delta-table.sh" "$CSV_PATH" "$DELTA_TABLE_PATH"; then
        log_error "Step 2/3 FAILED: Delta table creation failed"
        exit 1
    fi
fi
log_success "Step 2/3 PASSED: Delta table ready"

log_step "Step 3/3: Verifying data-lake setup"
if [ "$DRY_RUN" = "true" ]; then
    log_info "[DRY-RUN] Would run verify-delta-lake.sh"
else
    export VERIFY_METHOD="s3"
    if ! "$REPO_ROOT/run_scripts/spark_delta-lake_scripts/common/delta-lake/verify-delta-lake.sh"; then
        log_error "Step 3/3 FAILED: Delta-lake verification failed"
        exit 1
    fi
fi
log_success "Step 3/3 PASSED: Delta-lake verification complete"

log_success "Delta-lake setup and verification completed successfully!"
