#!/bin/bash
# Initialize database schema on Aurora (creates tables: fru_sales_embeddings, batch_analytics)
# Usage: ./init_db_schema.sh <env>
# Uses the RDS Data API (no direct network access to Aurora required).
# Requires: aws cli; AWS_PROFILE (admin) and AWS_REGION set by caller.

set -euo pipefail

ENVIRONMENT="${1:-dev}"
AWS_PROFILE="${AWS_PROFILE:-admin}"
AWS_REGION="${AWS_REGION:-us-east-1}"

command_exists() { command -v "$1" >/dev/null 2>&1; }

log() {
  echo "[init-db-schema][$ENVIRONMENT] $*"
}

main() {
  if ! command_exists aws; then
    log "aws CLI is required on PATH (missing: aws)."
    exit 1
  fi

  # Determine Terraform environment directory
  REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
  TERRAFORM_DIR="$REPO_ROOT/infra/terraform/environments"
  INFRA_DIR="$TERRAFORM_DIR/$ENVIRONMENT/infrastructure"
  SCHEMA_FILE="$REPO_ROOT/sql/schema_pgvector.sql"

  if [ ! -d "$INFRA_DIR" ]; then
    log "Infrastructure directory not found at $INFRA_DIR; cannot fetch outputs."
    exit 1
  fi

  if [ ! -f "$SCHEMA_FILE" ]; then
    log "Schema file not found at $SCHEMA_FILE"
    exit 1
  fi

  # Fetch required outputs from Terragrunt
  log "Fetching Aurora cluster information from Terraform outputs..."
  DB_CLUSTER_ARN=$(cd "$INFRA_DIR" && terragrunt output -raw db_cluster_arn 2>/dev/null || echo "")
  DB_SECRET_ARN=$(cd "$INFRA_DIR" && terragrunt output -raw db_password_secret_arn 2>/dev/null || echo "")
  DB_NAME=$(cd "$INFRA_DIR" && terragrunt output -raw aurora_database_name 2>/dev/null || echo "fru_db")

  if [ -z "$DB_CLUSTER_ARN" ] || [ -z "$DB_SECRET_ARN" ]; then
    log "Missing db_cluster_arn or db_password_secret_arn from infrastructure outputs; cannot initialize schema."
    exit 1
  fi

  log "Using cluster ARN: $DB_CLUSTER_ARN"
  log "Using DB credentials secret ARN: $DB_SECRET_ARN"
  log "Database name: $DB_NAME"

  # Read schema file and split into individual statements
  # RDS Data API requires executing one statement at a time
  log "Reading schema file: $SCHEMA_FILE"
  
  # Split SQL file into individual statements (split on semicolons, but preserve CREATE statements)
  # Use a temporary file to process the SQL
  TEMP_SQL=$(mktemp)
  # Remove comments and empty lines, then split on semicolons
  sed 's/--.*$//' "$SCHEMA_FILE" | grep -v '^[[:space:]]*$' | tr '\n' ' ' | sed 's/;/;\n/g' > "$TEMP_SQL"
  
  # Execute each statement via RDS Data API
  log "Initializing database schema via RDS Data API (executing statements one by one)..."
  local statement_count=0
  local success_count=0
  
  while IFS= read -r sql_statement; do
    # Skip empty statements
    if [ -z "$(echo "$sql_statement" | tr -d '[:space:]')" ]; then
      continue
    fi
    
    statement_count=$((statement_count + 1))
    log "Executing statement $statement_count: $(echo "$sql_statement" | head -c 60)..."
    
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
          log "  Statement $statement_count failed, retrying in 1 second..."
          sleep 1
        fi
      fi
    done
    
    if [ "$statement_success" = false ]; then
      log "  Warning: Statement $statement_count failed after $MAX_RETRIES attempts (may already exist): $(echo "$sql_statement" | head -c 60)..."
    fi
  done < "$TEMP_SQL"
  
  rm -f "$TEMP_SQL"
  
  if [ $success_count -gt 0 ]; then
    log "Database schema initialization completed: $success_count/$statement_count statements executed successfully."
    return 0
  else
    log "Failed to execute any statements. Schema may already be initialized."
    return 1
  fi
}

main "$@"

