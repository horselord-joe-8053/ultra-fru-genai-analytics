#!/bin/bash
# Initialize database schema for AWS Aurora
# Uses RDS Data API (no direct network access to Aurora required)
# Usage: init_schema_aws <environment> [--force-refresh-data]

set -euo pipefail

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

AWS_PROFILE="${AWS_PROFILE:-admin}"
AWS_REGION="${AWS_REGION:-us-east-1}"

init_schema_aws() {
    local env="${1:-$ENVIRONMENT}"
    
    if ! command_exists aws; then
        log_error "aws CLI is required on PATH (missing: aws)."
        exit 1
    fi
    
    # Determine Terraform environment directory
    TERRAFORM_DIR="$REPO_ROOT/infra/terraform/environments"
    INFRA_DIR="$TERRAFORM_DIR/$env/infrastructure"
    SCHEMA_FILE="$REPO_ROOT/sql/schema_pgvector.sql"
    
    if [ ! -d "$INFRA_DIR" ]; then
        log_error "Infrastructure directory not found at $INFRA_DIR; cannot fetch outputs."
        exit 1
    fi
    
    if [ ! -f "$SCHEMA_FILE" ]; then
        log_error "Schema file not found at $SCHEMA_FILE"
        exit 1
    fi
    
    # Fetch required outputs from Terragrunt
    log_info "Fetching Aurora cluster information from Terraform outputs..."
    local output_error
    
    log_info "Fetching Terraform output: db_cluster_arn"
    if ! DB_CLUSTER_ARN=$(cd "$INFRA_DIR" && terragrunt output -raw db_cluster_arn 2>&1); then
        output_error="$DB_CLUSTER_ARN"
        DB_CLUSTER_ARN=""
        log_error "Failed to fetch Terraform output 'db_cluster_arn'"
        log_error "Error: ${output_error:0:500}"
    else
        log_info "Output retrieved: db_cluster_arn=${DB_CLUSTER_ARN:0:100}..."
    fi
    
    log_info "Fetching Terraform output: db_password_secret_arn"
    if ! DB_SECRET_ARN=$(cd "$INFRA_DIR" && terragrunt output -raw db_password_secret_arn 2>&1); then
        output_error="$DB_SECRET_ARN"
        DB_SECRET_ARN=""
        log_error "Failed to fetch Terraform output 'db_password_secret_arn'"
        log_error "Error: ${output_error:0:500}"
    else
        log_info "Output retrieved: db_password_secret_arn=${DB_SECRET_ARN:0:100}..."
    fi
    
    log_info "Fetching Terraform output: aurora_database_name"
    if ! DB_NAME=$(cd "$INFRA_DIR" && terragrunt output -raw aurora_database_name 2>&1); then
        log_warning "Failed to fetch Terraform output 'aurora_database_name', using default: fru_db"
        log_warning "Error: ${DB_NAME:0:500}"
        DB_NAME="fru_db"
    else
        log_info "Output retrieved: aurora_database_name=$DB_NAME"
    fi
    
    if [ -z "$DB_CLUSTER_ARN" ] || [ -z "$DB_SECRET_ARN" ]; then
        log_error "Missing db_cluster_arn or db_password_secret_arn from infrastructure outputs; cannot initialize schema."
        exit 1
    fi
    
    log_info "Using cluster ARN: $DB_CLUSTER_ARN"
    log_info "Using DB credentials secret ARN: $DB_SECRET_ARN"
    log_info "Database name: $DB_NAME"
    
    # If --force-refresh-data is set, drop tables first
    if [ "$FORCE_REFRESH_DATA" = "true" ]; then
        log_info "FORCE_REFRESH_DATA=true: Dropping existing tables (if any)..."
        aws rds-data execute-statement \
            --resource-arn "$DB_CLUSTER_ARN" \
            --secret-arn "$DB_SECRET_ARN" \
            --database "$DB_NAME" \
            --sql "DROP TABLE IF EXISTS batch_analytics CASCADE; DROP TABLE IF EXISTS fru_sales_embeddings CASCADE;" \
            --profile "$AWS_PROFILE" \
            --region "$AWS_REGION" >/dev/null 2>&1 || true
        log_info "Tables dropped (if they existed). Proceeding with fresh schema initialization..."
    else
        # Check if schema is already initialized by checking for main tables
        log_info "Checking if database schema is already initialized..."
        local table_exists=false
        local check_result
        
        # Check for fru_sales_embeddings table (main table)
        if check_result=$(aws rds-data execute-statement \
            --resource-arn "$DB_CLUSTER_ARN" \
            --secret-arn "$DB_SECRET_ARN" \
            --database "$DB_NAME" \
            --sql "SELECT EXISTS (SELECT FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'fru_sales_embeddings');" \
            --profile "$AWS_PROFILE" \
            --region "$AWS_REGION" \
            --output text \
            --query 'records[0][0].booleanValue' 2>&1); then
            if [ "$check_result" = "True" ] || [ "$check_result" = "true" ] || [ "$check_result" = "1" ]; then
                table_exists=true
            fi
        fi
        
        # Also check for batch_analytics table (secondary table)
        if [ "$table_exists" = true ]; then
            if check_result=$(aws rds-data execute-statement \
                --resource-arn "$DB_CLUSTER_ARN" \
                --secret-arn "$DB_SECRET_ARN" \
                --database "$DB_NAME" \
                --sql "SELECT EXISTS (SELECT FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'batch_analytics');" \
                --profile "$AWS_PROFILE" \
                --region "$AWS_REGION" \
                --output text \
                --query 'records[0][0].booleanValue' 2>&1); then
                if [ "$check_result" != "True" ] && [ "$check_result" != "true" ] && [ "$check_result" != "1" ]; then
                    table_exists=false
                fi
            else
                # If check failed, assume table doesn't exist and proceed with initialization
                table_exists=false
            fi
        fi
        
        if [ "$table_exists" = true ]; then
            log_info "Database schema already initialized (tables exist)"
            log_success "Skipping schema initialization (idempotent - schema unchanged)"
            return 0
        fi
        
        log_info "Database schema not found. Proceeding with initialization..."
    fi
    
    # Read schema file and split into individual statements
    # RDS Data API requires executing one statement at a time
    log_info "Reading schema file: $SCHEMA_FILE"
    
    # Split SQL file into individual statements (split on semicolons, but preserve CREATE statements)
    # Use a temporary file to process the SQL
    TEMP_SQL=$(mktemp)
    # Remove comments and empty lines, then split on semicolons
    sed 's/--.*$//' "$SCHEMA_FILE" | grep -v '^[[:space:]]*$' | tr '\n' ' ' | sed 's/;/;\n/g' > "$TEMP_SQL"
    
    # Execute each statement via RDS Data API
    log_info "Initializing database schema via RDS Data API (executing statements one by one)..."
    local statement_count=0
    local success_count=0
    
    while IFS= read -r sql_statement; do
        # Skip empty statements
        if [ -z "$(echo "$sql_statement" | tr -d '[:space:]')" ]; then
            continue
        fi
        
        statement_count=$((statement_count + 1))
        log_info "Executing statement $statement_count: $(echo "$sql_statement" | head -c 60)..."
        
        # Execute with retry logic
        MAX_RETRIES=3
        RETRY_COUNT=0
        local statement_success=false
        
        while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
            RETRY_COUNT=$((RETRY_COUNT + 1))
            
            if aws rds-data execute-statement \
                --resource-arn "$DB_CLUSTER_ARN" \
                --secret-arn "$DB_SECRET_ARN" \
                --database "$DB_NAME" \
                --sql "$sql_statement" \
                --profile "$AWS_PROFILE" \
                --region "$AWS_REGION" \
                >/dev/null 2>&1; then
                statement_success=true
                success_count=$((success_count + 1))
                break
            else
                if [ $RETRY_COUNT -lt $MAX_RETRIES ]; then
                    log_info "  Statement $statement_count failed, retrying in 1 second..."
                    sleep 1
                fi
            fi
        done
        
        if [ "$statement_success" = false ]; then
            log_warning "  Statement $statement_count failed after $MAX_RETRIES attempts (may already exist): $(echo "$sql_statement" | head -c 60)..."
        fi
    done < "$TEMP_SQL"
    
    rm -f "$TEMP_SQL"
    
    if [ $success_count -gt 0 ]; then
        log_success "Database schema initialization completed: $success_count/$statement_count statements executed successfully."
        return 0
    else
        log_error "Failed to execute any statements. Schema may already be initialized."
        return 1
    fi
}

