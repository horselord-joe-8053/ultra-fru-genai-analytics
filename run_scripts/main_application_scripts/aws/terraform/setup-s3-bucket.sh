#!/bin/bash
# Setup S3 bucket for Terraform state
# Idempotent: safe to run multiple times
# Usage: ./setup-s3-bucket.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../../../.." && pwd)}"
source "$REPO_ROOT/orchestration/shared/logger.sh"
source "$REPO_ROOT/orchestration/shared/load-env.sh"

# Load environment variables
load_env_file

# Check for dry-run mode (from parent script)
DRY_RUN="${DRY_RUN:-false}"

# Get configuration
AWS_REGION="${AWS_REGION:-us-east-1}"
# Force admin profile for infrastructure operations (S3 bucket creation)
# Unset any credential env vars that might override the profile
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
export AWS_PROFILE=admin


# Check if bucket exists
bucket_exists() {
    local bucket=$1
    
    aws s3api head-bucket --bucket "$bucket" --profile admin >/dev/null 2>&1
}

# Create bucket (region-aware)
create_bucket() {
    local bucket=$1
    local region=$2
    
    log_info "Creating bucket: $bucket in region: $region"
    
    if [ "$region" = "us-east-1" ]; then
        # us-east-1 doesn't need LocationConstraint
        aws s3api create-bucket \
            --bucket "$bucket" \
            --region "$region" \
            --profile admin
    else
        # Other regions require LocationConstraint
        aws s3api create-bucket \
            --bucket "$bucket" \
            --region "$region" \
            --create-bucket-configuration LocationConstraint="$region" \
            --profile admin
    fi
}

# Configure bucket (versioning, encryption, public access block)
configure_bucket() {
    local bucket=$1
    
    log_info "Configuring bucket settings..."
    
    # Enable versioning
    log_info "  - Enabling versioning..."
    aws s3api put-bucket-versioning \
        --bucket "$bucket" \
        --versioning-configuration Status=Enabled \
        --profile admin >/dev/null 2>&1 || log_warning "Failed to enable versioning (may already be enabled)"
    
    # Enable encryption
    log_info "  - Enabling encryption..."
    aws s3api put-bucket-encryption \
        --bucket "$bucket" \
        --server-side-encryption-configuration '{
            "Rules": [{
                "ApplyServerSideEncryptionByDefault": {
                    "SSEAlgorithm": "AES256"
                }
            }]
        }' \
        --profile admin >/dev/null 2>&1 || log_warning "Failed to enable encryption (may already be enabled)"
    
    # Block public access
    log_info "  - Blocking public access..."
    aws s3api put-public-access-block \
        --bucket "$bucket" \
        --public-access-block-configuration \
            "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true" \
        --profile admin >/dev/null 2>&1 || log_warning "Failed to block public access (may already be configured)"
}

# Main function
main() {
    log_step "Setting up Terraform state bucket"
    
    # AWS credentials are already checked in Phase 0.4 of run.sh
    # Skip redundant check here
    
    # Check if TF_STATE_BUCKET is set
    if [ -z "$TF_STATE_BUCKET" ]; then
        log_error "TF_STATE_BUCKET is not set in .env file"
        log_info "Please set TF_STATE_BUCKET in your .env file"
        log_info "Example: TF_STATE_BUCKET=fru-terraform-state-999999999999"
        exit 1
    fi
    
    BUCKET_NAME="$TF_STATE_BUCKET"
    log_info "Bucket name: $BUCKET_NAME"
    log_info "Region: $AWS_REGION"
    [ -n "$AWS_PROFILE" ] && log_info "AWS Profile: $AWS_PROFILE"
    
    # Check if bucket exists
    local bucket_exists_flag=false
    if bucket_exists "$BUCKET_NAME"; then
        bucket_exists_flag=true
    fi
    
    if [ "$DRY_RUN" = "true" ]; then
        log_info "[DRY-RUN] Would perform the following operations:"
        if [ "$bucket_exists_flag" = false ]; then
            log_info "[DRY-RUN]   - Create S3 bucket: $BUCKET_NAME in region: $AWS_REGION"
        fi
        log_info "[DRY-RUN]   - Configure bucket settings:"
        log_info "[DRY-RUN]     - Enable versioning"
        log_info "[DRY-RUN]     - Enable encryption (AES256)"
        log_info "[DRY-RUN]     - Block public access"
        if [ "$bucket_exists_flag" = true ]; then
            log_info "[DRY-RUN] Bucket already exists: $BUCKET_NAME"
        else
            log_info "[DRY-RUN] Bucket does not exist (would be created)"
        fi
        return 0
    fi
    
    # Actual operations
    if [ "$bucket_exists_flag" = true ]; then
        log_info "Bucket already exists: $BUCKET_NAME"
        log_info "Updating bucket configuration..."
        configure_bucket "$BUCKET_NAME"
        log_success "Bucket configuration updated"
    else
        log_info "Bucket does not exist, creating..."
        create_bucket "$BUCKET_NAME" "$AWS_REGION"
        log_success "Bucket created"
        
        log_info "Configuring bucket..."
        configure_bucket "$BUCKET_NAME"
        log_success "Bucket configured"
    fi
    
    log_success "Terraform state bucket ready: $BUCKET_NAME"
    log_info "Bucket is configured with:"
    log_info "  - Versioning: Enabled"
    log_info "  - Encryption: AES256"
    log_info "  - Public Access: Blocked"
}

main "$@"

