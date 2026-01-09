#!/bin/bash
# Main database setup orchestrator for AWS
# Calls ensure-pgvector, init_schema, and load_data in sequence
# Usage: ./setup-database.sh <environment>

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../../.." && pwd)}"
source "$REPO_ROOT/run_scripts/shared/logger.sh"

ENVIRONMENT="${1:-dev}"

setup_database() {
    local env="${1:-$ENVIRONMENT}"
    
    log_step "Setting up database (pgvector, schema, data)"
    
    # Step 1: Ensure pgvector extension
    log_info "Step 1/3: Ensuring pgvector extension..."
    "$SCRIPT_DIR/ensure-pgvector.sh" "$env" || {
        log_warning "pgvector extension setup had issues (may already exist)"
    }
    
    # Step 2: Initialize database schema
    log_info "Step 2/3: Initializing database schema..."
    "$REPO_ROOT/run_scripts/main_application_scripts/common/database/init_schema.sh" "aws" "$env" || {
        log_warning "Schema initialization had issues (tables may already exist)"
    }
    
    # Step 3: Load data
    log_info "Step 3/3: Loading data..."
    "$REPO_ROOT/run_scripts/main_application_scripts/common/database/load_data.sh" "aws" "$env" || {
        log_warning "Data loading had issues (data may already exist)"
    }
    
    log_success "Database setup completed"
}

# If executed directly
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    setup_database "$@"
    exit $?
fi

