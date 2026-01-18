#!/bin/bash
# Load CSV data into AWS Aurora database via ETL script
# Idempotent: checks if data already exists before loading
#
# This script runs LOCALLY on your machine but connects to AWS Aurora (remote database).
# It reads credentials from .env file (single source of truth) and gets Aurora endpoint
# from Terragrunt outputs.
#
# Usage: load_data_aws [environment] [--force-refresh-data]
# Example: load_data_aws dev
# Example: load_data_aws dev --force-refresh-data

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../../.." && pwd)}"
source "$REPO_ROOT/run_scripts/shared/logger.sh"
source "$REPO_ROOT/run_scripts/shared/load-env.sh"

# Default environment
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

# AWS configuration
AWS_PROFILE="${AWS_PROFILE:-admin}"
AWS_REGION="${AWS_REGION:-us-east-1}"

ETL_SCRIPT="$REPO_ROOT/backend/etl/load_openai_embeddings_to_pgvector.py"
CSV_FILE="$REPO_ROOT/data/raw/fridge_sales_with_rating.csv"

load_data_aws() {
    local env="${1:-$ENVIRONMENT}"
    log_step "Loading data into Aurora database"
    
    # Navigate to infrastructure directory
    local infra_dir="$REPO_ROOT/infra/terraform/environments/$env/infrastructure"
    if [ ! -d "$infra_dir" ]; then
        log_error "Infrastructure directory not found: $infra_dir"
        exit 1
    fi
    
    # Fetch Aurora cluster info from Terragrunt outputs (for RDS Data API)
    log_info "Fetching Aurora cluster information from Terraform outputs..."
    
    local db_cluster_arn db_secret_arn db_name
    local output_error
    
    log_info "Fetching Terraform output: db_cluster_arn"
    if ! db_cluster_arn=$(cd "$infra_dir" && terragrunt output -raw db_cluster_arn 2>&1); then
        output_error="$db_cluster_arn"
        db_cluster_arn=""
        log_error "Failed to fetch Terraform output 'db_cluster_arn'"
        log_error "Error: ${output_error:0:500}"
    else
        log_info "Output retrieved: db_cluster_arn=${db_cluster_arn:0:100}..."
    fi
    
    log_info "Fetching Terraform output: db_password_secret_arn"
    if ! db_secret_arn=$(cd "$infra_dir" && terragrunt output -raw db_password_secret_arn 2>&1); then
        output_error="$db_secret_arn"
        db_secret_arn=""
        log_error "Failed to fetch Terraform output 'db_password_secret_arn'"
        log_error "Error: ${output_error:0:500}"
    else
        log_info "Output retrieved: db_password_secret_arn=${db_secret_arn:0:100}..."
    fi
    
    log_info "Fetching Terraform output: aurora_database_name"
    if ! db_name=$(cd "$infra_dir" && terragrunt output -raw aurora_database_name 2>&1); then
        log_warning "Failed to fetch Terraform output 'aurora_database_name', using default: fru_db"
        log_warning "Error: ${db_name:0:500}"
        db_name="fru_db"
    else
        log_info "Output retrieved: aurora_database_name=$db_name"
    fi
    
    if [ -z "$db_cluster_arn" ] || [ -z "$db_secret_arn" ]; then
        log_error "Missing Aurora cluster ARN or secret ARN from infrastructure outputs"
        log_info "  db_cluster_arn: ${db_cluster_arn:-NOT SET}"
        log_info "  db_secret_arn: ${db_secret_arn:-NOT SET}"
        log_info ""
        log_info "Please ensure infrastructure is deployed first:"
        log_info "  ./run_scripts/aws/run.sh infrastructure $env"
        exit 1
    fi
    
    log_info "Using Aurora cluster ARN: $db_cluster_arn"
    log_info "Using secret ARN: $db_secret_arn"
    log_info "Using database: $db_name"
    
    # Load environment variables
    load_env_file
    
    # RDS Data API uses Secrets Manager ARN (no direct credentials needed)
    log_info "Using RDS Data API (no direct database credentials required)"
    
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
    
    # Check if data needs to be reloaded using change detection
    log_info "Checking if data needs to be reloaded..."
    
    # Calculate current CSV file hash
    local csv_hash
    if command -v sha256sum >/dev/null 2>&1; then
        csv_hash=$(sha256sum "$CSV_FILE" | cut -d' ' -f1)
    elif command -v shasum >/dev/null 2>&1; then
        csv_hash=$(shasum -a 256 "$CSV_FILE" | cut -d' ' -f1)
    else
        log_warning "Cannot calculate CSV hash (sha256sum/shasum not found). Using timestamp-based check."
        csv_hash="unknown-$(stat -f %m "$CSV_FILE" 2>/dev/null || stat -c %Y "$CSV_FILE" 2>/dev/null || echo "0")"
    fi
    
    # Calculate current schema version hash
    local schema_file="$REPO_ROOT/sql/schema_pgvector.sql"
    local schema_hash
    if [ -f "$schema_file" ]; then
        if command -v sha256sum >/dev/null 2>&1; then
            schema_hash=$(sha256sum "$schema_file" | cut -d' ' -f1)
        elif command -v shasum >/dev/null 2>&1; then
            schema_hash=$(shasum -a 256 "$schema_file" | cut -d' ' -f1)
        else
            schema_hash="unknown"
        fi
    else
        log_warning "Schema file not found: $schema_file"
        schema_hash="unknown"
    fi
    
    # Check row count
    local row_count=0
    row_count=$(aws rds-data execute-statement \
        --resource-arn "$db_cluster_arn" \
        --secret-arn "$db_secret_arn" \
        --database "$db_name" \
        --sql "SELECT COUNT(*) FROM fru_sales_embeddings;" \
        --profile "$AWS_PROFILE" \
        --region "$AWS_REGION" \
        --output text \
        --query 'records[0][0].longValue' 2>/dev/null || echo "0")
    
    # Check stored metadata (CSV hash and schema version)
    local stored_csv_hash stored_schema_hash
    stored_csv_hash=$(aws rds-data execute-statement \
        --resource-arn "$db_cluster_arn" \
        --secret-arn "$db_secret_arn" \
        --database "$db_name" \
        --sql "SELECT value FROM metadata WHERE key='csv_hash';" \
        --profile "$AWS_PROFILE" \
        --region "$AWS_REGION" \
        --output text \
        --query 'records[0][0].stringValue' 2>/dev/null || echo "")
    
    stored_schema_hash=$(aws rds-data execute-statement \
        --resource-arn "$db_cluster_arn" \
        --secret-arn "$db_secret_arn" \
        --database "$db_name" \
        --sql "SELECT value FROM metadata WHERE key='schema_version';" \
        --profile "$AWS_PROFILE" \
        --region "$AWS_REGION" \
        --output text \
        --query 'records[0][0].stringValue' 2>/dev/null || echo "")
    
    # If --force-refresh-data is set, TRUNCATE table and bypass pre-check
    if [ "$FORCE_REFRESH_DATA" = "true" ]; then
        log_info "FORCE_REFRESH_DATA=true: Truncating existing data..."
        aws rds-data execute-statement \
            --resource-arn "$db_cluster_arn" \
            --secret-arn "$db_secret_arn" \
            --database "$db_name" \
            --sql "TRUNCATE TABLE fru_sales_embeddings CASCADE;" \
            --profile "$AWS_PROFILE" \
            --region "$AWS_REGION" >/dev/null 2>&1 || true
        log_info "Table truncated. Proceeding with fresh data load..."
        needs_reload=true
        reload_reason="FORCE_REFRESH_DATA flag is set"
    else
        # Determine if reload is needed
        local needs_reload=false
        local reload_reason=""
        
        if [ "$row_count" -eq 0 ] || [ "$row_count" = "0" ]; then
            needs_reload=true
            reload_reason="No data found in database"
        elif [ -z "$stored_csv_hash" ]; then
            # Metadata table doesn't exist or is empty - reload to establish baseline
            needs_reload=true
            reload_reason="Metadata not found (first load or metadata table missing)"
        elif [ "$csv_hash" != "$stored_csv_hash" ]; then
            needs_reload=true
            reload_reason="CSV file has changed (hash: ${csv_hash:0:8}... vs stored: ${stored_csv_hash:0:8}...)"
        elif [ "$schema_hash" != "$stored_schema_hash" ] && [ "$schema_hash" != "unknown" ]; then
            needs_reload=true
            reload_reason="Schema has changed (hash: ${schema_hash:0:8}... vs stored: ${stored_schema_hash:0:8}...)"
        fi
        
        if [ "$needs_reload" = false ]; then
            log_info "Data is up to date:"
            log_info "  - Row count: $row_count"
            log_info "  - CSV hash matches stored hash"
            if [ "$schema_hash" != "unknown" ]; then
                log_info "  - Schema version matches stored version"
            fi
            log_info "Skipping data reload."
            return 0
        fi
        
        # Reload needed
        log_info "Data reload needed: $reload_reason"
        log_info "  - Current CSV hash: ${csv_hash:0:16}..."
        log_info "  - Current schema hash: ${schema_hash:0:16}..."
        
        # For non-interactive mode (automated deployments), auto-reload
        # For interactive mode, prompt user
        if [ -t 0 ] && [ "${FORCE_RELOAD:-false}" != "true" ]; then
            # Interactive mode: prompt user
            read -p "Do you want to reload data? This will upsert existing rows. (y/N): " -n 1 -r
            echo # Add a newline after the prompt
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                log_info "Skipping data reload."
                return 0
            fi
        else
            # Non-interactive mode: auto-reload
            log_info "Non-interactive mode: Auto-reloading data..."
        fi
    fi
    
    # CRITICAL: Validate schema before attempting data load (fail-fast)
    log_info "Validating database schema before data load..."
    local table_exists=false
    local embedding_column_exists=false
    
    # Check if table exists
    if check_result=$(aws rds-data execute-statement \
        --resource-arn "$db_cluster_arn" \
        --secret-arn "$db_secret_arn" \
        --database "$db_name" \
        --sql "SELECT EXISTS (SELECT FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'fru_sales_embeddings');" \
        --profile "$AWS_PROFILE" \
        --region "$AWS_REGION" \
        --output text \
        --query 'records[0][0].booleanValue' 2>&1); then
        if [ "$check_result" = "True" ] || [ "$check_result" = "true" ] || [ "$check_result" = "1" ]; then
            table_exists=true
            log_success "✓ Table 'fru_sales_embeddings' exists"
            
            # Check if embedding column exists
            if embedding_check=$(aws rds-data execute-statement \
                --resource-arn "$db_cluster_arn" \
                --secret-arn "$db_secret_arn" \
                --database "$db_name" \
                --sql "SELECT EXISTS (SELECT FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'fru_sales_embeddings' AND column_name = 'embedding');" \
                --profile "$AWS_PROFILE" \
                --region "$AWS_REGION" \
                --output text \
                --query 'records[0][0].booleanValue' 2>&1); then
                if [ "$embedding_check" = "True" ] || [ "$embedding_check" = "true" ] || [ "$embedding_check" = "1" ]; then
                    embedding_column_exists=true
                    log_success "✓ Column 'embedding' exists in 'fru_sales_embeddings' table"
                else
                    log_error "✗ Column 'embedding' does NOT exist in 'fru_sales_embeddings' table"
                    log_error "  This will cause all INSERT statements to fail!"
                    log_error "  Please run schema initialization first: init_schema_aws.sh"
                    exit 1
                fi
            else
                log_error "✗ Failed to verify 'embedding' column (check query failed)"
                log_error "  Error: $(echo "$embedding_check" | head -c 200)"
                log_error "  Cannot proceed with data load - schema validation failed"
                exit 1
            fi
        else
            log_error "✗ Table 'fru_sales_embeddings' does NOT exist"
            log_error "  Please run schema initialization first: init_schema_aws.sh"
            exit 1
        fi
    else
        log_error "✗ Failed to verify table existence (check query failed)"
        log_error "  Error: $(echo "$check_result" | head -c 200)"
        log_error "  Cannot proceed with data load - schema validation failed"
        exit 1
    fi
    
    if [ "$table_exists" = true ] && [ "$embedding_column_exists" = true ]; then
        log_success "Schema validation passed - ready to load data"
    else
        log_error "Schema validation failed - cannot proceed with data load"
        exit 1
    fi
    
    # Set environment variables for RDS Data API ETL script
    export FRU_CSV_PATH="${FRU_CSV_PATH:-$CSV_FILE}"
    export DB_CLUSTER_ARN="$db_cluster_arn"
    export DB_SECRET_ARN="$db_secret_arn"
    export PGDATABASE="$db_name"
    export AWS_PROFILE="$AWS_PROFILE"
    export AWS_REGION="$AWS_REGION"
    export OPENAI_API_KEY="${OPENAI_API_KEY:-}"
    export OPENAI_EMBED_MODEL="${OPENAI_EMBED_MODEL:-text-embedding-3-small}"
    
    # Run ETL script using RDS Data API
    log_info "Running ETL script via RDS Data API..."
    log_info "  CSV: $FRU_CSV_PATH"
    log_info "  Cluster ARN: $db_cluster_arn"
    log_info "  Database: $db_name"
    
    cd "$REPO_ROOT"
    python -m backend.etl.load_openai_embeddings_to_pgvector_rds_api
    
    if [ $? -eq 0 ]; then
        log_success "Data loaded successfully"
        
        # Store metadata after successful load
        log_info "Storing metadata (CSV hash, schema version)..."
        
        # Ensure metadata table exists
        aws rds-data execute-statement \
            --resource-arn "$db_cluster_arn" \
            --secret-arn "$db_secret_arn" \
            --database "$db_name" \
            --sql "CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY, value TEXT, updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP);" \
            --profile "$AWS_PROFILE" \
            --region "$AWS_REGION" \
            >/dev/null 2>&1 || true
        
        # Store CSV hash
        aws rds-data execute-statement \
            --resource-arn "$db_cluster_arn" \
            --secret-arn "$db_secret_arn" \
            --database "$db_name" \
            --sql "INSERT INTO metadata (key, value, updated_at) VALUES ('csv_hash', '$csv_hash', CURRENT_TIMESTAMP) ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = CURRENT_TIMESTAMP;" \
            --profile "$AWS_PROFILE" \
            --region "$AWS_REGION" \
            >/dev/null 2>&1 || log_warning "Failed to store CSV hash in metadata"
        
        # Store schema version
        if [ "$schema_hash" != "unknown" ]; then
            aws rds-data execute-statement \
                --resource-arn "$db_cluster_arn" \
                --secret-arn "$db_secret_arn" \
                --database "$db_name" \
                --sql "INSERT INTO metadata (key, value, updated_at) VALUES ('schema_version', '$schema_hash', CURRENT_TIMESTAMP) ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = CURRENT_TIMESTAMP;" \
                --profile "$AWS_PROFILE" \
                --region "$AWS_REGION" \
                >/dev/null 2>&1 || log_warning "Failed to store schema version in metadata"
        fi
        
        # Store embedding model version
        local embed_model="${OPENAI_EMBED_MODEL:-text-embedding-3-small}"
        aws rds-data execute-statement \
            --resource-arn "$db_cluster_arn" \
            --secret-arn "$db_secret_arn" \
            --database "$db_name" \
            --sql "INSERT INTO metadata (key, value, updated_at) VALUES ('embedding_model', '$embed_model', CURRENT_TIMESTAMP) ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = CURRENT_TIMESTAMP;" \
            --profile "$AWS_PROFILE" \
            --region "$AWS_REGION" \
            >/dev/null 2>&1 || log_warning "Failed to store embedding model in metadata"
        
        log_success "Metadata stored successfully"
    else
        log_error "ETL script failed"
        exit 1
    fi
}

# Function is exported for use by wrapper script

