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

# Helper function to check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

AWS_REGION="${AWS_REGION:-us-east-1}"
ENVIRONMENT="${ENVIRONMENT:-dev}"

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
    
    # Get S3 bucket name from Terraform outputs
    TERRAFORM_DIR="$REPO_ROOT/infra/terraform/environments/$ENVIRONMENT"
    APP_DIR="$TERRAFORM_DIR/application"
    
    local s3_bucket_name=""
    if [ -d "$APP_DIR" ] && command_exists terragrunt; then
        ORIG_DIR=$(pwd)
        cd "$APP_DIR" 2>/dev/null || {
            log_warning "Could not access Terraform application directory, using default bucket name"
            s3_bucket_name="${S3_BUCKET_NAME:-fru-frontend-bucket}"
        }
        if [ -z "$s3_bucket_name" ]; then
            s3_bucket_name=$(terragrunt output -raw s3_bucket_id 2>/dev/null || echo "")
        fi
        cd "$ORIG_DIR" 2>/dev/null || true
    fi
    
    # Fallback to default if Terraform output not available
    if [ -z "$s3_bucket_name" ]; then
        s3_bucket_name="${S3_BUCKET_NAME:-fru-frontend-bucket}"
        log_warning "Could not get S3 bucket name from Terraform, using default: $s3_bucket_name"
        log_info "To use the correct bucket, ensure Terraform application layer is deployed first"
    else
        log_info "Using S3 bucket from Terraform: $s3_bucket_name"
    fi
    
    S3_BUCKET_NAME="$s3_bucket_name"
    
    # Check if frontend is built, build if needed
    if [ ! -d "$REPO_ROOT/frontend/dist" ]; then
        log_info "Frontend not built, building now..."
        cd "$REPO_ROOT/frontend"
        
        # Check if node_modules exists, install if needed
        if [ ! -d "node_modules" ]; then
            log_info "Installing frontend dependencies..."
            if [ "$DRY_RUN" = "true" ]; then
                log_info "[DRY-RUN] Would run: npm install"
            else
                npm install || {
                    log_error "Failed to install frontend dependencies"
                    exit 1
                }
            fi
        fi
        
        # Build frontend
        if [ "$DRY_RUN" = "true" ]; then
            log_info "[DRY-RUN] Would run: npm run build"
        else
            npm run build || {
                log_error "Failed to build frontend"
                exit 1
            }
            log_success "Frontend built successfully"
        fi
        cd "$REPO_ROOT"
    else
        log_info "Frontend already built"
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
    log_info "Note: CloudFront distribution is managed by Terraform"
    log_info "  CloudFront will automatically serve content from this S3 bucket"
}

main() {
    deploy_frontend
}

main "$@"

