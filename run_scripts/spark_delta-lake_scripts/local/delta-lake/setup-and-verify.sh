#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../../.." && pwd)"
source "$SCRIPT_DIR/../../../../common/logger.sh"
source "$SCRIPT_DIR/../../../../common/load-env.sh"

# Setup and verify Delta Lake for local development
# All operations are idempotent (safe to run multiple times)

log_step "Setting up and verifying Delta Lake for local development"

log_step "Step 1/3: Setting up Delta Lake directory structure"
if [ "$DRY_RUN" = "true" ]; then
    log_info "[DRY-RUN] Would run setup-delta-lake.sh"
else
    export SETUP_METHOD="filesystem"
    if ! "$REPO_ROOT/run_scripts/spark_delta-lake_scripts/common/delta-lake/setup-delta-lake.sh"; then
        log_error "Step 1/3 FAILED: Delta Lake directory setup failed"
        exit 1
    fi
fi
log_success "Step 1/3 PASSED: Delta Lake directory structure ready"

log_step "Step 2/3: Creating Delta table from CSV"
if [ "$DRY_RUN" = "true" ]; then
    log_info "[DRY-RUN] Would run create-delta-table.sh"
else
    load_env_file || true
    CSV_PATH="${CSV_PATH:-$REPO_ROOT/data/raw/fridge_sales_with_rating.csv}"
    DELTA_TABLE_PATH="${DELTA_TABLE_PATH:-data/delta/fru_sales}"
    if [[ "$DELTA_TABLE_PATH" = /* ]]; then
        OUTPUT_PATH="$DELTA_TABLE_PATH"
    else
        OUTPUT_PATH="$REPO_ROOT/$DELTA_TABLE_PATH"
    fi
    export PATH_CHECK_METHOD="filesystem"
    export EXECUTION_METHOD="docker"
    export SPARK_PACKAGES="${DELTA_LAKE_PACKAGE}"
    if ! "$REPO_ROOT/run_scripts/spark_delta-lake_scripts/common/delta-lake/create-delta-table.sh" "$CSV_PATH" "$OUTPUT_PATH"; then
        log_error "Step 2/3 FAILED: Delta table creation failed"
        exit 1
    fi
fi
log_success "Step 2/3 PASSED: Delta table ready"

log_step "Step 3/3: Verifying Delta table"
if [ "$DRY_RUN" = "true" ]; then
    log_info "[DRY-RUN] Would run verify-delta-lake.sh"
else
    export VERIFY_METHOD="filesystem"
    if ! "$REPO_ROOT/run_scripts/spark_delta-lake_scripts/common/delta-lake/verify-delta-lake.sh"; then
        log_error "Step 3/3 FAILED: Delta table verification failed"
        exit 1
    fi
fi
log_success "Step 3/3 PASSED: Delta table verification complete"

log_success "Delta Lake setup and verification completed successfully!"
