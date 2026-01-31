#!/bin/bash
# Setup AWS profiles from .env file
# Syncs AWS_ADMIN_* and AWS_BEDROCK_* credentials to ~/.aws/credentials
# Idempotent: updates existing profiles, creates if missing

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../../../" && pwd)}"
source "$REPO_ROOT/orchestration/shared/logger.sh"
source "$REPO_ROOT/orchestration/shared/load-env.sh"
# Now REPO_ROOT and ENV_FILE are available from load-env.sh

setup_aws_profiles() {
    log_step "Setting up AWS profiles from .env"
    
    # Load environment variables (but don't export credential variables)
    load_env_file
    
    # Check if required variables are set
    local missing_vars=0
    
    if [ -z "${AWS_ADMIN_ACCESS_KEY_ID:-}" ]; then
        log_error "AWS_ADMIN_ACCESS_KEY_ID not set in .env"
        missing_vars=1
    fi
    
    if [ -z "${AWS_ADMIN_SECRET_ACCESS_KEY:-}" ]; then
        log_error "AWS_ADMIN_SECRET_ACCESS_KEY not set in .env"
        missing_vars=1
    fi
    
    if [ -z "${AWS_BEDROCK_ACCESS_KEY_ID:-}" ]; then
        log_error "AWS_BEDROCK_ACCESS_KEY_ID not set in .env"
        missing_vars=1
    fi
    
    if [ -z "${AWS_BEDROCK_SECRET_ACCESS_KEY:-}" ]; then
        log_error "AWS_BEDROCK_SECRET_ACCESS_KEY not set in .env"
        missing_vars=1
    fi
    
    if [ $missing_vars -eq 1 ]; then
        log_error "Missing required AWS credential variables in .env"
        log_info "Required variables:"
        log_info "  - AWS_ADMIN_ACCESS_KEY_ID"
        log_info "  - AWS_ADMIN_SECRET_ACCESS_KEY"
        log_info "  - AWS_BEDROCK_ACCESS_KEY_ID"
        log_info "  - AWS_BEDROCK_SECRET_ACCESS_KEY"
        exit 1
    fi
    
    # Get region (default to us-east-1)
    AWS_REGION="${AWS_REGION:-us-east-1}"
    
    # Ensure ~/.aws directory exists
    mkdir -p ~/.aws
    chmod 700 ~/.aws
    
    # Backup existing credentials file if it exists
    if [ -f ~/.aws/credentials ]; then
        cp ~/.aws/credentials ~/.aws/credentials.backup.$(date +%Y%m%d_%H%M%S)
        log_info "Backed up existing ~/.aws/credentials"
    fi
    
    # Setup admin profile
    log_info "Setting up [admin] profile..."
    aws configure set aws_access_key_id "$AWS_ADMIN_ACCESS_KEY_ID" --profile admin
    aws configure set aws_secret_access_key "$AWS_ADMIN_SECRET_ACCESS_KEY" --profile admin
    aws configure set region "$AWS_REGION" --profile admin
    log_success "[admin] profile configured"
    
    # Setup bedrock profile
    log_info "Setting up [bedrock] profile..."
    aws configure set aws_access_key_id "$AWS_BEDROCK_ACCESS_KEY_ID" --profile bedrock
    aws configure set aws_secret_access_key "$AWS_BEDROCK_SECRET_ACCESS_KEY" --profile bedrock
    aws configure set region "$AWS_REGION" --profile bedrock
    log_success "[bedrock] profile configured"
    
    # Set proper permissions on credentials file
    chmod 600 ~/.aws/credentials
    
    log_success "AWS profiles setup complete"
    log_info "Profiles available:"
    log_info "  - admin (for infrastructure operations: ECR, Terraform, S3, etc.)"
    log_info "  - bedrock (for application runtime: Bedrock API calls)"
    
    return 0
}

main() {
    setup_aws_profiles
}

main "$@"

