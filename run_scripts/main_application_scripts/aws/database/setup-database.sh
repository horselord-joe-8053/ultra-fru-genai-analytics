#!/bin/bash
# Main database setup orchestrator for AWS
# Calls ensure-pgvector, init_schema, and load_data in sequence
# Usage: ./setup-database.sh <environment> [--force-refresh-data]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../../.." && pwd)}"
source "$REPO_ROOT/run_scripts/shared/logger.sh"

ENVIRONMENT="${1:-dev}"
FORCE_REFRESH_DATA="${FORCE_REFRESH_DATA:-false}"

# Parse arguments
ARGS=()
for arg in "$@"; do
    if [ "$arg" = "--force-refresh-data" ]; then
        FORCE_REFRESH_DATA=true
    else
        ARGS+=("$arg")
    fi
done

# Update ENVIRONMENT from parsed args if provided
if [ ${#ARGS[@]} -gt 0 ]; then
    ENVIRONMENT="${ARGS[0]:-$ENVIRONMENT}"
fi

setup_database() {
    local env="${1:-$ENVIRONMENT}"
    
    log_step "Setting up database (pgvector, schema, data)"
    
    # Step 1: Ensure pgvector extension
    log_info "Substep 1/3: Ensuring pgvector extension..."
    local pgvector_cmd="$SCRIPT_DIR/ensure-pgvector.sh $env"
    if [ "$FORCE_REFRESH_DATA" = "true" ]; then
        pgvector_cmd="$pgvector_cmd --force-refresh-data"
    fi
    $pgvector_cmd || {
        log_warning "pgvector extension setup had issues (may already exist)"
    }
    
    # Step 2: Initialize database schema
    log_info "Substep 2/3: Initializing database schema..."
    local schema_cmd="$REPO_ROOT/run_scripts/main_application_scripts/common/database/init_schema.sh aws $env"
    if [ "$FORCE_REFRESH_DATA" = "true" ]; then
        schema_cmd="$schema_cmd --force-refresh-data"
    fi
    $schema_cmd || {
        log_warning "Schema initialization had issues (tables may already exist)"
    }
    
    # Step 3: Load data
    log_info "Substep 3/3: Loading data..."
    local load_cmd="$REPO_ROOT/run_scripts/main_application_scripts/common/database/load_data.sh aws $env"
    if [ "$FORCE_REFRESH_DATA" = "true" ]; then
        load_cmd="$load_cmd --force-refresh-data"
    fi
    $load_cmd || {
        log_warning "Data loading had issues (data may already exist)"
    }
    
    log_success "Database setup completed"
}

# If executed directly
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    setup_database "$@"
    exit $?
fi

