#!/bin/bash
# Initialize database schema
# Idempotent: SQL uses IF NOT EXISTS

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/../common/logger.sh"
source "$SCRIPT_DIR/../common/load-env.sh"

SCHEMA_FILE="$REPO_ROOT/sql/schema_pgvector.sql"

init_database() {
    log_step "Initializing database schema"
    
    # Load environment variables
    load_env_file
    
    # Check if schema file exists
    if [ ! -f "$SCHEMA_FILE" ]; then
        log_error "Schema file not found at $SCHEMA_FILE"
        exit 1
    fi
    
    # For local Docker, database is exposed on port 55432
    # Override PGHOST and PGPORT if using Docker
    if docker ps | grep -q fru_db; then
        PGHOST="localhost"
        PGPORT="55432"  # Docker exposes DB on 55432
        export PGHOST PGPORT
        log_info "  Database: $PGHOST:$PGPORT/$PGDATABASE (Docker)"
    else
        log_info "  Database: $PGHOST:$PGPORT/$PGDATABASE"
    fi
    
    # Check if psql is available
    if command_exists psql; then
        log_info "Using local psql to initialize schema..."
        PGPASSWORD="$PGPASSWORD" psql "postgresql://$PGUSER@$PGHOST:$PGPORT/$PGDATABASE" -f "$SCHEMA_FILE"
        log_success "Database schema initialized"
    elif docker ps | grep -q fru_db; then
        log_info "Using Docker exec to initialize schema..."
        docker exec -i fru_db psql -U "$PGUSER" -d "$PGDATABASE" < "$SCHEMA_FILE"
        log_success "Database schema initialized"
    else
        log_error "Neither psql nor Docker container 'fru_db' is available"
        log_error "Please install psql or ensure Docker services are running"
        exit 1
    fi
    
    # Verify schema was created
    log_info "Verifying schema..."
    if command_exists psql; then
        TABLE_COUNT=$(PGPASSWORD="$PGPASSWORD" psql "postgresql://$PGUSER@$PGHOST:$PGPORT/$PGDATABASE" -tAc "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'public' AND table_name IN ('fru_sales_embeddings', 'batch_analytics');")
    else
        TABLE_COUNT=$(docker exec fru_db psql -U "$PGUSER" -d "$PGDATABASE" -tAc "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'public' AND table_name IN ('fru_sales_embeddings', 'batch_analytics');")
    fi
    
    if [ "$TABLE_COUNT" -ge 2 ]; then
        log_success "Schema verification passed ($TABLE_COUNT tables found)"
    else
        log_warning "Schema verification: Only $TABLE_COUNT expected tables found (expected 2+)"
    fi
}

main() {
    init_database
}

main "$@"

