#!/bin/bash
# Check AWS credentials and configuration
# Idempotent: just checks, doesn't modify

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common/logger.sh"

check_aws_credentials() {
    log_step "Checking AWS credentials and configuration"
    
    # Check if AWS CLI is installed
    if ! command_exists aws; then
        log_error "AWS CLI is not installed"
        log_info "Install with: brew install awscli"
        exit 1
    fi
    
    # Check if credentials are configured
    log_info "Checking AWS credentials..."
    if ! aws sts get-caller-identity >/dev/null 2>&1; then
        log_error "AWS credentials are not configured or invalid"
        log_info "Configure credentials using one of:"
        log_info "  1. Add to .env file: AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY"
        log_info "  2. Run: aws configure"
        log_info "  3. Use IAM role (if running on AWS infrastructure)"
        exit 1
    fi
    
    # Get AWS account info
    AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
    AWS_REGION=$(aws configure get region || echo "us-east-1")
    
    log_success "AWS credentials are valid"
    log_info "  Account ID: $AWS_ACCOUNT_ID"
    log_info "  Region: $AWS_REGION"
    
    return 0
}

main() {
    check_aws_credentials
}

main "$@"

