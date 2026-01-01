#!/bin/bash
# Reset fru_sales_embeddings table (drop and recreate)
# WARNING: This will delete all data in fru_sales_embeddings table
# Preserves batch_analytics table

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/../common/logger.sh"
source "$SCRIPT_DIR/../common/load-env.sh"

reset_database() {
    log_step "Resetting fru_sales_embeddings table"
    
    # Load environment variables
    load_env_file
    
    # Check if Docker container is running
    if ! docker ps | grep -q fru_db; then
        log_error "Docker container 'fru_db' is not running"
        log_error "Please start Docker services first: ./run_scripts/local/start-services.sh"
        exit 1
    fi
    
    log_warning "⚠️  WARNING: This will DELETE all data in fru_sales_embeddings table"
    log_warning "⚠️  The batch_analytics table will be preserved"
    echo ""
    read -p "Are you sure you want to continue? (yes/no): " confirm
    if [ "$confirm" != "yes" ]; then
        log_info "Reset cancelled"
        exit 0
    fi
    
    # Step 1: Drop the table (CASCADE to drop indexes and constraints)
    log_step "Step 1/3: Dropping fru_sales_embeddings table..."
    if docker exec fru_db psql -U "$PGUSER" -d "$PGDATABASE" -c "DROP TABLE IF EXISTS fru_sales_embeddings CASCADE;" 2>/dev/null; then
        log_success "Table dropped successfully"
    else
        log_error "Failed to drop table"
        exit 1
    fi
    
    # Step 2: Recreate schema
    log_step "Step 2/3: Recreating schema..."
    SCHEMA_FILE="$REPO_ROOT/sql/schema_pgvector.sql"
    if [ ! -f "$SCHEMA_FILE" ]; then
        log_error "Schema file not found at $SCHEMA_FILE"
        exit 1
    fi
    log_info "Applying schema file..."
    docker exec -i fru_db psql -U "$PGUSER" -d "$PGDATABASE" < "$SCHEMA_FILE"
    log_success "Schema recreated successfully"
    
    # Step 3: Repopulate data
    log_step "Step 3/3: Repopulating data from CSV..."
    "$SCRIPT_DIR/load-data.sh"
    
    # Verify the reset
    log_step "Verifying reset..."
    FEEDBACK_RATING_TYPE=$(docker exec fru_db psql -U "$PGUSER" -d "$PGDATABASE" -tAc "SELECT data_type FROM information_schema.columns WHERE table_name = 'fru_sales_embeddings' AND column_name = 'feedback_rating';" 2>/dev/null || echo "")
    ROW_COUNT=$(docker exec fru_db psql -U "$PGUSER" -d "$PGDATABASE" -tAc "SELECT COUNT(*) FROM fru_sales_embeddings;" 2>/dev/null || echo "0")
    
    if [ "$FEEDBACK_RATING_TYPE" = "integer" ]; then
        log_success "✅ feedback_rating column is INTEGER (correct)"
    else
        log_error "❌ feedback_rating column is $FEEDBACK_RATING_TYPE (expected integer)"
        exit 1
    fi
    
    if [ "$ROW_COUNT" -gt 0 ]; then
        log_success "✅ Data repopulated successfully ($ROW_COUNT rows)"
    else
        log_warning "⚠️  No data found in table (expected if ETL failed)"
    fi
    
    log_success "Database reset complete!"
    log_info "  - feedback_rating type: $FEEDBACK_RATING_TYPE"
    log_info "  - Row count: $ROW_COUNT"
}

main() {
    reset_database
}

main "$@"

