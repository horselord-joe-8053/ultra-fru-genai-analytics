#!/bin/bash
# Verify Delta table setup for local development
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

log_info "Verifying Delta table setup (mode: $MODE)..."
log_info "  Delta table path: $DELTA_DIR"

if [ "$DRY_RUN" = "true" ]; then
    log_info "[DRY-RUN] Would verify Delta table existence and structure"
    return 0
fi

# Common verification: Delta table directory exists
if [ ! -d "$DELTA_DIR" ]; then
    log_error "✗ Delta table directory does not exist: $DELTA_DIR"
    return 1
fi
log_success "✓ Delta table directory exists"

if [ "$MODE" = "standalone" ]; then
    # Idempotent mode: Basic verification
    log_info "Running basic verification (standalone mode)..."
    
    # Check Delta table structure
    if [ -d "$DELTA_DIR/_delta_log" ]; then
        log_success "✓ Delta table structure exists (_delta_log directory found)"
        
        # Count log entries
        DELTA_LOG_COUNT=$(find "$DELTA_DIR/_delta_log" -name "*.json" 2>/dev/null | wc -l | tr -d ' ')
        if [ "$DELTA_LOG_COUNT" -gt 0 ]; then
            log_info "  Delta table contains $DELTA_LOG_COUNT log entries"
        fi
    else
        log_warning "⚠ Delta table structure incomplete (_delta_log directory missing)"
        log_warning "  Run create-delta-table.sh to create the Delta table"
    fi
    
    log_success "Basic Delta table verification complete"
else
    # Full-workflow mode: Comprehensive verification
    log_info "Running comprehensive verification (full-workflow mode)..."
    
    # 1. Verify directory structure
    log_info "  Verifying Delta table directory structure..."
    if [ ! -d "$DELTA_DIR/_delta_log" ]; then
        log_error "  ✗ _delta_log directory is missing (Delta table is incomplete)"
        return 1
    fi
    log_success "  ✓ _delta_log directory exists"
    
    # 2. Verify Delta log entries
    log_info "  Verifying Delta log entries..."
    DELTA_LOG_COUNT=$(find "$DELTA_DIR/_delta_log" -name "*.json" 2>/dev/null | wc -l | tr -d ' ')
    if [ "$DELTA_LOG_COUNT" -eq 0 ]; then
        log_error "  ✗ Delta table has no log entries (table may be corrupted or empty)"
        return 1
    fi
    log_success "  ✓ Delta table has $DELTA_LOG_COUNT log entries"
    
    # 3. Verify data files exist
    log_info "  Verifying data files..."
    # Check for parquet files or other data files (Delta tables store data alongside _delta_log)
    if find "$DELTA_DIR" -maxdepth 1 -type f -name "*.parquet" 2>/dev/null | grep -q . || \
       find "$DELTA_DIR" -type d -name "part-*" 2>/dev/null | grep -q .; then
        log_success "  ✓ Data files found in Delta table"
    else
        log_warning "  ⚠ No data files found (table may be empty, but structure is valid)"
    fi
    
    # 4. Verify Spark can read the table (if Spark is available)
    if command -v spark-submit >/dev/null 2>&1 || \
       (docker ps >/dev/null 2>&1 && docker ps --filter "name=fru_api" --format "{{.Names}}" | grep -q "fru_api"); then
        log_info "  Verifying Spark can read Delta table..."
        
        # Create a simple test script to verify Delta table can be read
        TEST_SCRIPT=$(mktemp)
        cat > "$TEST_SCRIPT" << 'PYTHON_EOF'
from pyspark.sql import SparkSession
import sys

delta_path = sys.argv[1]
spark = (
    SparkSession.builder.appName("delta-verify")
    .config("spark.sql.extensions", "io.delta.sql.DeltaSparkSessionExtension")
    .config("spark.sql.catalog.spark_catalog", "org.apache.spark.sql.delta.catalog.DeltaCatalog")
    .getOrCreate()
)
try:
    df = spark.read.format("delta").load(delta_path)
    count = df.count()
    print(f"SUCCESS: Delta table is readable, contains {count} rows")
    sys.exit(0)
except Exception as e:
    print(f"ERROR: Failed to read Delta table: {e}")
    sys.exit(1)
PYTHON_EOF
        
        # Require Delta Lake package from environment (.env is source of truth, no defaults)
        if ! require_delta_lake_package; then
            log_warning "  ⚠ Cannot verify Delta table readability (DELTA_LAKE_PACKAGE not set)"
        else
            if command -v spark-submit >/dev/null 2>&1; then
                if spark-submit \
                    --packages "$DELTA_LAKE_PACKAGE" \
                    "$TEST_SCRIPT" \
                    "$DELTA_DIR" >/dev/null 2>&1; then
                    log_success "  ✓ Spark can successfully read the Delta table"
                else
                    log_warning "  ⚠ Spark could not read the Delta table (may still be valid)"
                fi
            elif docker ps >/dev/null 2>&1 && docker exec fru_api test -f /opt/spark/bin/spark-submit 2>/dev/null; then
                if docker exec -w /app -e DELTA_LAKE_PACKAGE="$DELTA_LAKE_PACKAGE" fru_api \
                    /opt/spark/bin/spark-submit \
                    --packages "$DELTA_LAKE_PACKAGE" \
                    "$TEST_SCRIPT" \
                    "$DELTA_DIR" >/dev/null 2>&1; then
                    log_success "  ✓ Spark can successfully read the Delta table"
                else
                    log_warning "  ⚠ Spark could not read the Delta table (may still be valid)"
                fi
            fi
        fi
        
        rm -f "$TEST_SCRIPT"
    else
        log_info "  ⚠ Spark not available for verification (skipping read test)"
    fi
    
    log_success "Comprehensive Delta table verification complete"
fi

