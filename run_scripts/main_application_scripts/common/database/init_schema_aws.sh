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
    local FORCE_TABLE_RECREATION=false  # Set to true when we know table doesn't exist or was dropped
    
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
    
    # Ensure pgvector extension is installed before creating tables with VECTOR columns
    # This is critical - RDS Data API may fail silently if extension isn't ready
    log_info "Ensuring pgvector extension is installed and ready..."
    aws rds-data execute-statement \
        --resource-arn "$DB_CLUSTER_ARN" \
        --secret-arn "$DB_SECRET_ARN" \
        --database "$DB_NAME" \
        --sql "CREATE EXTENSION IF NOT EXISTS vector;" \
        --profile "$AWS_PROFILE" \
        --region "$AWS_REGION" >/dev/null 2>&1 || log_warning "pgvector extension check had issues (may already exist)"
    
    # Wait for pgvector extension to be fully ready (not just installed, but actually usable)
    # This performs multiple checks: extension exists, VECTOR type available, can create VECTOR columns
    if [ -f "$REPO_ROOT/run_scripts/main_application_scripts/aws/database/wait-for-pgvector-ready.sh" ]; then
        source "$REPO_ROOT/run_scripts/main_application_scripts/aws/database/wait-for-pgvector-ready.sh"
        if ! wait_for_pgvector_ready "$DB_CLUSTER_ARN" "$DB_SECRET_ARN" "$DB_NAME" 60 2; then
            log_error "pgvector extension did not become ready - proceeding anyway but table creation may fail"
            log_warning "This may cause the embedding column to be missing - auto-fix will handle it if needed"
        fi
    else
        log_warning "wait-for-pgvector-ready.sh not found, using fallback delay..."
        sleep 3
    fi
    
    # If --force-refresh-data is set, drop tables first
    if [ "$FORCE_REFRESH_DATA" = "true" ]; then
        log_info "FORCE_REFRESH_DATA=true: Dropping existing tables (if any)..."
        
        # Drop tables separately to ensure both are dropped
        log_info "Dropping batch_analytics table (if exists)..."
        aws rds-data execute-statement \
            --resource-arn "$DB_CLUSTER_ARN" \
            --secret-arn "$DB_SECRET_ARN" \
            --database "$DB_NAME" \
            --sql "DROP TABLE IF EXISTS batch_analytics CASCADE;" \
            --profile "$AWS_PROFILE" \
            --region "$AWS_REGION" >/dev/null 2>&1 || true
        
        log_info "Dropping fru_sales_embeddings table (if exists)..."
        aws rds-data execute-statement \
            --resource-arn "$DB_CLUSTER_ARN" \
            --secret-arn "$DB_SECRET_ARN" \
            --database "$DB_NAME" \
            --sql "DROP TABLE IF EXISTS fru_sales_embeddings CASCADE;" \
            --profile "$AWS_PROFILE" \
            --region "$AWS_REGION" >/dev/null 2>&1 || true
        
        # Verify tables were dropped
        log_info "Verifying tables were dropped..."
        local table_exists=false
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
                log_warning "⚠️  Table still exists after DROP - this may cause issues with CREATE TABLE IF NOT EXISTS"
            else
                log_success "✓ Verified: fru_sales_embeddings table was dropped"
            fi
        fi
        
        log_info "Tables dropped (if they existed). Proceeding with fresh schema initialization..."
    else
        # Check if schema is already initialized by checking for main tables AND structure
        log_info "Checking if database schema is already initialized..."
        local table_exists=false
        local schema_correct=false
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
                
                # CRITICAL: Verify that the embedding column exists (required for data loading)
                log_info "Verifying table structure: checking for 'embedding' column..."
                if embedding_check=$(aws rds-data execute-statement \
                    --resource-arn "$DB_CLUSTER_ARN" \
                    --secret-arn "$DB_SECRET_ARN" \
                    --database "$DB_NAME" \
                    --sql "SELECT EXISTS (SELECT FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'fru_sales_embeddings' AND column_name = 'embedding');" \
                    --profile "$AWS_PROFILE" \
                    --region "$AWS_REGION" \
                    --output text \
                    --query 'records[0][0].booleanValue' 2>&1); then
                    if [ "$embedding_check" = "True" ] || [ "$embedding_check" = "true" ] || [ "$embedding_check" = "1" ]; then
                        schema_correct=true
                        log_success "✓ Verified: 'embedding' column exists in fru_sales_embeddings table"
                    else
                        log_warning "⚠️  Table exists but MISSING 'embedding' column - schema is incomplete"
                        log_warning "   This will cause data loading to fail. Forcing schema recreation..."
                        schema_correct=false
                    fi
                else
                    log_warning "⚠️  Could not verify 'embedding' column (check failed)"
                    log_warning "   Assuming schema may be incomplete. Proceeding with schema initialization..."
                    schema_correct=false
                fi
            fi
        fi
        
        # Also check for batch_analytics table (secondary table)
        if [ "$table_exists" = true ] && [ "$schema_correct" = true ]; then
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
                    schema_correct=false
                fi
            else
                # If check failed, assume table doesn't exist and proceed with initialization
                schema_correct=false
            fi
        fi
        
        if [ "$table_exists" = true ] && [ "$schema_correct" = true ]; then
            log_info "Database schema already initialized (tables exist with correct structure)"
            log_success "Skipping schema initialization (idempotent - schema unchanged)"
            return 0
        elif [ "$table_exists" = true ] && [ "$schema_correct" = false ]; then
            log_warning "Database schema exists but is incomplete or incorrect"
            log_warning "Dropping existing tables to ensure clean schema initialization..."
            # Drop tables before recreating
            aws rds-data execute-statement \
                --resource-arn "$DB_CLUSTER_ARN" \
                --secret-arn "$DB_SECRET_ARN" \
                --database "$DB_NAME" \
                --sql "DROP TABLE IF EXISTS batch_analytics CASCADE; DROP TABLE IF EXISTS fru_sales_embeddings CASCADE;" \
                --profile "$AWS_PROFILE" \
                --region "$AWS_REGION" >/dev/null 2>&1 || true
            log_info "Tables dropped. Proceeding with fresh schema initialization..."
            # Set flag to use CREATE TABLE (not IF NOT EXISTS) since we just dropped the table
            FORCE_TABLE_RECREATION=true
        else
            log_info "Database schema not found. Proceeding with initialization..."
            # Table doesn't exist, so we can use CREATE TABLE (not IF NOT EXISTS) to ensure proper creation
            FORCE_TABLE_RECREATION=true
        fi
    else
        # If FORCE_REFRESH_DATA is true, we've already dropped tables, so use CREATE TABLE
        FORCE_TABLE_RECREATION=true
    fi
    
    # Read schema file and split into individual statements
    # RDS Data API requires executing one statement at a time
    log_info "Reading schema file: $SCHEMA_FILE"
    
    # Split SQL file into individual statements (split on semicolons, but preserve CREATE statements)
    # Use a temporary file to process the SQL
    TEMP_SQL=$(mktemp)
    # Use Python script for more robust SQL parsing that handles parentheses correctly
    PARSE_SQL_SCRIPT="$SCRIPT_DIR/parse_sql_statements.py"
    if [ ! -f "$PARSE_SQL_SCRIPT" ]; then
        log_error "SQL parsing script not found at: $PARSE_SQL_SCRIPT"
        exit 1
    fi
    
    if ! python3 "$PARSE_SQL_SCRIPT" "$SCHEMA_FILE" > "$TEMP_SQL"; then
        log_error "Failed to parse SQL file: $SCHEMA_FILE"
        rm -f "$TEMP_SQL"
        exit 1
    fi
    
    # DEBUG: Print TEMP_SQL contents for debugging
    log_info "DEBUG: TEMP_SQL file created at: $TEMP_SQL"
    log_info "DEBUG: Number of statements parsed: $(wc -l < "$TEMP_SQL" | tr -d ' ')"
    log_info "DEBUG: TEMP_SQL file contents (first 10 lines):"
    head -10 "$TEMP_SQL" | while IFS= read -r line; do
        log_info "DEBUG:   $(echo "$line" | head -c 150)..."
    done || true
    
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
        
        # For CREATE TABLE statements, log the full statement to verify embedding column is included
        if echo "$sql_statement" | grep -qi "CREATE TABLE.*fru_sales_embeddings"; then
            log_info "Executing statement $statement_count: CREATE TABLE fru_sales_embeddings"
            log_info "DEBUG: Statement length: ${#sql_statement} characters"
            log_info "DEBUG: Full CREATE TABLE statement:"
            # Print statement in chunks to handle long lines
            echo "$sql_statement" | fold -w 120 | while IFS= read -r line; do
                log_info "DEBUG:   $line"
            done
            # Check if embedding column is in the statement
            if echo "$sql_statement" | grep -qi "embedding"; then
                log_info "DEBUG: ✓ CREATE TABLE statement contains 'embedding' column"
            else
                log_error "DEBUG: ✗ CREATE TABLE statement MISSING 'embedding' column!"
                log_error "DEBUG: This is a critical error - embedding column must be present"
                log_error "Skipping this statement to prevent incorrect table creation"
                continue
            fi
            # For CREATE TABLE IF NOT EXISTS, change to CREATE TABLE when we know table doesn't exist
            # This ensures the table is created with the correct structure (including VECTOR column)
            # RDS Data API may silently fail to create VECTOR columns with IF NOT EXISTS
            if [ "${FORCE_TABLE_RECREATION:-false}" = "true" ]; then
                # Replace "CREATE TABLE IF NOT EXISTS" with "CREATE TABLE" since we know table doesn't exist
                sql_statement=$(echo "$sql_statement" | sed 's/CREATE TABLE IF NOT EXISTS/CREATE TABLE/gi')
                log_info "DEBUG: Changed CREATE TABLE IF NOT EXISTS to CREATE TABLE (table doesn't exist or was dropped)"
            fi
        else
            log_info "Executing statement $statement_count: $(echo "$sql_statement" | head -c 60)..."
        fi
        
        # Execute with retry logic
        MAX_RETRIES=3
        RETRY_COUNT=0
        local statement_success=false
        local last_error=""
        
        while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
            RETRY_COUNT=$((RETRY_COUNT + 1))
            
            # Capture error output for debugging
            local error_output
            if error_output=$(aws rds-data execute-statement \
                --resource-arn "$DB_CLUSTER_ARN" \
                --secret-arn "$DB_SECRET_ARN" \
                --database "$DB_NAME" \
                --sql "$sql_statement" \
                --profile "$AWS_PROFILE" \
                --region "$AWS_REGION" \
                2>&1); then
                statement_success=true
                success_count=$((success_count + 1))
                if echo "$sql_statement" | grep -qi "CREATE TABLE.*fru_sales_embeddings"; then
                    log_success "  ✓ CREATE TABLE statement executed successfully"
                fi
                break
            else
                last_error="$error_output"
                if [ $RETRY_COUNT -lt $MAX_RETRIES ]; then
                    log_info "  Statement $statement_count failed, retrying in 1 second..."
                    log_info "  Error: $(echo "$error_output" | head -c 200)"
                    sleep 1
                fi
            fi
        done
        
        if [ "$statement_success" = false ]; then
            log_warning "  Statement $statement_count failed after $MAX_RETRIES attempts"
            log_warning "  Statement: $(echo "$sql_statement" | head -c 100)..."
            log_warning "  Last error: $(echo "$last_error" | head -c 500)"
            # If this is a CREATE TABLE statement, this is more serious
            if echo "$sql_statement" | grep -qi "CREATE TABLE"; then
                log_error "  ⚠️  CRITICAL: CREATE TABLE statement failed - table may not be created correctly!"
            fi
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

