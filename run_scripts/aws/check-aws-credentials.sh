#!/bin/bash
# Check AWS credentials and configuration
# Verifies all AWS-related environment variables and credentials
# Idempotent: just checks, doesn't modify

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/../common/logger.sh"
source "$SCRIPT_DIR/../common/load-env.sh"

# Load .env file if it exists
load_env_file 2>/dev/null || true

check_aws_cli() {
    log_info "Checking AWS CLI installation..."
    if ! command_exists aws; then
        log_error "AWS CLI is not installed"
        log_info "Install with: brew install awscli"
        return 1
    fi
    log_success "AWS CLI is installed"
    return 0
}

check_aws_credentials_from_env() {
    log_info "Checking AWS credentials from .env file..."
    
    local missing_vars=0
    
    # Check AWS_ACCESS_KEY_ID
    if [ -z "$AWS_ACCESS_KEY_ID" ]; then
        log_warning "AWS_ACCESS_KEY_ID not set in .env (optional for AWS deployment, required for local)"
    else
        log_success "AWS_ACCESS_KEY_ID is set"
    fi
    
    # Check AWS_SECRET_ACCESS_KEY
    if [ -z "$AWS_SECRET_ACCESS_KEY" ]; then
        log_warning "AWS_SECRET_ACCESS_KEY not set in .env (optional for AWS deployment, required for local)"
    else
        log_success "AWS_SECRET_ACCESS_KEY is set"
    fi
    
    # Check AWS_REGION
    if [ -z "$AWS_REGION" ]; then
        log_warning "AWS_REGION not set in .env (will default to us-east-1)"
        AWS_REGION="us-east-1"
    else
        log_success "AWS_REGION is set: $AWS_REGION"
    fi
    
    # Check BEDROCK_MODEL_ID
    if [ -z "$BEDROCK_MODEL_ID" ]; then
        log_warning "BEDROCK_MODEL_ID not set in .env"
        log_info "  Default will be used: anthropic.claude-3-haiku-20240307-v1:0"
    else
        log_success "BEDROCK_MODEL_ID is set: $BEDROCK_MODEL_ID"
    fi
    
    # Check AWS_PROFILE
    if [ -z "$AWS_PROFILE" ]; then
        log_info "AWS_PROFILE not set in .env (will use default AWS credentials)"
    else
        log_success "AWS_PROFILE is set: $AWS_PROFILE"
        # Verify profile exists
        if ! aws configure list-profiles 2>/dev/null | grep -q "^$AWS_PROFILE$"; then
            log_warning "AWS profile '$AWS_PROFILE' not found in ~/.aws/credentials"
            log_info "  Run: aws configure --profile $AWS_PROFILE"
        else
            log_success "AWS profile '$AWS_PROFILE' exists"
        fi
    fi
    
    return 0
}

check_aws_authentication() {
    log_info "Checking AWS authentication..."
    
    local profile_flag=""
    if [ -n "$AWS_PROFILE" ]; then
        profile_flag="--profile $AWS_PROFILE"
    fi
    
    # Try to get caller identity
    if ! aws sts get-caller-identity $profile_flag >/dev/null 2>&1; then
        log_error "AWS credentials are not configured or invalid"
        log_info "Configure credentials using one of:"
        if [ -n "$AWS_PROFILE" ]; then
            log_info "  1. Run: aws configure --profile $AWS_PROFILE"
        else
            log_info "  1. Add to .env file: AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY"
            log_info "  2. Run: aws configure"
        fi
        log_info "  3. Use IAM role (if running on AWS infrastructure)"
        return 1
    fi
    
    # Get AWS account info
    AWS_ACCOUNT_ID=$(aws sts get-caller-identity $profile_flag --query Account --output text)
    local aws_region_from_cli=$(aws configure get region $profile_flag 2>/dev/null || echo "")
    AWS_REGION="${AWS_REGION:-${aws_region_from_cli:-us-east-1}}"
    
    log_success "AWS credentials are valid"
    log_info "  Account ID: $AWS_ACCOUNT_ID"
    log_info "  Region: $AWS_REGION"
    if [ -n "$AWS_PROFILE" ]; then
        log_info "  Profile: $AWS_PROFILE"
    fi
    
    return 0
}

check_bedrock_access() {
    log_info "Checking Bedrock access..."
    
    local profile_flag=""
    if [ -n "$AWS_PROFILE" ]; then
        profile_flag="--profile $AWS_PROFILE"
    fi
    
    local region="${AWS_REGION:-us-east-1}"
    local model_id="${BEDROCK_MODEL_ID:-anthropic.claude-3-haiku-20240307-v1:0}"
    
    # Extract foundation model name (before the colon)
    local foundation_model=$(echo "$model_id" | cut -d: -f1)
    
    # Check if foundation model is available
    if aws bedrock list-foundation-models $profile_flag --region "$region" \
        --query "modelSummaries[?modelId=='$foundation_model']" \
        --output text 2>/dev/null | grep -q "$foundation_model"; then
        log_success "Bedrock foundation model is available: $foundation_model"
    else
        log_warning "Bedrock foundation model may not be available: $foundation_model"
        log_info "  Region: $region"
        log_info "  Check: https://console.aws.amazon.com/bedrock/"
    fi
    
    # Try to check model access (may fail if model access not granted)
    if aws bedrock get-foundation-model $profile_flag --region "$region" \
        --model-identifier "$foundation_model" >/dev/null 2>&1; then
        log_success "Bedrock model access verified: $model_id"
    else
        log_warning "Cannot verify Bedrock model access (may need to request access)"
        log_info "  Model: $model_id"
        log_info "  Request access: https://console.aws.amazon.com/bedrock/"
    fi
    
    return 0
}

check_all_aws_credentials() {
    log_step "Checking AWS credentials and configuration"
    
    local errors=0
    
    # Step 1: Check AWS CLI
    if ! check_aws_cli; then
        errors=$((errors + 1))
    fi
    
    echo ""
    
    # Step 2: Check environment variables from .env
    check_aws_credentials_from_env
    
    echo ""
    
    # Step 3: Check AWS authentication
    if ! check_aws_authentication; then
        errors=$((errors + 1))
    fi
    
    echo ""
    
    # Step 4: Check Bedrock access (non-blocking)
    check_bedrock_access
    
    echo ""
    
    if [ $errors -gt 0 ]; then
        log_error "AWS credentials check failed with $errors error(s)"
        return 1
    fi
    
    log_success "All AWS credentials checks passed"
    return 0
}

main() {
    check_all_aws_credentials
}

main "$@"

