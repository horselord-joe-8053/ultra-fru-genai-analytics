#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../../../../.." && pwd)}"
source "$REPO_ROOT/run_scripts/shared/logger.sh"
source "$REPO_ROOT/run_scripts/shared/load-env.sh"
log_info "[debug] REPO_ROOT resolved to: $REPO_ROOT (spark local delta setup)"

# Setup and verify Delta Lake for local development
# All operations are idempotent (safe to run multiple times)
ENVIRONMENT="${ENVIRONMENT:-dev}"
DRY_RUN="${DRY_RUN:-false}"
PREEMPT="${PREEMPT:-false}"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --preempt)
            PREEMPT="true"
            shift
            ;;
        --dry-run)
            DRY_RUN="true"
            shift
            ;;
        --environment|-e)
            ENVIRONMENT="$2"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done

export ENVIRONMENT
export DRY_RUN
export PREEMPT

# If --preempt flag is set, teardown existing Delta tables first
if [ "$PREEMPT" = "true" ]; then
    log_step "Preempt: Tearing down existing Delta tables"
    log_warning "════════════════════════════════════════════════════════════════"
    log_warning "PREEMPT MODE: Deleting all existing Delta tables"
    log_warning "════════════════════════════════════════════════════════════════"
    
    teardown_cmd="$REPO_ROOT/run_scripts/spark_delta-lake_scripts/common/delta-lake/teardown-delta.sh --local --environment $ENVIRONMENT"
    if [ "$DRY_RUN" = "true" ]; then
        teardown_cmd="$teardown_cmd --dry-run"
    else
        teardown_cmd="$teardown_cmd --force"
    fi
    
    if $teardown_cmd; then
        log_success "Preempt teardown completed"
        echo ""
    else
        log_warning "Preempt teardown had issues (continuing with setup anyway)"
        echo ""
    fi
fi

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
    
    # Always initialize CSV_WAS_UPLOADED to false (will be set explicitly below)
    # This prevents persistence issues from previous runs and makes intent clear
    export CSV_WAS_UPLOADED="false"
    
    # Determine CSV path (support relative and absolute paths)
    local csv_source="${CSV_PATH:-$REPO_ROOT/data/raw/fridge_sales_with_rating.csv}"
    if [[ ! "$csv_source" = /* ]]; then
        # Relative path - resolve to absolute
        CSV_PATH="$REPO_ROOT/$csv_source"
    else
        CSV_PATH="$csv_source"
    fi
    
    # Verify CSV file exists
    if [ ! -f "$CSV_PATH" ]; then
        log_error "CSV file not found: $CSV_PATH"
        log_info "Please ensure the CSV file exists or set CSV_PATH in your .env file"
        exit 1
    fi
    
    log_info "Using CSV from local filesystem: $CSV_PATH"
    
    # Get file info for logging
    if command -v stat >/dev/null 2>&1; then
        local csv_size
        csv_size=$(stat -f%z "$CSV_PATH" 2>/dev/null || stat -c%s "$CSV_PATH" 2>/dev/null || echo "unknown")
        log_info "  File size: ${csv_size} bytes"
    fi
    
    # When --preempt is set, Delta table has already been torn down above,
    # so create-delta-table.sh will create it fresh with the latest CSV data
    DELTA_TABLE_PATH="${DELTA_TABLE_PATH:-data/delta/fru_sales}"
    if [[ "$DELTA_TABLE_PATH" = /* ]]; then
        OUTPUT_PATH="$DELTA_TABLE_PATH"
    else
        OUTPUT_PATH="$REPO_ROOT/$DELTA_TABLE_PATH"
    fi
    
    export PATH_CHECK_METHOD="filesystem"
    export EXECUTION_METHOD="docker"
    export SPARK_PACKAGES="${DELTA_LAKE_PACKAGE}"
    # For local deployments, always recreate Delta table (simpler than change detection)
    # This ensures data freshness and avoids complex file comparison logic
    # Explicitly set to true to force recreation (bypasses idempotent check)
    export CSV_WAS_UPLOADED="true"
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

log_info ""
log_info "════════════════════════════════════════════════════════════════"
log_info "Delta Lake setup completed successfully!"
log_info "════════════════════════════════════════════════════════════════"
log_info ""
log_info "Next steps:"
log_info "  • Batch analytics will be computed automatically by the analytics scheduler"
log_info "    (if ENABLE_ANALYTICS_SCHEDULER=true in your .env file)"
log_info ""
log_info "  • The scheduler runs every ${ANALYTICS_SCHEDULER_INTERVAL_SECONDS:-300} seconds by default"
log_info "    and reads from the Delta table at: ${DELTA_TABLE_PATH:-$REPO_ROOT/data/delta/fru_sales}"
log_info ""
log_info "  • Analytics results are saved to PostgreSQL batch_analytics table"
log_info "    and displayed in the frontend Batch Analytics panel"
log_info ""
