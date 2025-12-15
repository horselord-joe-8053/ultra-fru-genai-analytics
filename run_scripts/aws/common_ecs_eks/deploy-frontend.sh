#!/bin/bash
# Deploy frontend to S3 and CloudFront
# Idempotent: only uploads changed files

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
source "$SCRIPT_DIR/../../common/logger.sh"
# Save SCRIPT_DIR before sourcing load-env.sh (which sets its own SCRIPT_DIR)
FRONTEND_SCRIPT_DIR="$SCRIPT_DIR"
source "$SCRIPT_DIR/../../common/load-env.sh"
# Restore our SCRIPT_DIR
SCRIPT_DIR="$FRONTEND_SCRIPT_DIR"

S3_BUCKET_NAME="${S3_BUCKET_NAME:-fru-frontend-bucket}"
AWS_REGION="${AWS_REGION:-us-east-1}"

# Check for dry-run mode (from parent script)
DRY_RUN="${DRY_RUN:-false}"

deploy_frontend() {
    log_step "Deploying frontend to S3"
    
    # Check AWS credentials
    "$SCRIPT_DIR/../check-aws-credentials.sh" || exit 1
    
    # Load environment variables
    load_env_file
    
    # Use admin profile for infrastructure operations (S3)
    AWS_PROFILE="${AWS_PROFILE:-admin}"
    log_info "Using AWS profile: $AWS_PROFILE (for infrastructure operations)"
    
    # Check if frontend is built
    if [ ! -d "$REPO_ROOT/frontend/dist" ]; then
        log_error "Frontend not built. Please run build first."
        log_info "Run: cd $REPO_ROOT/frontend && npm run build"
        exit 1
    fi
    
    # Check if S3 bucket exists
    local bucket_exists=false
    if aws s3 ls --profile "$AWS_PROFILE" "s3://$S3_BUCKET_NAME" >/dev/null 2>&1; then
        bucket_exists=true
        log_info "S3 bucket already exists"
    else
        log_info "S3 bucket does not exist"
    fi
    
    if [ "$DRY_RUN" = "true" ]; then
        log_info "[DRY-RUN] Would perform the following operations:"
        if [ "$bucket_exists" = false ]; then
            log_info "[DRY-RUN]   - Create S3 bucket: $S3_BUCKET_NAME"
            log_info "[DRY-RUN]   - Configure static website hosting"
        fi
        log_info "[DRY-RUN]   - Sync frontend files to S3 (showing what would be synced)..."
        aws s3 sync --dryrun --profile "$AWS_PROFILE" "$REPO_ROOT/frontend/dist" "s3://$S3_BUCKET_NAME" --delete
        log_info "[DRY-RUN] Bucket: $S3_BUCKET_NAME"
        log_info "[DRY-RUN] Website URL: http://$S3_BUCKET_NAME.s3-website-$AWS_REGION.amazonaws.com"
        return 0
    fi
    
    # Create S3 bucket if it doesn't exist
    if [ "$bucket_exists" = false ]; then
        log_info "S3 bucket does not exist, creating..."
        if [ "$AWS_REGION" = "us-east-1" ]; then
            aws s3 mb --profile "$AWS_PROFILE" "s3://$S3_BUCKET_NAME" --region "$AWS_REGION"
        else
            aws s3 mb --profile "$AWS_PROFILE" "s3://$S3_BUCKET_NAME" --region "$AWS_REGION"
        fi
        log_success "S3 bucket created"
        
        # Configure static website hosting
        log_info "Configuring static website hosting..."
        aws s3 website --profile "$AWS_PROFILE" "s3://$S3_BUCKET_NAME" \
            --index-document index.html \
            --error-document index.html
    fi
    
    # Sync files to S3
    log_info "Syncing frontend files to S3..."
    aws s3 sync --profile "$AWS_PROFILE" "$REPO_ROOT/frontend/dist" "s3://$S3_BUCKET_NAME" --delete
    
    log_success "Frontend deployed to S3"
    log_info "  Bucket: $S3_BUCKET_NAME"
    log_info "  Website URL: http://$S3_BUCKET_NAME.s3-website-$AWS_REGION.amazonaws.com"
    log_info ""
    log_warning "Note: CloudFront distribution setup is not automated yet"
    log_info "  Create CloudFront distribution manually or use Terraform"
}

main() {
    deploy_frontend
}

main "$@"

