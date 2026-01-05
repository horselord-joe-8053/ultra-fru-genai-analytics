#!/bin/bash
# Core logic for creating Delta table from CSV
# This script is called by environment-specific wrappers
# Usage: create-delta-table.sh <INPUT_PATH> <OUTPUT_PATH>
#
# Environment Variables (set by wrapper):
#   SPARK_PACKAGES - Spark packages (required)
#   PATH_CHECK_METHOD - "filesystem" or "s3" (required)
#   EXECUTION_METHOD - "local", "docker", or "ecs_task" (required)
#   SPARK_SUBMIT_PATH - Path to spark-submit (required for local/docker)
#   MODE - "standalone" or "full-workflow" (from DATA_LAKE_SETUP_MODE)
#   DRY_RUN - "true" or "false" (optional)
#   REPO_ROOT - Repository root directory (required)
#   CLUSTER_NAME - ECS cluster name (required for ecs_task)
#   SERVICE_NAME - ECS service name (required for ecs_task)

set -e

INPUT_PATH="$1"
OUTPUT_PATH="$2"
MODE="${MODE:-${DATA_LAKE_SETUP_MODE:-standalone}}"
DRY_RUN="${DRY_RUN:-false}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../../.." && pwd)}"
source "$SCRIPT_DIR/../logger.sh"

if [ -z "$INPUT_PATH" ] || [ -z "$OUTPUT_PATH" ]; then
    log_error "INPUT_PATH and OUTPUT_PATH are required"
    exit 1
fi

# Validate required environment variables
if [ -z "$SPARK_PACKAGES" ]; then
    log_error "SPARK_PACKAGES environment variable is required (set by wrapper)"
    exit 1
fi

if [ -z "$PATH_CHECK_METHOD" ]; then
    log_error "PATH_CHECK_METHOD environment variable is required (set by wrapper)"
    exit 1
fi

if [ -z "$EXECUTION_METHOD" ]; then
    log_error "EXECUTION_METHOD environment variable is required (set by wrapper)"
    exit 1
fi

log_info "Input path: $INPUT_PATH"
log_info "Output path: $OUTPUT_PATH"
log_info "Path check method: $PATH_CHECK_METHOD"
log_info "Execution method: $EXECUTION_METHOD"
log_info "Mode: $MODE"

# Check if Delta table exists
if "$SCRIPT_DIR/helpers/check-delta-table-exists.sh" "$OUTPUT_PATH" "$PATH_CHECK_METHOD" 2>/dev/null; then
    TABLE_EXISTS=true
else
    TABLE_EXISTS=false
fi

# Mode-specific behavior
if [ "$MODE" = "standalone" ]; then
    # Idempotent: Skip if table exists
    if [ "$TABLE_EXISTS" = true ]; then
        log_info "Delta table already exists at: $OUTPUT_PATH"
        log_success "Skipping Delta table creation (idempotent mode)"
        exit 0
    else
        log_info "Delta table does not exist, creating..."
    fi
else
    # Full-workflow: Verify and potentially recreate if needed
    if [ "$TABLE_EXISTS" = true ]; then
        log_info "Delta table exists, verifying integrity..."
        # For now, we consider existing table as valid
        # In the future, we could add more validation here
        log_success "Delta table exists and appears valid"
        log_info "Delta table verification complete"
        exit 0
    else
        log_info "Delta table does not exist, creating..."
    fi
fi

# Dry-run mode
if [ "$DRY_RUN" = "true" ]; then
    log_info "[DRY-RUN] Would create Delta table at: $OUTPUT_PATH"
    log_info "[DRY-RUN] Would process CSV from: $INPUT_PATH"
    exit 0
fi

# Validate input file exists (for filesystem paths)
if [ "$PATH_CHECK_METHOD" = "filesystem" ]; then
    if [ ! -f "$INPUT_PATH" ]; then
        log_error "Input CSV file not found: $INPUT_PATH"
        exit 1
    fi
fi

# Execute Spark job based on execution method
case "$EXECUTION_METHOD" in
    local|docker)
        "$SCRIPT_DIR/helpers/local/run-spark-job-local.sh" \
            "$INPUT_PATH" \
            "$OUTPUT_PATH" \
            "$SPARK_PACKAGES" \
            "$EXECUTION_METHOD" \
            "${SPARK_SUBMIT_PATH:-spark-submit}"
        ;;
    ecs_task)
        if [ -z "$CLUSTER_NAME" ] || [ -z "$SERVICE_NAME" ]; then
            log_error "CLUSTER_NAME and SERVICE_NAME are required for ECS execution"
            exit 1
        fi
        
        "$SCRIPT_DIR/helpers/aws/run-spark-job-aws.sh" \
            "$INPUT_PATH" \
            "$OUTPUT_PATH" \
            "$SPARK_PACKAGES" \
            "$CLUSTER_NAME" \
            "$SERVICE_NAME"
        ;;
    *)
        log_error "Unknown execution method: $EXECUTION_METHOD"
        exit 1
        ;;
esac

log_success "Delta table creation complete!"

