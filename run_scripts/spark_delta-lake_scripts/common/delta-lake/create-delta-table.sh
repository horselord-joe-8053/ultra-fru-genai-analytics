#!/bin/bash
# Create Delta table from CSV file
# Idempotent: skips creation if table already exists
#
# Usage: create-delta-table.sh <INPUT_PATH> <OUTPUT_PATH>
#
# Required Environment Variables:
#   SPARK_PACKAGES - Maven coordinates for Spark packages
#   PATH_CHECK_METHOD - "filesystem" or "s3"
#   EXECUTION_METHOD - "docker" or "ecs_task"
#   REPO_ROOT - Repository root directory
#
# Optional Environment Variables:
#   CLUSTER_NAME - ECS cluster name (required for ecs_task)
#   SERVICE_NAME - ECS service name (required for ecs_task)
#   DRY_RUN - "true" to preview without creating

set -e

INPUT_PATH="$1"
OUTPUT_PATH="$2"
DRY_RUN="${DRY_RUN:-false}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../../.." && pwd)}"
source "$REPO_ROOT/run_scripts/shared/logger.sh"

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

# Track if table was actually created (not skipped)
DELTA_TABLE_WAS_CREATED="false"

# Check if CSV was uploaded (indicates CSV content changed)
# If CSV was uploaded, bypass idempotent check and force recreation
if [ "${CSV_WAS_UPLOADED:-false}" = "true" ]; then
    log_info "CSV was uploaded (size changed), forcing Delta table recreation..."
    log_info "Bypassing idempotent check (CSV content has changed)"
    DELTA_TABLE_WAS_CREATED="true"
elif "$SCRIPT_DIR/helpers/check-delta-table-exists.sh" "$OUTPUT_PATH" "$PATH_CHECK_METHOD" 2>/dev/null; then
    log_info "Delta table already exists at: $OUTPUT_PATH"
    log_success "Skipping creation (idempotent - CSV unchanged)"
    DELTA_TABLE_WAS_CREATED="false"
    # Don't exit - continue to analytics check (will skip if table not created)
else
    # Table doesn't exist, will create it
    DELTA_TABLE_WAS_CREATED="true"
fi

# Only create table if needed
if [ "$DELTA_TABLE_WAS_CREATED" = "false" ]; then
    log_info "Delta table unchanged, skipping analytics trigger"
    exit 0
fi

log_info "Creating Delta table at: $OUTPUT_PATH"

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
    docker)
        "$SCRIPT_DIR/helpers/local/run-spark-job-docker.sh" \
            "$INPUT_PATH" \
            "$OUTPUT_PATH" \
            "$SPARK_PACKAGES"
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
        log_error "Unknown execution method: $EXECUTION_METHOD (must be 'docker' or 'ecs_task')"
        exit 1
        ;;
esac

log_success "Delta table creation complete!"

# Always trigger analytics if table was created/updated (unless dry-run)
if [ "$DELTA_TABLE_WAS_CREATED" = "true" ] && [ "$DRY_RUN" != "true" ]; then
    log_info "Triggering analytics job immediately after Delta table creation/update..."
    
    case "$EXECUTION_METHOD" in
        docker)
            # Run in background (non-blocking) to avoid delaying setup script
            if "$SCRIPT_DIR/helpers/local/trigger-analytics-local.sh" 2>&1; then
                log_info "Analytics job started in background"
            else
                log_warning "Analytics trigger failed (continuing anyway)"
                log_warning "Scheduler will run analytics on next interval"
            fi
            ;;
        ecs_task)
            if [ -z "$CLUSTER_NAME" ] || [ -z "$SERVICE_NAME" ]; then
                log_warning "CLUSTER_NAME and SERVICE_NAME not set, skipping analytics trigger"
            else
                # Run in background (non-blocking) - ECS task will run independently
                log_info "Starting analytics ECS task (runs independently)..."
                if "$SCRIPT_DIR/helpers/aws/trigger-analytics-aws.sh" \
                    "$CLUSTER_NAME" \
                    "$SERVICE_NAME" 2>&1; then
                    log_info "Analytics ECS task started"
                else
                    log_warning "Analytics trigger failed (continuing anyway)"
                    log_warning "Scheduler will run analytics on next interval"
                fi
            fi
            ;;
        *)
            log_warning "Unknown execution method for analytics trigger: $EXECUTION_METHOD"
            ;;
    esac
    
    log_info "Scheduler will also run analytics periodically (safety net)"
fi

