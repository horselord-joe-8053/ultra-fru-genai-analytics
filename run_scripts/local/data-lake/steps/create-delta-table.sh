#!/bin/bash
# Create Delta table from CSV file using Spark
# Called by: run_scripts/local/data-lake/setup-and-verify.sh
# Receives: DATA_LAKE_SETUP_MODE, DELTA_DIR, DELTA_TABLE_PATH from parent

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
source "$SCRIPT_DIR/../../../common/logger.sh"
source "$SCRIPT_DIR/../../../common/load-env.sh"

MODE="${DATA_LAKE_SETUP_MODE:-standalone}"

# Get Delta table path (from parent or environment)
if [ -z "$DELTA_DIR" ] || [ -z "$DELTA_TABLE_PATH" ]; then
    load_env_file || true
    DELTA_TABLE_PATH="${DELTA_TABLE_PATH:-data/delta/fru_sales}"
    
    # Resolve to absolute path
    if [[ "$DELTA_TABLE_PATH" = /* ]]; then
        DELTA_DIR="$DELTA_TABLE_PATH"
    else
        DELTA_DIR="$REPO_ROOT/$DELTA_TABLE_PATH"
    fi
fi

# Default CSV file
CSV_FILE="${1:-$REPO_ROOT/data/raw/fridge_sales_with_rating.csv}"

log_info "Delta table path: $DELTA_DIR"
log_info "CSV file: $CSV_FILE"

# Mode-specific behavior
if [ "$MODE" = "standalone" ]; then
    # Idempotent: Check if Delta table already exists
    if [ -d "$DELTA_DIR/_delta_log" ]; then
        log_info "Delta table already exists at: $DELTA_DIR"
        
        # Quick validation - check for log entries
        DELTA_LOG_COUNT=$(find "$DELTA_DIR/_delta_log" -name "*.json" 2>/dev/null | wc -l | tr -d ' ')
        if [ "$DELTA_LOG_COUNT" -gt 0 ]; then
            log_success "✓ Delta table exists with $DELTA_LOG_COUNT log entries"
            log_info "Skipping Delta table creation (idempotent mode)"
            exit 0
        else
            log_warning "Delta table directory exists but has no log entries, recreating..."
            rm -rf "$DELTA_DIR"
            mkdir -p "$DELTA_DIR"
        fi
    else
        log_info "Delta table does not exist, creating..."
        mkdir -p "$DELTA_DIR"
    fi
else
    # Full-workflow: Verify and potentially recreate if needed
    log_info "Ensuring Delta table is properly configured (full-workflow mode)..."
    
    if [ -d "$DELTA_DIR/_delta_log" ]; then
        log_info "Delta table exists, verifying integrity..."
        
        # Verify Delta table integrity
        DELTA_LOG_COUNT=$(find "$DELTA_DIR/_delta_log" -name "*.json" 2>/dev/null | wc -l | tr -d ' ')
        if [ "$DELTA_LOG_COUNT" -eq 0 ]; then
            log_warning "Delta table appears incomplete (no log entries), recreating..."
            rm -rf "$DELTA_DIR"
            mkdir -p "$DELTA_DIR"
        else
            log_success "✓ Delta table exists and appears valid ($DELTA_LOG_COUNT log entries)"
            log_info "Delta table verification complete"
            exit 0
        fi
    else
        log_info "Delta table does not exist, creating..."
        mkdir -p "$DELTA_DIR"
    fi
fi

# Check if CSV file exists
if [ ! -f "$CSV_FILE" ]; then
    log_error "CSV file not found: $CSV_FILE"
    log_info "Expected CSV file at: $CSV_FILE"
    log_info "Create the CSV file or specify a different path"
    exit 1
fi

# Require Delta Lake package from environment (.env is source of truth, no defaults)
# This will error out if DELTA_LAKE_PACKAGE is not set in .env
if ! require_delta_lake_package; then
    exit 1
fi

# Determine how to run Spark (local or Docker)
if command -v spark-submit >/dev/null 2>&1; then
    # Use local Spark
    log_info "Using local Spark to create Delta table"
    
    spark-submit \
        --packages "$DELTA_LAKE_PACKAGE" \
        "$REPO_ROOT/spark_jobs/ingest_delta.py" \
        "$CSV_FILE" \
        "$DELTA_DIR" || {
        log_warning "Failed to create Delta table using local Spark"
        if [ "$MODE" = "full-workflow" ]; then
            log_error "Full-workflow mode requires successful Delta table creation"
            exit 1
        else
            log_warning "Standalone mode: continuing despite issues"
            exit 0
        fi
    }
    
    log_success "Delta table created successfully using local Spark"
elif docker ps >/dev/null 2>&1 && docker ps --filter "name=fru_api" --format "{{.Names}}" | grep -q "fru_api"; then
    # Use Spark in Docker container
    log_info "Using Spark in Docker container to create Delta table"
    
    # Check if container has Spark installed
    if docker exec fru_api test -f /opt/spark/bin/spark-submit 2>/dev/null; then
        docker exec -w /app -e DELTA_LAKE_PACKAGE="$DELTA_LAKE_PACKAGE" fru_api \
            /opt/spark/bin/spark-submit \
            --packages "$DELTA_LAKE_PACKAGE" \
            /app/spark_jobs/ingest_delta.py \
            "$CSV_FILE" \
            "$DELTA_DIR" || {
            log_warning "Failed to create Delta table using Docker Spark"
            if [ "$MODE" = "full-workflow" ]; then
                log_error "Full-workflow mode requires successful Delta table creation"
                exit 1
            else
                log_warning "Standalone mode: continuing despite issues"
                exit 0
            fi
        }
        
        log_success "Delta table created successfully using Docker Spark"
    else
        log_error "Spark not found in Docker container"
        log_info "Please ensure the fru_api container has Spark installed, or install Spark locally"
        return 1
    fi
else
    log_error "Neither local Spark nor Docker container with Spark is available"
    log_info "Please install Spark locally (use --setup-spark flag) or start Docker services"
    return 1
fi

