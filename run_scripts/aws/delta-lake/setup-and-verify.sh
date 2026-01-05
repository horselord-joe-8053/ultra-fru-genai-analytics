#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
source "$SCRIPT_DIR/../../common/logger.sh"
source "$SCRIPT_DIR/../../common/load-env.sh"

DATA_LAKE_SETUP_MODE="${DATA_LAKE_SETUP_MODE:-standalone}"

for arg in "$@"; do
    if [ "$arg" = "--full-workflow" ]; then
        DATA_LAKE_SETUP_MODE="full-workflow"
    elif [ "$arg" = "--standalone" ]; then
        DATA_LAKE_SETUP_MODE="standalone"
    fi
done

export DATA_LAKE_SETUP_MODE
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
    VARS_FILE=$("$REPO_ROOT/run_scripts/common/delta-lake/setup-delta-lake.sh" 2>&1 | tee /dev/stderr | tail -1)
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
    export PATH_CHECK_METHOD="s3"
    export EXECUTION_METHOD="ecs_task"
    export MODE="$DATA_LAKE_SETUP_MODE"
    export SPARK_PACKAGES="${DELTA_LAKE_PACKAGE}"
    export CLUSTER_NAME="fru-${ENVIRONMENT}-cluster"
    export SERVICE_NAME="fru-${ENVIRONMENT}-api-service"
    if ! "$REPO_ROOT/run_scripts/common/delta-lake/create-delta-table.sh" "$CSV_PATH" "$DELTA_TABLE_PATH"; then
        if [ "$DATA_LAKE_SETUP_MODE" = "full-workflow" ]; then
            log_error "Step 2/3 FAILED: Delta table creation failed"
            exit 1
        fi
    fi
fi
log_success "Step 2/3 PASSED: Delta table ready"

log_step "Step 3/3: Verifying data-lake setup"
if [ "$DRY_RUN" = "true" ]; then
    log_info "[DRY-RUN] Would run verify-delta-lake.sh"
else
    export VERIFY_METHOD="s3"
    if ! "$REPO_ROOT/run_scripts/common/delta-lake/verify-delta-lake.sh"; then
        if [ "$DATA_LAKE_SETUP_MODE" = "full-workflow" ]; then
            log_error "Step 3/3 FAILED: Delta-lake verification failed"
            exit 1
        fi
    fi
fi
log_success "Step 3/3 PASSED: Delta-lake verification complete"

log_success "Delta-lake setup and verification completed successfully!"
