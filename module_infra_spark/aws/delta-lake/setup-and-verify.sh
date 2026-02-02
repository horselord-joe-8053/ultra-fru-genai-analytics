#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../../../../" && pwd)}"
source "$REPO_ROOT/orchestration/common/logger.sh"
source "$REPO_ROOT/orchestration/common/env/load-env.sh"
# Source CSV upload helper
source "$REPO_ROOT/module_infra_spark/common/delta-lake/helpers/local_to_s3_data_upload.sh"
log_info "[debug] REPO_ROOT resolved to: $REPO_ROOT (spark aws delta setup)"

# Setup and verify Delta Lake for AWS (S3)
# All operations are idempotent (safe to run multiple times)
ENVIRONMENT="${ENVIRONMENT:-dev}"
DRY_RUN="${DRY_RUN:-false}"
PREEMPT="${PREEMPT:-false}"
FORCE_REFRESH_DATA="${FORCE_REFRESH_DATA:-false}"

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
        --force-refresh-data)
            FORCE_REFRESH_DATA="true"
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
export FORCE_REFRESH_DATA

# If --preempt flag is set, teardown existing Delta tables first
if [ "$PREEMPT" = "true" ]; then
    log_step "Preempt: Tearing down existing Delta tables"
    log_warning "════════════════════════════════════════════════════════════════"
    log_warning "PREEMPT MODE: Deleting all existing Delta tables"
    log_warning "════════════════════════════════════════════════════════════════"
    
    teardown_cmd="$REPO_ROOT/module_infra_spark/common/delta-lake/teardown-delta.sh --environment $ENVIRONMENT"
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

log_step "Setting up and verifying data-lake infrastructure"

log_step "Substep 1/3: Setting up data-lake infrastructure (S3 + IAM)"
if [ "$DRY_RUN" = "true" ]; then
    log_info "[DRY-RUN] Would run setup-delta-lake.sh"
else
    export SETUP_METHOD="terraform"
    VARS_FILE=$("$REPO_ROOT/module_infra_spark/common/delta-lake/setup-delta-lake.sh" 2>&1 | tee /dev/stderr | tail -1)
    EXIT_CODE=${PIPESTATUS[0]}
    if [ $EXIT_CODE -ne 0 ]; then
        log_error "Substep 1/3 FAILED: Delta-lake infrastructure setup failed"
        exit 1
    fi
    if [ -n "$VARS_FILE" ] && [ -f "$VARS_FILE" ]; then
        source "$VARS_FILE"
        rm -f "$VARS_FILE"
    fi
    # Fail-fast: S3_BUCKET_ID must be set before upload/Delta steps (avoids invalid s3:///raw/...)
    if [ -z "${S3_BUCKET_ID:-}" ]; then
        log_error "Substep 1/3 did not set S3_BUCKET_ID. Delta-lake infrastructure (S3 bucket) is missing or Terraform outputs are not available."
        log_error "  Deploy infrastructure first, or set ENABLE_ANALYTICS_SCHEDULER=false / use --skip-data-lake to skip data-lake setup."
        exit 1
    fi
fi
log_success "Substep 1/3 PASSED: Delta-lake infrastructure ready"

log_step "Substep 2/3: Creating Delta table in S3"
if [ "$DRY_RUN" = "true" ]; then
    log_info "[DRY-RUN] Would run create-delta-table.sh"
else
    load_env_file || true
    
    # Always initialize CSV_WAS_UPLOADED to false (will be set by upload function if needed)
    # This prevents persistence issues from previous runs
    export CSV_WAS_UPLOADED="false"
    
    # Determine CSV path (support both local and S3 paths)
    local_csv_path="${CSV_PATH:-$REPO_ROOT/module_app_core/data/raw/fridge_sales_with_rating.csv}"
    s3_csv_path="s3://${S3_BUCKET_ID}/raw/fridge_sales_with_rating.csv"
    
    # Check if CSV_PATH is already an S3 path
    if [[ "$local_csv_path" =~ ^s3:// ]]; then
        # Already S3 path, use it directly
        CSV_PATH="$local_csv_path"
        log_info "Using CSV from S3: $CSV_PATH"
        # CSV is already in S3 - assume unchanged (no local file to compare)
        # This ensures CSV_WAS_UPLOADED="false" so idempotent check will run
        export CSV_WAS_UPLOADED="false"
    else
        # Local path detected - resolve absolute path if relative
        if [[ ! "$local_csv_path" = /* ]]; then
            local_csv_path="$REPO_ROOT/$local_csv_path"
        fi
        
        log_info "Local CSV path detected: $local_csv_path"
        
        # Upload CSV to S3 (with change detection, or force if --preempt)
        # --preempt flag bypasses change detection and forces upload
        if ! upload_csv_to_s3 "$local_csv_path" "$s3_csv_path" "$PREEMPT" "$DRY_RUN"; then
            log_error "Failed to upload CSV to S3"
            exit 1
        fi
        
        # Use S3 path for Delta table creation
        CSV_PATH="$s3_csv_path"
        log_info "Using CSV from S3: $CSV_PATH"
    fi
    
    DELTA_TABLE_PATH="${S3_DELTA_PATH:-s3://$S3_BUCKET_ID/delta}/fru_sales"
    
    # Get Spark packages and convert paths using Python helpers
    PYTHON_HELPER_OUTPUT=$("$PYTHON_CMD" -c "
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
    # Export AWS credentials for ECS task execution
    export AWS_PROFILE="${AWS_PROFILE:-admin}"
    export AWS_REGION="${AWS_REGION:-us-east-1}"
    create_cmd="$REPO_ROOT/module_infra_spark/common/delta-lake/create-delta-table.sh $CSV_PATH $DELTA_TABLE_PATH"
    if [ "$FORCE_REFRESH_DATA" = "true" ]; then
        create_cmd="$create_cmd --force-refresh-data"
    fi
    if ! $create_cmd; then
        log_error "Substep 2/3 FAILED: Delta table creation failed"
        exit 1
    fi
fi
log_success "Substep 2/3 PASSED: Delta table ready"

log_step "Substep 3/3: Verifying data-lake setup"
if [ "$DRY_RUN" = "true" ]; then
    log_info "[DRY-RUN] Would run verify-delta-lake.sh"
else
    export VERIFY_METHOD="s3"
    if ! "$REPO_ROOT/module_infra_spark/common/delta-lake/verify-delta-lake.sh"; then
        log_error "Substep 3/3 FAILED: Delta-lake verification failed"
        exit 1
    fi
fi
log_success "Substep 3/3 PASSED: Delta-lake verification complete"

log_info ""
log_info "════════════════════════════════════════════════════════════════"
log_info "Delta-lake setup completed successfully!"
log_info "════════════════════════════════════════════════════════════════"
log_info ""
log_info "Next steps:"
log_info "  • Batch analytics will be computed automatically by the analytics scheduler"
log_info "    (if ENABLE_ANALYTICS_SCHEDULER=true in your .env file)"
log_info ""
log_info "  • The scheduler runs every ${ANALYTICS_SCHEDULER_INTERVAL_SECONDS:-300} seconds by default"
log_info "    and reads from the Delta table at: ${S3_DELTA_PATH:-s3://$S3_BUCKET_ID/delta}/fru_sales"
log_info ""
log_info "  • Analytics results are saved to PostgreSQL batch_analytics table"
log_info "    and displayed in the frontend Batch Analytics panel"
log_info ""
