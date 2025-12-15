#!/bin/bash
# Deploy infrastructure using Terragrunt
# Idempotent: terragrunt apply is safe to run multiple times
# Usage: ./deploy.sh [dev|prod] [infrastructure|application|eks|all]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
source "$SCRIPT_DIR/../../common/logger.sh"
source "$SCRIPT_DIR/../../common/load-env.sh"

TERRAFORM_DIR="$REPO_ROOT/infra/terraform/environments"

# Check for dry-run mode (from parent script)
DRY_RUN="${DRY_RUN:-false}"

# Parse arguments
ENVIRONMENT="${1:-dev}"
LAYER="${2:-all}"

if [[ ! "$ENVIRONMENT" =~ ^(dev|prod)$ ]]; then
    log_error "Invalid environment: $ENVIRONMENT"
    log_info "Usage: $0 [dev|prod] [infrastructure|application|eks|all]"
    exit 1
fi

if [[ ! "$LAYER" =~ ^(infrastructure|application|eks|all)$ ]]; then
    log_error "Invalid layer: $LAYER"
    log_info "Usage: $0 [dev|prod] [infrastructure|application|eks|all]"
    exit 1
fi

deploy_terragrunt() {
    log_step "Deploying infrastructure with Terragrunt"
    log_info "REPO_ROOT: $REPO_ROOT"
    log_info "Environment: $ENVIRONMENT"
    log_info "Layer: $LAYER"

    # Helper to run terragrunt with a single automatic unlock/retry on lock errors
    # Streams output in real-time while still capturing for lock error detection
    run_with_lock_retry() {
        local description="$1"; shift
        local cmd=( "$@" )
        local tmp_out
        tmp_out="$(mktemp)"

        log_info "Running: ${cmd[*]}  (${description})"
        log_info "Note: This operation may take several minutes. Output will stream in real-time..."
        
        # Stream output to both terminal and temp file using tee
        # This allows real-time visibility while still capturing output for lock error detection
        if "${cmd[@]}" 2>&1 | tee "$tmp_out"; then
            rm -f "$tmp_out"
            return 0
        fi
        
        # Command failed - check exit code from tee (which reflects the command's exit code)
        local exit_code=${PIPESTATUS[0]}
        
        # Check for lock error in captured output
        if grep -q "Error acquiring the state lock" "$tmp_out"; then
            # Strip ANSI to ease parsing
            local clean_out
            clean_out="$(mktemp)"
            sed -E 's/\x1B\[[0-9;]*[mK]//g' "$tmp_out" > "$clean_out"

            # Try to extract the lock ID from common patterns
            local lock_id
            # Simplest and most robust: grab the first UUID in the output
            lock_id="$(grep -Eo '[0-9a-fA-F-]{8}-[0-9a-fA-F-]{4}-[0-9a-fA-F-]{4}-[0-9a-fA-F-]{4}-[0-9a-fA-F-]{12}' "$clean_out" | head -1)"
            # Basic sanity: ensure it looks like a UUID
            if ! [[ "$lock_id" =~ ^[0-9a-fA-F-]{8}-[0-9a-fA-F-]{4}-[0-9a-fA-F-]{4}-[0-9a-fA-F-]{4}-[0-9a-fA-F-]{12}$ ]]; then
                lock_id=""
            fi

            if [ -n "$lock_id" ]; then
                log_warning "State lock detected (ID: $lock_id). Attempting force-unlock and retry..."
                log_info "This retry may take several minutes. Terraform will re-run the full operation..."
                if terragrunt force-unlock -force "$lock_id"; then
                    log_info "Lock released. Retrying ${description} (this will re-run the full operation)..."
                    log_info "Note: Output will stream in real-time during retry..."
                    # Retry with streaming output again
                    if "${cmd[@]}" 2>&1 | tee "$tmp_out"; then
                        rm -f "$tmp_out" "$clean_out"
                        return 0
                    fi
                else
                    log_warning "Failed to force-unlock lock ID: $lock_id"
                fi
            else
                log_warning "State lock detected but lock ID could not be parsed. Showing original error."
            fi

            rm -f "$clean_out"
        fi

        # Show captured output if command failed (for non-lock errors)
        cat "$tmp_out"
        rm -f "$tmp_out"
        return 1
    }
    
    # Check AWS credentials
    "$SCRIPT_DIR/../check-aws-credentials.sh" || exit 1
    
    # Check if Terragrunt is installed
    if ! command_exists terragrunt; then
        log_error "Terragrunt is not installed"
        log_info "Install with: brew install terragrunt"
        exit 1
    fi
    
    # Check if Terraform is installed
    if ! command_exists terraform; then
        log_error "Terraform is not installed"
        log_info "Install with: brew install terraform"
        exit 1
    fi
    
    # Load environment variables (needed for bootstrap script)
    load_env_file
    
    # Setup Terraform state bucket (if needed)
    log_step "Ensuring Terraform state bucket exists"
    "$SCRIPT_DIR/setup-s3-bucket.sh" || exit 1
    
    # Set required environment variables for Terragrunt
    export AWS_REGION="${AWS_REGION:-us-east-1}"
    export AWS_PROFILE="${AWS_PROFILE:-admin}"  # Use admin profile for Terraform
    export ENVIRONMENT="$ENVIRONMENT"
    
    # Set secrets if available
    if [ -n "$OPENAI_API_KEY" ]; then
        export OPENAI_API_KEY
    fi
    
    if [ -n "$PGPASSWORD" ]; then
        export PGPASSWORD
    fi
    
    ENV_DIR="$TERRAFORM_DIR/$ENVIRONMENT"
    
    if [ ! -d "$ENV_DIR" ]; then
        log_error "Environment directory not found at $ENV_DIR"
        exit 1
    fi
    
    # Deploy infrastructure layer
    if [ "$LAYER" = "infrastructure" ] || [ "$LAYER" = "all" ]; then
        log_step "Deploying infrastructure layer (VPC, Aurora, IAM, Secrets Manager)"
        
        cd "$ENV_DIR/infrastructure"
        
        log_info "Running terragrunt plan..."
        if ! run_with_lock_retry "plan (infrastructure)" terragrunt plan -lock-timeout=5m; then
            log_error "Terraform plan failed for infrastructure layer"
            log_info "Check the plan output above for errors"
            exit 1
        fi
        
        if [ "$DRY_RUN" = "true" ]; then
            log_info "[DRY-RUN] Would run: terragrunt apply"
            log_info "[DRY-RUN] Plan output shown above. No changes will be made."
        else
            log_info "Applying Terragrunt configuration for infrastructure layer..."
            if ! run_with_lock_retry "apply (infrastructure)" terragrunt apply -auto-approve -lock-timeout=5m; then
                log_error "Terraform apply failed for infrastructure layer"
                log_info "Check the apply output above for errors"
                exit 1
            fi
            log_success "Infrastructure layer deployed successfully!"
        fi
    fi
    
    # Deploy application layer
    if [ "$LAYER" = "application" ] || [ "$LAYER" = "all" ]; then
        log_step "Deploying application layer (ECS, ALB, Frontend)"
        
        # Check if container image is set
        if [ -z "$CONTAINER_IMAGE" ]; then
            log_error "CONTAINER_IMAGE not set. Container image is required for application deployment."
            log_info "The image should be built and pushed to ECR first."
            log_info "Run: ./run_scripts/aws/common_ecs_eks/build-push-ecr.sh"
            if [ "$DRY_RUN" = "true" ]; then
                log_info "[DRY-RUN] Continuing with dry-run (image would be required for actual deployment)"
            else
                log_error "Cannot proceed without CONTAINER_IMAGE. Exiting."
                exit 1
            fi
        else
            export CONTAINER_IMAGE
            log_info "Using container image: $CONTAINER_IMAGE"
        fi
        
        cd "$ENV_DIR/application"
        
        log_info "Running terragrunt plan for application layer..."
        if ! run_with_lock_retry "plan (application)" terragrunt plan -lock-timeout=5m; then
            log_error "Terraform plan failed for application layer"
            log_info "Check the plan output above for errors"
            exit 1
        fi
        
        if [ "$DRY_RUN" = "true" ]; then
            log_info "[DRY-RUN] Would run: terragrunt apply"
            log_info "[DRY-RUN] Plan output shown above. No changes will be made."
        else
            log_info "Applying Terragrunt configuration for application layer..."
            if ! run_with_lock_retry "apply (application)" terragrunt apply -auto-approve -lock-timeout=5m; then
                log_error "Terraform apply failed for application layer"
                log_info "Check the apply output above for errors"
                exit 1
            fi
            log_success "Application layer deployed successfully!"
        fi
    fi
    
    # Deploy EKS layer
    if [ "$LAYER" = "eks" ] || [ "$LAYER" = "all" ]; then
        log_step "Deploying EKS layer (EKS cluster, node groups, OIDC provider)"
        
        cd "$ENV_DIR/eks"
        
        log_info "Running terragrunt plan for EKS layer..."
        if ! terragrunt plan; then
            log_error "Terraform plan failed for EKS layer"
            log_info "Check the plan output above for errors"
            exit 1
        fi
        
        if [ "$DRY_RUN" = "true" ]; then
            log_info "[DRY-RUN] Would run: terragrunt apply"
            log_info "[DRY-RUN] Plan output shown above. No changes will be made."
        else
            log_info "Applying Terragrunt configuration for EKS layer..."
            if ! terragrunt apply -auto-approve; then
                log_error "Terraform apply failed for EKS layer"
                log_info "Check the apply output above for errors"
                exit 1
            fi
            log_success "EKS layer deployed successfully!"
        fi
    fi
    
    log_success "Terragrunt deployment complete!"
    log_info "To view outputs: cd $ENV_DIR/<layer> && terragrunt output"
    log_info "To destroy: cd $ENV_DIR/<layer> && terragrunt destroy"
}

main() {
    deploy_terragrunt
}

main "$@"

