#!/bin/bash
# Initialize database schema for AWS Aurora
# Uses RDS Data API (no direct network access to Aurora required)
# Usage: init_schema_aws <environment>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
source "$SCRIPT_DIR/../logger.sh"

ENVIRONMENT="${1:-dev}"
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
    DB_CLUSTER_ARN=$(cd "$INFRA_DIR" && terragrunt output -raw db_cluster_arn 2>/dev/null || echo "")
    DB_SECRET_ARN=$(cd "$INFRA_DIR" && terragrunt output -raw db_password_secret_arn 2>/dev/null || echo "")
    DB_NAME=$(cd "$INFRA_DIR" && terragrunt output -raw aurora_database_name 2>/dev/null || echo "fru_db")
    
    if [ -z "$DB_CLUSTER_ARN" ] || [ -z "$DB_SECRET_ARN" ]; then
        log_error "Missing db_cluster_arn or db_password_secret_arn from infrastructure outputs; cannot initialize schema."
        exit 1
    fi
    
    log_info "Using cluster ARN: $DB_CLUSTER_ARN"
    log_info "Using DB credentials secret ARN: $DB_SECRET_ARN"
    log_info "Database name: $DB_NAME"
    
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

