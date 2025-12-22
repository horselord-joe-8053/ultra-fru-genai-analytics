#!/bin/bash
# Load CSV data into AWS Aurora database via ETL script
# Idempotent: checks if data already exists before loading
#
# This script runs LOCALLY on your machine but connects to AWS Aurora (remote database).
# It reads credentials from .env file (single source of truth) and gets Aurora endpoint
# from Terragrunt outputs.
#
# Usage: ./load_data_to_aurora.sh [environment]
# Example: ./load_data_to_aurora.sh dev
#
# Note: This is for AWS setup, not local development.
# For local development, use: run_scripts/local/load-data.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
source "$SCRIPT_DIR/../../common/logger.sh"
source "$SCRIPT_DIR/../../common/load-env.sh"

# Default environment
ENVIRONMENT="${1:-dev}"

# AWS configuration
AWS_PROFILE="${AWS_PROFILE:-admin}"
AWS_REGION="${AWS_REGION:-us-east-1}"

ETL_SCRIPT="$REPO_ROOT/backend/etl/load_openai_embeddings_to_pgvector.py"
CSV_FILE="$REPO_ROOT/data/raw/fridge_sales_with_rating.csv"

load_data() {
    log_step "Loading data into Aurora database"
    
    # Navigate to infrastructure directory
    local infra_dir="$REPO_ROOT/infra/terraform/environments/$ENVIRONMENT/infrastructure"
    if [ ! -d "$infra_dir" ]; then
        log_error "Infrastructure directory not found: $infra_dir"
        exit 1
    fi
    
    # Fetch Aurora cluster info from Terragrunt outputs (for RDS Data API)
    log_info "Fetching Aurora cluster information from Terraform outputs..."
    
    local db_cluster_arn db_secret_arn db_name
    db_cluster_arn=$(cd "$infra_dir" && terragrunt output -raw db_cluster_arn 2>/dev/null || true)
    db_secret_arn=$(cd "$infra_dir" && terragrunt output -raw db_password_secret_arn 2>/dev/null || true)
    db_name=$(cd "$infra_dir" && terragrunt output -raw aurora_database_name 2>/dev/null || echo "fru_db")
    
    if [ -z "$db_cluster_arn" ] || [ -z "$db_secret_arn" ]; then
        log_error "Missing Aurora cluster ARN or secret ARN from infrastructure outputs"
        log_info "  db_cluster_arn: ${db_cluster_arn:-NOT SET}"
        log_info "  db_secret_arn: ${db_secret_arn:-NOT SET}"
        log_info ""
        log_info "Please ensure infrastructure is deployed first:"
        log_info "  ./run_scripts/aws/run.sh infrastructure $ENVIRONMENT"
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
    
    # Check if data is already loaded using RDS Data API
    log_info "Checking if data is already loaded..."
    
    local row_count=0
    # Use AWS CLI to check row count via RDS Data API
    row_count=$(aws rds-data execute-statement \
        --resource-arn "$db_cluster_arn" \
        --secret-arn "$db_secret_arn" \
        --database "$db_name" \
        --sql "SELECT COUNT(*) FROM fru_sales_embeddings;" \
        --profile "$AWS_PROFILE" \
        --region "$AWS_REGION" \
        --output text \
        --query 'records[0][0].longValue' 2>/dev/null || echo "0")
    
    if [ "$row_count" -gt 0 ] && [ "$row_count" != "0" ]; then
        log_info "Data already loaded ($row_count rows found)."
        # For automated testing, allow FORCE_RELOAD env var to skip prompt
        if [ "${FORCE_RELOAD:-false}" != "true" ]; then
            read -p "Do you want to reload data? This will upsert existing rows. (y/N): " -n 1 -r
            echo # Add a newline after the prompt
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                log_info "Skipping data reload."
                return 0
            fi
        else
            log_info "FORCE_RELOAD=true, proceeding with reload..."
        fi
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
    else
        log_error "ETL script failed"
        exit 1
    fi
}

main() {
    load_data
}

main "$@"

