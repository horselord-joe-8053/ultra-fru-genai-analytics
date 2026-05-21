#!/bin/bash
# Create Delta table from CSV file
# Idempotent: skips creation if table already exists
#
# Usage: create-delta-table.sh <INPUT_PATH> <OUTPUT_PATH> [--force-refresh-data]
#
# Required Environment Variables:
#   SPARK_PACKAGES - Maven coordinates for Spark packages
#   PATH_CHECK_METHOD - "filesystem" or "s3"
#   EXECUTION_METHOD - "docker", "ecs_task", or "docker_ecr"
#   REPO_ROOT - Repository root directory
#
# Optional Environment Variables:
#   CLUSTER_NAME - ECS cluster name (required for ecs_task)
#   SERVICE_NAME - ECS service name (required for ecs_task)
#   CONTAINER_IMAGE - ECR image URI (required for docker_ecr)
#   DRY_RUN - "true" to preview without creating
#   FORCE_REFRESH_DATA - "true" to force refresh (delete existing table before creating)

set -e

INPUT_PATH="$1"
OUTPUT_PATH="$2"
DRY_RUN="${DRY_RUN:-false}"
FORCE_REFRESH_DATA="${FORCE_REFRESH_DATA:-false}"

# Parse arguments (shift past INPUT_PATH and OUTPUT_PATH)
shift 2 || true
for arg in "$@"; do
    if [ "$arg" = "--force-refresh-data" ]; then
        FORCE_REFRESH_DATA=true
    fi
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../../.." && pwd)}"
source "$REPO_ROOT/lib/logger.sh"

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

# If --force-refresh-data is set, delete existing Delta table first
if [ "$FORCE_REFRESH_DATA" = "true" ]; then
    log_info "FORCE_REFRESH_DATA=true: Deleting existing Delta table (if any)..."
    if [ "$PATH_CHECK_METHOD" = "s3" ]; then
        # Delete from S3
        AWS_PROFILE="${AWS_PROFILE:-admin}"
        AWS_REGION="${AWS_REGION:-us-east-1}"
        if aws s3 rm "$OUTPUT_PATH" --recursive --profile "$AWS_PROFILE" --region "$AWS_REGION" >/dev/null 2>&1; then
            log_info "Delta table deleted from S3: $OUTPUT_PATH"
        else
            log_info "Delta table may not exist in S3 (or deletion failed): $OUTPUT_PATH"
        fi
    else
        # Delete from local filesystem
        if [ -d "$OUTPUT_PATH" ]; then
            rm -rf "$OUTPUT_PATH"
            log_info "Delta table deleted from filesystem: $OUTPUT_PATH"
        else
            log_info "Delta table directory does not exist: $OUTPUT_PATH"
        fi
    fi
    log_info "Proceeding with fresh Delta table creation..."
    DELTA_TABLE_WAS_CREATED="true"
elif [ "${CSV_WAS_UPLOADED:-false}" = "true" ]; then
    # Check if CSV was uploaded (indicates CSV content changed)
    # If CSV was uploaded, bypass idempotent check and force recreation
    log_info "CSV was uploaded (size changed), forcing Delta table recreation..."
    log_info "Bypassing idempotent check (CSV content has changed)"
    DELTA_TABLE_WAS_CREATED="true"
else
    # Check if Delta table already exists (idempotent check)
    log_info "Checking if Delta table already exists at: $OUTPUT_PATH"
    if "$SCRIPT_DIR/helpers/check-delta-table-exists.sh" "$OUTPUT_PATH" "$PATH_CHECK_METHOD"; then
        log_info "Delta table already exists at: $OUTPUT_PATH"
        log_success "Skipping creation (idempotent - CSV unchanged)"
        DELTA_TABLE_WAS_CREATED="false"
        # Don't exit - continue to analytics check (will skip if table not created)
    else
        # Table doesn't exist, will create it
        log_info "Delta table does not exist, will create it"
        DELTA_TABLE_WAS_CREATED="true"
    fi
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
    docker_ecr)
        if [ -z "$CONTAINER_IMAGE" ]; then
            log_error "CONTAINER_IMAGE is required for docker_ecr (set by run.sh / load-image-identifiers.sh)"
            exit 1
        fi
        "$SCRIPT_DIR/helpers/aws/run-spark-job-docker-ecr.sh" \
            "$INPUT_PATH" \
            "$OUTPUT_PATH" \
            "$SPARK_PACKAGES"
        ;;
    *)
        log_error "Unknown execution method: $EXECUTION_METHOD (must be 'docker', 'ecs_task', or 'docker_ecr')"
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
        docker_ecr)
            # App (EKS/ECS) scheduler will run analytics periodically; no one-off trigger
            log_info "Scheduler in app pod will run analytics on next interval"
            ;;
        *)
            log_warning "Unknown execution method for analytics trigger: $EXECUTION_METHOD"
            ;;
    esac
    
    log_info "Scheduler will also run analytics periodically (safety net)"
fi

