#!/bin/bash
# Load CSV data into local database via ETL script
# Idempotent: checks if data already exists before loading

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
source "$SCRIPT_DIR/../logger.sh"
source "$SCRIPT_DIR/../load-env.sh"

load_data_local() {
    log_step "Loading data into database (local)"
    
    ETL_SCRIPT="$REPO_ROOT/backend/etl/load_openai_embeddings_to_pgvector.py"
    CSV_FILE="$REPO_ROOT/data/raw/fridge_sales_with_rating.csv"
    
    # Load environment variables
    load_env_file || true
    
    # Check if ETL script exists
    if [ ! -f "$ETL_SCRIPT" ]; then
        log_error "ETL script not found at $ETL_SCRIPT"
        exit 1
    fi
    
    # Check if CSV file exists
    if [ ! -f "$CSV_FILE" ]; then
        log_error "CSV file not found at $CSV_FILE"
        exit 1
    fi
    
    # Check if virtual environment exists
    if [ ! -d "$REPO_ROOT/venv" ]; then
        log_error "Python virtual environment not found. Please run setup-python.sh first."
        exit 1
    fi
    
    # Activate virtual environment
    source "$REPO_ROOT/venv/bin/activate"
    
    # Check if data is already loaded
    log_info "Checking if data is already loaded..."
    ROW_COUNT=0
    if command_exists psql; then
        ROW_COUNT=$(PGPASSWORD="$PGPASSWORD" psql "postgresql://$PGUSER@$PGHOST:$PGPORT/$PGDATABASE" -tAc "SELECT COUNT(*) FROM fru_sales_embeddings;" 2>/dev/null || echo "0")
    elif docker ps | grep -q fru_db; then
        ROW_COUNT=$(docker exec fru_db psql -U "$PGUSER" -d "$PGDATABASE" -tAc "SELECT COUNT(*) FROM fru_sales_embeddings;" 2>/dev/null || echo "0")
    fi
    
    if [ "$ROW_COUNT" -gt 0 ]; then
        log_info "Data already loaded ($ROW_COUNT rows found). Skipping ETL."
        log_info "To reload data, drop the table first or use --force flag (not implemented yet)"
        return 0
    fi
    
    # Set CSV path if not already set
    export FRU_CSV_PATH="${FRU_CSV_PATH:-$CSV_FILE}"
    
    # Run ETL script
    log_info "Running ETL script to load data..."
    log_info "  CSV: $FRU_CSV_PATH"
    
    # For local Docker, database is exposed on port 55432
    # Override PGHOST and PGPORT if using Docker
    if docker ps | grep -q fru_db; then
        # Force override for Docker
        PGHOST="localhost"
        PGPORT="55432"  # Docker exposes DB on 55432
        export PGHOST PGPORT
        log_info "  Database: $PGHOST:$PGPORT/$PGDATABASE (Docker)"
    else
        log_info "  Database: $PGHOST:$PGPORT/$PGDATABASE"
    fi
    
    # Export all required environment variables for ETL script
    # These are already loaded by load_env_file, but ensure they're exported
    export PGHOST PGPORT PGUSER PGPASSWORD PGDATABASE
    export OPENAI_API_KEY OPENAI_EMBED_MODEL
    
    # Run from repo root with PYTHONPATH set so imports work
    cd "$REPO_ROOT"
    export PYTHONPATH="$REPO_ROOT:$PYTHONPATH"
    python backend/etl/load_openai_embeddings_to_pgvector.py
    
    if [ $? -eq 0 ]; then
        log_success "Data loaded successfully"
    else
        log_error "ETL script failed"
        exit 1
    fi
}

