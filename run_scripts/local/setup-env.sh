#!/bin/bash
# Setup .env file from template if it doesn't exist
# Idempotent: won't overwrite existing .env file

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/logger.sh"
source "$SCRIPT_DIR/../common/load-env.sh"
# Now REPO_ROOT, ENV_FILE, and ENV_TEMPLATE are available from load-env.sh

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
# Database Configuration (REQUIRED)
PGHOST=localhost
PGPORT=5432
PGUSER=postgres
PGPASSWORD=postgres
PGDATABASE=fru_db

# OpenAI Configuration (REQUIRED)
OPENAI_API_KEY=sk-...
OPENAI_EMBED_MODEL=text-embedding-3-small

# AWS Configuration (REQUIRED)
AWS_REGION=us-east-1

# AWS Bedrock Configuration
# Primary: Inference Profile ID (for Claude 3.5 and newer models)
AWS_BEDROCK_INFERENCE_PROFILE_ID=us.anthropic.claude-3-5-haiku-20241022-v1:0

# Fallback: Model ID (for ON_DEMAND models like Claude 3)
# Only used if AWS_BEDROCK_INFERENCE_PROFILE_ID is not set
AWS_BEDROCK_MODEL_ID=anthropic.claude-3-haiku-20240307-v1:0

# Application Configuration (REQUIRED)
LOG_LEVEL=INFO
ALLOWED_ORIGINS=*

# AWS Credentials for Profiles (required for AWS operations)
# These are used to populate ~/.aws/credentials profiles
# Run: ./run_scripts/aws/setup-aws-profiles.sh after setting these
# AWS_ADMIN_ACCESS_KEY_ID=your-admin-access-key
# AWS_ADMIN_SECRET_ACCESS_KEY=your-admin-secret-key
# AWS_BEDROCK_ACCESS_KEY_ID=your-bedrock-access-key
# AWS_BEDROCK_SECRET_ACCESS_KEY=your-bedrock-secret-key

# AWS Profile Selection
# AWS_PROFILE=admin  # For infrastructure scripts (default: admin)
# For application runtime in Docker, set AWS_PROFILE=admin in docker-compose.yml

# Optional: Feature Flags
# USE_AGENT_QUERY=false  # Enable agent-based query processing
# USE_AGENT_QUERY_PERCENTAGE=0  # Percentage of queries to use agent (0-100)
# USE_AGENT_QUERY_WHITELIST=  # Comma-separated list of user IDs to always use agent

# Optional: Data Paths
# FRU_CSV_PATH=data/raw/fridge_sales_with_rating.csv
# REPO_ROOT=  # Repository root path (defaults to auto-detection if not set)

# Optional: Analytics Scheduler (requires Spark + Delta table)
# ENABLE_ANALYTICS_SCHEDULER=true
# ANALYTICS_SCHEDULER_INTERVAL_MINUTES=5
# SPARK_HOME=/path/to/spark  # Optional, if spark-submit not in PATH
# DELTA_TABLE_PATH=data/delta/fru_sales

# =============================================================================
# Spark + Delta Lake Configuration (REQUIRED)
# =============================================================================
# Standard combination: Spark 4.0.1 + Delta Lake 4.0.0 + Scala 2.13.x
# This combination has been tested and verified to work correctly.
# The Delta Lake package format is: io.delta:delta-spark_{SCALA_VERSION}:{DELTA_VERSION}
#
# IMPORTANT: This must be set in your .env file. No hardcoded defaults are used.
# If not set, scripts will error with a helpful message.
#
# Delta Lake package (Maven coordinates) - REQUIRED
# Format: io.delta:delta-spark_{SCALA_VERSION}:{DELTA_VERSION}
# Standard: io.delta:delta-spark_2.13:4.0.0 (compatible with Spark 4.0.1)
DELTA_LAKE_PACKAGE=io.delta:delta-spark_2.13:4.0.0

# Spark version - used by Dockerfile.api during build (passed as build arg)
# Expected version: 4.0.1
# This is passed to Docker builds via docker-compose.yml (local) or build-push-ecr.sh (AWS)
SPARK_VERSION=4.0.1

# Hadoop version - used by Dockerfile.api during build (passed as build arg)
# Expected version: 3 (Hadoop 3 is standard for Spark 4.x)
# This is passed to Docker builds via docker-compose.yml (local) or build-push-ecr.sh (AWS)
HADOOP_VERSION=3

# Delta Lake version (for reference/documentation only, not directly used by scripts)
# Expected version: 4.0.0
# This documents the intended Delta Lake version (matches DELTA_LAKE_PACKAGE).
DELTA_LAKE_VERSION=4.0.0

# Scala version (for reference/documentation only, not directly used by scripts)
# Expected version: 2.13.x
# This documents the intended Scala version (matches DELTA_LAKE_PACKAGE).
SCALA_VERSION=2.13
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

