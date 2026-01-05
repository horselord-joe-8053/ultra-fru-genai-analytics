#!/bin/bash
# Create Delta table in S3 from CSV file
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

# Default CSV file
CSV_FILE="${1:-$REPO_ROOT/data/raw/fridge_sales_with_rating.csv}"

# Extract bucket name for verification
if [[ ! "$S3_DELTA_PATH" =~ ^s3://([^/]+)/(.+)$ ]]; then
    log_error "Invalid S3 Delta path format: $S3_DELTA_PATH"
    log_error "Expected format: s3://bucket-name/path/to/delta/table"
    exit 1
fi
S3_BUCKET="${BASH_REMATCH[1]}"

# Mode-specific behavior
if [ "$MODE" = "standalone" ]; then
    # Idempotent: Check if Delta table already exists
    log_info "Checking if Delta table already exists..."
    if aws s3 ls "$S3_DELTA_PATH/_delta_log/" --profile "${AWS_PROFILE:-admin}" >/dev/null 2>&1; then
        log_info "Delta table already exists at: $S3_DELTA_PATH"
        
        # Quick validation
        DELTA_LOG_COUNT=$(aws s3 ls "$S3_DELTA_PATH/_delta_log/" --profile "${AWS_PROFILE:-admin}" 2>/dev/null | wc -l | tr -d ' ')
        if [ "$DELTA_LOG_COUNT" -gt 0 ]; then
            log_success "✓ Delta table exists with $DELTA_LOG_COUNT log entries"
            log_info "Skipping Delta table creation (idempotent mode)"
            return 0
        else
            log_warning "Delta table directory exists but has no log entries, recreating..."
            aws s3 rm "$S3_DELTA_PATH" --recursive --profile "${AWS_PROFILE:-admin}" || true
        fi
    else
        log_info "Delta table does not exist, creating..."
    fi
else
    # Full-workflow: Verify and potentially recreate if needed
    log_info "Ensuring Delta table is properly configured (full-workflow mode)..."
    
    if aws s3 ls "$S3_DELTA_PATH/_delta_log/" --profile "${AWS_PROFILE:-admin}" >/dev/null 2>&1; then
        log_info "Delta table exists, verifying integrity..."
        
        # Verify Delta table integrity (check for _delta_log, basic structure)
        DELTA_LOG_COUNT=$(aws s3 ls "$S3_DELTA_PATH/_delta_log/" --profile "${AWS_PROFILE:-admin}" 2>/dev/null | wc -l | tr -d ' ')
        if [ "$DELTA_LOG_COUNT" -eq 0 ]; then
            log_warning "Delta table appears incomplete (no log entries), recreating..."
            # Delete and recreate
            aws s3 rm "$S3_DELTA_PATH" --recursive --profile "${AWS_PROFILE:-admin}" || true
        else
            log_success "✓ Delta table exists and appears valid ($DELTA_LOG_COUNT log entries)"
            log_info "Delta table verification complete"
            return 0
        fi
    else
        log_info "Delta table does not exist, creating..."
    fi
fi

# Create Delta table (common logic for both modes)
if [ "$DRY_RUN" = "true" ]; then
    log_info "[DRY-RUN] Would create Delta table at: $S3_DELTA_PATH"
    log_info "[DRY-RUN] Would upload CSV from: $CSV_FILE"
    return 0
fi

# Check if CSV file exists
if [ ! -f "$CSV_FILE" ]; then
    log_error "CSV file not found: $CSV_FILE"
    log_info "Expected CSV file at: $CSV_FILE"
    log_info "Create the CSV file or specify a different path"
    exit 1
fi

# Use existing script to create Delta table
log_info "Creating Delta table using: $REPO_ROOT/run_scripts/aws/database/create_delta_table_s3.sh"
if "$REPO_ROOT/run_scripts/aws/database/create_delta_table_s3.sh" "$CSV_FILE" "$S3_DELTA_PATH"; then
    log_success "Delta table created successfully"
else
        log_warning "Delta table creation had issues"
        if [ "$MODE" = "full-workflow" ]; then
            log_error "Full-workflow mode requires successful Delta table creation"
            exit 1
        else
            log_warning "Standalone mode: continuing despite issues"
            exit 0
        fi
fi

