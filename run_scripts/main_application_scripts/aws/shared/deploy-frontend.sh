#!/bin/bash
# Deploy frontend to S3 and CloudFront
# Idempotent: only uploads changed files

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../../../.." && pwd)}"
source "$REPO_ROOT/run_scripts/shared/logger.sh"
# Save SCRIPT_DIR before sourcing load-env.sh (which sets its own SCRIPT_DIR)
FRONTEND_SCRIPT_DIR="$SCRIPT_DIR"
source "$REPO_ROOT/run_scripts/shared/load-env.sh"
# Restore our SCRIPT_DIR
SCRIPT_DIR="$FRONTEND_SCRIPT_DIR"

# Helper function to check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Extract frontend version from built files
# Phase 2: Frontend Version Verification
# Stores version in .frontend-version.txt for later verification
extract_frontend_version() {
    local dist_dir="${1:-$REPO_ROOT/frontend/dist}"
    local version_file="${2:-$REPO_ROOT/.frontend-version.txt}"
    
    if [ ! -d "$dist_dir" ]; then
        log_warning "Frontend dist directory not found: $dist_dir"
        return 1
    fi
    
    log_info "Extracting frontend version from built files..."
    
    # Try to extract version from built JS files
    # Look for version pattern: V_YYMMDD-HHMMSS_...
    local version_pattern="V_[0-9]\{6\}-[0-9]\{6\}_[^\"'[:space:]]*"
    local extracted_version=""
    
    # Search in built JS files (most likely location)
    if [ -d "$dist_dir/assets" ]; then
        extracted_version=$(find "$dist_dir/assets" -name "*.js" -type f -exec grep -oh "$version_pattern" {} \; 2>/dev/null | head -1)
    fi
    
    # If not found in JS, try HTML
    if [ -z "$extracted_version" ] && [ -f "$dist_dir/index.html" ]; then
        extracted_version=$(grep -oh "$version_pattern" "$dist_dir/index.html" 2>/dev/null | head -1)
    fi
    
    # If still not found, try all files in dist
    if [ -z "$extracted_version" ]; then
        extracted_version=$(grep -roh "$version_pattern" "$dist_dir" 2>/dev/null | head -1)
    fi
    
    if [ -n "$extracted_version" ]; then
        echo "$extracted_version" > "$version_file"
        log_success "Frontend version extracted: $extracted_version"
        log_info "Version saved to: $version_file"
        export FRONTEND_VERSION="$extracted_version"
        return 0
    else
        log_warning "Could not extract frontend version from build"
        log_info "Searched in: $dist_dir"
        log_info "Version pattern: $version_pattern"
        # Don't fail - version extraction is optional for now
        return 1
    fi
}

AWS_REGION="${AWS_REGION:-us-east-1}"
ENVIRONMENT="${ENVIRONMENT:-dev}"

# Check for dry-run mode (from parent script)
DRY_RUN="${DRY_RUN:-false}"

deploy_frontend() {
    log_step "Deploying frontend to S3"
    
    # AWS credentials are already checked in Phase 0.4 of run.sh
    # Skip redundant check here
    
    # Load environment variables
    load_env_file
    
    # Use admin profile for infrastructure operations (S3)
    AWS_PROFILE="${AWS_PROFILE:-admin}"
    log_info "Using AWS profile: $AWS_PROFILE (for infrastructure operations)"
    
    # Get S3 bucket name from Terraform outputs
    # Use eks for EKS, ecs for ECS
    TERRAFORM_DIR="$REPO_ROOT/infra/terraform/providers/aws/environments/$ENVIRONMENT"
    CONTAINER_TYPE="${CONTAINER_TYPE:-ecs}"
    if [ "$CONTAINER_TYPE" = "eks" ]; then
        APP_DIR="$TERRAFORM_DIR/eks"
    else
        APP_DIR="$TERRAFORM_DIR/ecs"
    fi
    
    local s3_bucket_name=""
    if [ -d "$APP_DIR" ] && command_exists terragrunt; then
        ORIG_DIR=$(pwd)
        cd "$APP_DIR" 2>/dev/null || {
            log_error "Could not access Terraform application directory: $APP_DIR"
            log_error "Terraform application layer must be deployed first"
            log_info "Deploy infrastructure with: ./run_scripts/main_application_scripts/aws/run.sh infrastructure $ENVIRONMENT"
            exit 1
        }
        s3_bucket_name=$(terragrunt output -raw s3_bucket_id 2>/dev/null || echo "")
        cd "$ORIG_DIR" 2>/dev/null || true
    else
        if [ ! -d "$APP_DIR" ]; then
            log_error "Terraform application directory not found: $APP_DIR"
        fi
        if ! command_exists terragrunt; then
            log_error "Terragrunt is not installed or not in PATH"
        fi
        log_error "Cannot get S3 bucket name from Terraform"
        log_info "Terraform application layer must be deployed first"
        log_info "Deploy infrastructure with: ./run_scripts/main_application_scripts/aws/run.sh infrastructure $ENVIRONMENT"
        exit 1
    fi
    
    # Require Terraform output - fail if not available
    if [ -z "$s3_bucket_name" ]; then
        log_error "Failed to get S3 bucket name from Terraform output"
        log_error "Terraform application layer may not be deployed, or s3_bucket_id output is missing"
        log_info "Deploy infrastructure with: ./run_scripts/main_application_scripts/aws/run.sh infrastructure $ENVIRONMENT"
        log_info "Then deploy application with: ./run_scripts/main_application_scripts/aws/run.sh application $ENVIRONMENT"
        exit 1
    fi
    
    log_info "Using S3 bucket from Terraform: $s3_bucket_name"
    
    S3_BUCKET_NAME="$s3_bucket_name"
    
    # Check if frontend needs to be built
    # Frontend uses relative URLs - CloudFront will proxy /query and /analytics to ALB
    local needs_build=false
    
    if [ ! -d "$REPO_ROOT/frontend/dist" ]; then
        log_info "Frontend dist directory not found, will build"
        needs_build=true
    else
        # Check if any source files are newer than the dist build
        # This ensures we rebuild when source code changes
        # Use cross-platform stat command (macOS: -f, Linux: -c)
        local dist_file
        dist_file=$(find "$REPO_ROOT/frontend/dist" -type f \( -name "*.html" -o -name "*.js" -o -name "*.css" \) 2>/dev/null | head -1)
        local dist_mtime="0"
        if [ -n "$dist_file" ]; then
            dist_mtime=$(stat -f "%m" "$dist_file" 2>/dev/null || stat -c "%Y" "$dist_file" 2>/dev/null || echo "0")
        fi
        
        local src_mtime="0"
        local src_files
        src_files=$(find "$REPO_ROOT/frontend/src" -type f \( -name "*.tsx" -o -name "*.ts" -o -name "*.jsx" -o -name "*.js" -o -name "*.css" \) 2>/dev/null)
        if [ -n "$src_files" ]; then
            # Get the most recent source file modification time
            local src_file
            for src_file in $src_files; do
                local file_mtime
                file_mtime=$(stat -f "%m" "$src_file" 2>/dev/null || stat -c "%Y" "$src_file" 2>/dev/null || echo "0")
                if [ "$file_mtime" -gt "$src_mtime" ]; then
                    src_mtime="$file_mtime"
                fi
            done
        fi
        
        if [ "$src_mtime" -gt "$dist_mtime" ]; then
            log_info "Source files are newer than dist build, will rebuild"
            needs_build=true
        else
            log_info "Frontend already built and up-to-date"
        fi
        
        # In preempt/force-rebuild mode, always rebuild the frontend even if timestamps look up-to-date.
        # This ensures a truly clean slate when using --preempt or when FORCE_REBUILD is set by callers.
        if [ "${PREEMPT:-false}" = "true" ] || [ "${FORCE_REBUILD:-false}" = "true" ]; then
            log_info "PREEMPT/FORCE_REBUILD mode: Forcing frontend rebuild"
            needs_build=true
        fi
    fi
    
    if [ "$needs_build" = "true" ]; then
        log_info "Building frontend..."
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
        
        # Build frontend (uses relative URLs - CloudFront proxies API requests to ALB)
        # BUILD_TIME is injected automatically by vite.config.ts using Date.now()
        # VITE_PROVIDER, VITE_CONTAINER_TYPE, VITE_ENVIRONMENT are passed to Vite for version label
        # This ensures the version (V_YYMMDD-HHMMSS_PROVIDER_CONTAINER_ENV) reflects build context
        if [ "$DRY_RUN" = "true" ]; then
            log_info "[DRY-RUN] Would run: npm run build"
            log_info "[DRY-RUN] Frontend will use relative URLs (/query, /analytics)"
            log_info "[DRY-RUN] CloudFront will proxy these requests to ALB"
        else
            # Export build context variables for Vite (will be injected via vite.config.ts define)
            export VITE_PROVIDER="${VITE_PROVIDER:-aws}"
            export VITE_CONTAINER_TYPE="${CONTAINER_TYPE:-ecs}"
            export VITE_ENVIRONMENT="${ENVIRONMENT:-dev}"
            log_info "Building frontend with context: provider=$VITE_PROVIDER, container=$VITE_CONTAINER_TYPE, env=$VITE_ENVIRONMENT"
            npm run build || {
                log_error "Failed to build frontend"
                exit 1
            }
            log_success "Frontend built successfully"
            log_info "Frontend uses relative URLs - CloudFront will proxy /query and /analytics to ALB"
            
            # Phase 2: Extract and track frontend version after build
            extract_frontend_version "$REPO_ROOT/frontend/dist" "$REPO_ROOT/.frontend-version.txt" || true
        fi
        cd "$REPO_ROOT"
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
    
    # Phase 2: Log frontend version after deployment
    if [ -f "$REPO_ROOT/.frontend-version.txt" ]; then
        local deployed_version
        deployed_version=$(cat "$REPO_ROOT/.frontend-version.txt" 2>/dev/null || echo "")
        if [ -n "$deployed_version" ]; then
            log_info "  Frontend version deployed: $deployed_version"
            export FRONTEND_VERSION="$deployed_version"
        fi
    fi
    
    # ============================================================================
    # CloudFront Invalidation
    # ============================================================================
    # Get CloudFront distribution ID from Terraform outputs
    local cloudfront_dist_id=""
    local cloudfront_domain=""
    
    if [ -d "$APP_DIR" ] && command_exists terragrunt; then
        ORIG_DIR=$(pwd)
        cd "$APP_DIR" 2>/dev/null || {
            log_warning "Could not access Terraform application directory for CloudFront outputs"
            log_info "Skipping CloudFront invalidation - manual invalidation may be required"
            cd "$ORIG_DIR" 2>/dev/null || true
        }
        
        if [ -d "$APP_DIR" ]; then
            # Try to get distribution ID
            if cloudfront_dist_id=$(terragrunt output -raw cloudfront_distribution_id 2>/dev/null); then
                if [ -n "$cloudfront_dist_id" ] && [ "$cloudfront_dist_id" != "null" ]; then
                    log_info "Found CloudFront distribution ID: $cloudfront_dist_id"
                    
                    # Source invalidation helper
                    local helper_script="$SCRIPT_DIR/helpers/cloudfront-invalidation.sh"
                    if [ -f "$helper_script" ]; then
                        source "$helper_script"
                        
                        # Create invalidation for all paths
                        # Note: create_cloudfront_invalidation() sets CLOUDFRONT_INVALIDATION_ID environment variable
                        # Using "/*" invalidates all paths including:
                        # - Frontend: / (index.html and all static assets)
                        # - API endpoints: /query, /analytics, /version, /health, /query/stream
                        # This ensures both frontend updates and API endpoint cache (including /analytics) are cleared
                        # The "/*" pattern is more efficient than invalidating individual paths
                        if create_cloudfront_invalidation "$cloudfront_dist_id" "/*"; then
                            # Phase 4: Store invalidation ID for tracking
                            local invalidation_log="$REPO_ROOT/.cloudfront-invalidations.log"
                            local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
                            echo "$timestamp|$cloudfront_dist_id|$CLOUDFRONT_INVALIDATION_ID|/*" >> "$invalidation_log"
                            log_info "Invalidation ID logged to: $invalidation_log"
                            
                            # Wait for invalidation to complete (non-blocking mode)
                            # If invalidation fails or times out, deployment will continue
                            # The invalidation will complete in the background
                            log_info "Waiting for CloudFront invalidation to complete (non-blocking)..."
                            if wait_for_invalidation "$cloudfront_dist_id" "$CLOUDFRONT_INVALIDATION_ID" 15 "true"; then
                                log_success "CloudFront invalidation completed"
                                
                                # Optional: Verify frontend version (non-blocking)
                                if cloudfront_domain=$(terragrunt output -raw cloudfront_domain_name 2>/dev/null); then
                                    if [ -n "$cloudfront_domain" ] && [ "$cloudfront_domain" != "null" ]; then
                                        verify_frontend_version "$cloudfront_domain" || true  # Non-blocking
                                    fi
                                fi
                            else
                                # wait_for_invalidation returned error (non-blocking mode)
                                # Deployment will continue - invalidation happens in background
                                log_warning "CloudFront invalidation did not complete within timeout"
                                log_warning "Deployment will continue - invalidation will complete in the background"
                                log_info "Frontend files are already deployed to S3"
                                log_info "The new version will be available once CloudFront invalidation completes"
                            fi
                        else
                            # Invalidation creation failed - log warning but don't block deployment
                            log_warning "Failed to create CloudFront invalidation"
                            log_warning "Deployment will continue - frontend files are already deployed to S3"
                            log_info "You may need to manually invalidate CloudFront cache later"
                            log_info "Or wait for the cache to expire naturally"
                        fi
                    else
                        log_warning "CloudFront invalidation helper not found: $helper_script"
                        log_info "Skipping automatic invalidation"
                    fi
                else
                    log_warning "CloudFront distribution ID not found in Terraform outputs"
                    log_info "Skipping CloudFront invalidation"
                fi
            else
                log_warning "Could not get CloudFront distribution ID from Terraform"
                log_info "Skipping CloudFront invalidation - manual invalidation may be required"
            fi
            
            cd "$ORIG_DIR" 2>/dev/null || true
        fi
    else
        log_warning "Cannot access Terraform outputs for CloudFront invalidation"
        log_info "Skipping CloudFront invalidation"
    fi
    
    # Log completion
    log_success "Frontend deployment complete"
    log_info "  Website URL: http://$S3_BUCKET_NAME.s3-website-$AWS_REGION.amazonaws.com"
    if [ -n "$cloudfront_domain" ]; then
        log_info "  CloudFront URL: https://$cloudfront_domain"
    fi
    log_info ""
    log_info "Note: CloudFront distribution is managed by Terraform"
    log_info "  CloudFront will automatically serve content from this S3 bucket"
}

main() {
    deploy_frontend
}

main "$@"

