#!/bin/bash
# Setup .env file from template if it doesn't exist
# Idempotent: won't overwrite existing .env file

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/../common/logger.sh"

ENV_FILE="$REPO_ROOT/.env"
ENV_TEMPLATE="$REPO_ROOT/.env.example"

setup_env_file() {
    log_step "Setting up .env file"
    
    # Check if .env already exists
    if [ -f "$ENV_FILE" ]; then
        log_info ".env file already exists at $ENV_FILE"
        log_info "Skipping .env creation. Edit it manually if needed."
        return 0
    fi
    
    # Create .env from template if it exists, otherwise create from scratch
    if [ -f "$ENV_TEMPLATE" ]; then
        log_info "Creating .env from template..."
        cp "$ENV_TEMPLATE" "$ENV_FILE"
        log_success "Created .env from template"
    else
        log_info "Creating .env from scratch..."
        cat > "$ENV_FILE" << 'EOF'
# Database Configuration
PGHOST=localhost
PGPORT=5432
PGUSER=postgres
PGPASSWORD=postgres
PGDATABASE=fru_db

# OpenAI Configuration
OPENAI_API_KEY=sk-...

# AWS Configuration
AWS_REGION=us-east-1
BEDROCK_MODEL_ID=anthropic.claude-3-haiku-20240229-v1:0

# Optional: AWS Credentials (for local development only)
# If not set, boto3 will use ~/.aws/credentials or IAM role
# AWS_ACCESS_KEY_ID=your-access-key
# AWS_SECRET_ACCESS_KEY=your-secret-key
# AWS_SESSION_TOKEN=...  # If using temporary credentials

# Optional: Data Paths
# FRU_CSV_PATH=data/raw/fridge_sales_with_rating.csv

# Optional: Analytics Scheduler (requires Spark + Delta table)
# ENABLE_ANALYTICS_SCHEDULER=true
# ANALYTICS_SCHEDULER_INTERVAL_MINUTES=5
# SPARK_HOME=/path/to/spark  # Optional, if spark-submit not in PATH
# DELTA_TABLE_PATH=data/delta/fru_sales
EOF
        log_success "Created .env file"
    fi
    
    log_warning "Please edit $ENV_FILE and fill in:"
    log_warning "  - OPENAI_API_KEY (required)"
    log_warning "  - AWS credentials (optional, can use ~/.aws/credentials instead)"
    log_warning "  - Other optional settings as needed"
    
    return 0
}

main() {
    setup_env_file
}

main "$@"

