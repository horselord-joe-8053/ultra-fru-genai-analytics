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

    # Helper functions for lock handling
    # Calculate age of lock in seconds
    calculate_lock_age() {
        local created_iso="$1"
        # Parse ISO 8601 timestamp (e.g., "2025-12-18T22:46:26.942208Z")
        # Remove microseconds and Z suffix for parsing
        local created_clean="${created_iso%.*}"  # Remove .942208
        created_clean="${created_clean%Z}"       # Remove Z
        
        if ! command_exists date; then
            echo 0
            return
        fi
        
        local created_epoch=0
        local now_epoch=$(date +%s 2>/dev/null || echo 0)
        
        # Try macOS date format first (date -j)
        if created_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%S" "$created_clean" +%s 2>/dev/null); then
            echo $((now_epoch - created_epoch))
            return
        fi
        
        # Try Linux date format (date -d)
        if created_epoch=$(date -d "$created_iso" +%s 2>/dev/null); then
            echo $((now_epoch - created_epoch))
            return
        fi
        
        # Fallback: return 0 if parsing fails
        echo 0
    }

    # Check if Terraform/terragrunt process is running for current user
    is_process_running() {
        local lock_who="$1"
        
        # Check for running terraform or terragrunt processes for current user
        # Use pgrep if available, otherwise use ps
        if command_exists pgrep; then
            if pgrep -f "terraform|terragrunt" >/dev/null 2>&1; then
                return 0  # Process is running
            fi
        elif command_exists ps; then
            if ps aux | grep -v grep | grep -E "terraform|terragrunt" >/dev/null 2>&1; then
                return 0  # Process is running
            fi
        fi
        
        return 1  # No process found
    }

    # Download and parse S3 lock file
    get_lock_file_info() {
        local env="$1"
        local layer="$2"
        local bucket="${TF_STATE_BUCKET:-}"
        
        if [ -z "$bucket" ]; then
            # Try to get from environment or construct default
            bucket="${TF_STATE_BUCKET:-fru-terraform-state-$(aws sts get-caller-identity --profile "${AWS_PROFILE:-admin}" --query Account --output text 2>/dev/null || echo "")}"
        fi
        
        if [ -z "$bucket" ]; then
            return 1
        fi
        
        local lock_file_path="$env/$layer/terraform.tfstate.tflock"
        local lock_file_s3="s3://$bucket/$lock_file_path"
        local tmp_lock_file
        tmp_lock_file="$(mktemp)"
        
        # Try to download lock file (suppress progress output)
        if aws s3 cp "$lock_file_s3" "$tmp_lock_file" --profile "${AWS_PROFILE:-admin}" --region "${AWS_REGION:-us-east-1}" --no-progress >/dev/null 2>&1; then
            # Verify file was actually downloaded and exists
            if [ -f "$tmp_lock_file" ] && [ -s "$tmp_lock_file" ]; then
                echo "$tmp_lock_file"
                return 0
            else
                rm -f "$tmp_lock_file"
                return 1
            fi
        else
            rm -f "$tmp_lock_file"
            return 1
        fi
    }

    # Check if lock file still exists in S3
    lock_still_exists() {
        local env="$1"
        local layer="$2"
        local bucket="${TF_STATE_BUCKET:-}"
        
        if [ -z "$bucket" ]; then
            bucket="${TF_STATE_BUCKET:-fru-terraform-state-$(aws sts get-caller-identity --profile "${AWS_PROFILE:-admin}" --query Account --output text 2>/dev/null || echo "")}"
        fi
        
        if [ -z "$bucket" ]; then
            return 1  # Can't check, assume doesn't exist
        fi
        
        local lock_file_path="$env/$layer/terraform.tfstate.tflock"
        aws s3 ls "s3://$bucket/$lock_file_path" --profile "${AWS_PROFILE:-admin}" --region "${AWS_REGION:-us-east-1}" >/dev/null 2>&1
    }

    # Helper to run terragrunt with improved lock error handling
    # Streams output in real-time while still capturing for lock error detection
    run_with_lock_retry() {
        local description="$1"; shift
        local cmd=( "$@" )
        local tmp_out
        tmp_out="$(mktemp)"
        local exit_code=0

        # Pre-check: Check if a lock already exists before running the command
        # This prevents waiting for the full lock timeout if a stale lock exists
        if lock_still_exists "$ENVIRONMENT" "$LAYER"; then
            log_warning "Lock file detected in S3 before running command. Attempting to handle it..."
            local lock_file
            if lock_file=$(get_lock_file_info "$ENVIRONMENT" "$LAYER" 2>/dev/null); then
                local lock_id=""
                local lock_who=""
                local lock_created=""
                
                # Debug: show lock file contents (first 10 lines) if file exists
                if [ -f "$lock_file" ] && [ -s "$lock_file" ]; then
                    log_info "Lock file contents (first 10 lines):"
                    head -10 "$lock_file" 2>/dev/null | while IFS= read -r line; do
                        log_info "  $line"
                    done || log_warning "Could not read lock file contents"
                else
                    log_warning "Lock file does not exist or is empty: $lock_file"
                fi
                
                if command_exists jq; then
                    lock_id=$(jq -r '.ID // ""' "$lock_file" 2>/dev/null || echo "")
                    lock_who=$(jq -r '.Who // ""' "$lock_file" 2>/dev/null || echo "")
                    lock_created=$(jq -r '.Created // ""' "$lock_file" 2>/dev/null || echo "")
                else
                    lock_id=$(grep -o '"ID":"[^"]*"' "$lock_file" 2>/dev/null | sed 's/"ID":"\(.*\)"/\1/' || echo "")
                    lock_who=$(grep -o '"Who":"[^"]*"' "$lock_file" 2>/dev/null | sed 's/"Who":"\(.*\)"/\1/' || echo "")
                    lock_created=$(grep -o '"Created":"[^"]*"' "$lock_file" 2>/dev/null | sed 's/"Created":"\(.*\)"/\1/' || echo "")
                fi
                
                log_info "Extracted values:"
                log_info "  lock_id: ${lock_id:-<empty>}"
                log_info "  lock_who: ${lock_who:-<empty>}"
                log_info "  lock_created: ${lock_created:-<empty>}"
                
                rm -f "$lock_file"
                
                if [ -n "$lock_id" ]; then
                    log_info "Successfully extracted lock ID: $lock_id"
                    
                    # Calculate lock age
                    local lock_age=0
                    if [ -n "$lock_created" ]; then
                        lock_age=$(calculate_lock_age "$lock_created")
                        log_info "  Lock age: ${lock_age} seconds (created: $lock_created)"
                    fi
                    
                    # Check if lock owner process is still running
                    # If lock is very old (> 10 minutes), consider it stale even if processes are running
                    local stale_threshold=600  # 10 minutes in seconds
                    local processes_running=false
                    if [ -n "$lock_who" ] && is_process_running "$lock_who"; then
                        processes_running=true
                    fi
                    
                    if [ "$processes_running" = true ] && [ $lock_age -lt $stale_threshold ]; then
                        log_error "Active lock detected! Terraform/terragrunt processes are running and lock is recent."
                        log_error "  Lock ID: $lock_id"
                        log_error "  Lock age: ${lock_age} seconds (created: $lock_created)"
                        log_error "  Lock owner: $lock_who"
                        log_error ""
                        log_error "To prevent state corruption, automatic unlock is NOT performed."
                        log_error "Please ensure no other Terraform operations are active for this state."
                        log_error ""
                        log_error "To manually unlock (if safe):"
                        log_error "  cd $TERRAFORM_DIR/$ENVIRONMENT/$LAYER && terragrunt force-unlock $lock_id -force"
                        rm -f "$tmp_out"
                        return 1  # Fail fast
                    elif [ "$processes_running" = true ] && [ $lock_age -ge $stale_threshold ]; then
                        log_warning "Lock is stale (${lock_age}s old) but terraform/terragrunt processes are running."
                        log_warning "  This may be from the current script execution. Proceeding with unlock attempt..."
                    fi
                    
                    # Process is not running (or lock is very old), attempt to unlock
                    log_warning "Stale lock detected (ID: $lock_id). Attempting to unlock before running command..."
                    log_info "  Lock age: ${lock_age} seconds"
                    
                    # Capture current directory to ensure we're in the right place
                    local current_dir
                    current_dir="$(pwd)"
                    log_info "  Current directory: $current_dir"
                    log_info "  Running: terragrunt force-unlock -force $lock_id"
                    
                    local unlock_output
                    unlock_output="$(terragrunt force-unlock -force "$lock_id" 2>&1)"
                    local unlock_exit_code=$?
                    
                    if [ $unlock_exit_code -eq 0 ]; then
                        log_success "Unlock command succeeded. Waiting for S3 propagation..."
                        sleep 2  # Wait for S3 propagation
                        if lock_still_exists "$ENVIRONMENT" "$LAYER"; then
                            log_error "Lock still exists after force-unlock attempt!"
                            log_error "  Lock ID: $lock_id"
                            log_error "  This may indicate S3 propagation delay or unlock failed silently."
                            log_error ""
                            log_error "Manual intervention required:"
                            log_error "  cd $TERRAFORM_DIR/$ENVIRONMENT/$LAYER"
                            log_error "  terragrunt force-unlock $lock_id -force"
                            rm -f "$tmp_out"
                            return 1
                        fi
                        log_success "Lock cleared. Proceeding with command..."
                    else
                        log_error "Failed to force-unlock lock ID: $lock_id"
                        log_error "  Exit code: $unlock_exit_code"
                        log_error "  Command output:"
                        echo "$unlock_output" | while IFS= read -r line; do
                            log_error "    $line"
                        done
                        log_error ""
                        log_error "Manual intervention required:"
                        log_error "  cd $TERRAFORM_DIR/$ENVIRONMENT/$LAYER"
                        log_error "  terragrunt force-unlock $lock_id -force"
                        rm -f "$tmp_out"
                        return 1
                    fi
                else
                    log_warning "Lock file exists but could not extract lock ID from it."
                    log_warning "Proceeding with command - lock error will be detected and handled after timeout."
                fi
            else
                log_warning "Lock file exists in S3 but could not download it for inspection."
                log_warning "Proceeding with command - lock error will be detected and handled after timeout."
            fi
        fi

        log_info "Running: ${cmd[*]}  (${description})"
        log_info "Note: This operation may take several minutes. Output will stream in real-time..."
        
        # Stream output to both terminal and temp file using tee
        # Capture actual exit code using PIPESTATUS
        if "${cmd[@]}" 2>&1 | tee "$tmp_out"; then
            exit_code=0
        else
            exit_code=${PIPESTATUS[0]}  # Get actual command exit code (not tee's)
        fi
        
        # If command succeeded, return success
        if [ $exit_code -eq 0 ]; then
            rm -f "$tmp_out"
            return 0
        fi
        
        # Command failed - check for lock error
        # Use case-insensitive grep and check for multiple lock error patterns
        if grep -qiE "(Error acquiring the state lock|state lock|PreconditionFailed)" "$tmp_out"; then
            log_warning "Lock error detected in output. Parsing lock information..."
            
            # Strip ANSI to ease parsing
            local clean_out
            clean_out="$(mktemp)"
            sed -E 's/\x1B\[[0-9;]*[mK]//g' "$tmp_out" > "$clean_out"

            # Try to extract the lock ID from common patterns (check both clean and original)
            local lock_id
            lock_id="$(grep -Eo '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}' "$clean_out" | head -1)"
            
            # If not found in clean output, try original (in case ANSI stripping removed it)
            if [ -z "$lock_id" ]; then
                lock_id="$(grep -Eo '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}' "$tmp_out" | head -1)"
            fi
            
            # Basic sanity: ensure it looks like a UUID
            if ! [[ "$lock_id" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
                lock_id=""
                log_warning "Could not extract lock ID from error output"
            else
                log_info "Extracted lock ID: $lock_id"
            fi

            if [ -n "$lock_id" ]; then
                log_warning "State lock detected (ID: $lock_id)"
                
                # Try to extract lock info directly from error output first (faster than S3)
                local lock_who=""
                local lock_created=""
                local lock_age=0
                
                # Extract "Who" from error output (format: "Who:       jameswang9311@...")
                lock_who=$(grep -iE "^[[:space:]]*Who:" "$clean_out" | sed -E 's/^[[:space:]]*Who:[[:space:]]*//' | head -1)
                
                # Extract "Created" from error output (format: "Created:   2025-12-18 22:46:26.942208 +0000 UTC")
                lock_created=$(grep -iE "^[[:space:]]*Created:" "$clean_out" | sed -E 's/^[[:space:]]*Created:[[:space:]]*//' | head -1)
                
                # If not found in error output, try to get from S3 lock file
                if [ -z "$lock_who" ] || [ -z "$lock_created" ]; then
                    local lock_file
                    if lock_file=$(get_lock_file_info "$ENVIRONMENT" "$LAYER" 2>/dev/null); then
                        # Parse lock file JSON
                        if command_exists jq; then
                            [ -z "$lock_who" ] && lock_who=$(jq -r '.Who // ""' "$lock_file" 2>/dev/null || echo "")
                            [ -z "$lock_created" ] && lock_created=$(jq -r '.Created // ""' "$lock_file" 2>/dev/null || echo "")
                        else
                            # Fallback: try to parse JSON manually (basic extraction)
                            [ -z "$lock_who" ] && lock_who=$(grep -o '"Who":"[^"]*"' "$lock_file" 2>/dev/null | sed 's/"Who":"\(.*\)"/\1/' || echo "")
                            [ -z "$lock_created" ] && lock_created=$(grep -o '"Created":"[^"]*"' "$lock_file" 2>/dev/null | sed 's/"Created":"\(.*\)"/\1/' || echo "")
                        fi
                        rm -f "$lock_file"
                    fi
                fi
                
                if [ -n "$lock_created" ]; then
                    lock_age=$(calculate_lock_age "$lock_created")
                    if [ $lock_age -gt 0 ]; then
                        log_info "  Detected lock created at: $lock_created (Age: ${lock_age} seconds)"
                    fi
                fi
                if [ -n "$lock_who" ]; then
                    log_info "  Locked by: $lock_who"
                fi
                log_info "  Lock path: fru-terraform-state-${TF_STATE_BUCKET##*-}/$ENVIRONMENT/$LAYER/terraform.tfstate"
                
                # Fail-fast: Check if lock owner process is still running
                if [ -n "$lock_who" ] && is_process_running "$lock_who"; then
                    log_error "Lock owner process is still running!"
                    log_error "  Lock owner: $lock_who"
                    log_error "  Lock ID: $lock_id"
                    if [ $lock_age -gt 0 ]; then
                        log_error "  Lock age: ${lock_age} seconds"
                    fi
                    log_error ""
                    log_error "Another Terraform operation may be in progress."
                    log_error "Wait for it to complete or manually verify no processes are running."
                    log_error ""
                    log_error "To check for running processes:"
                    log_error "  ps aux | grep -E 'terraform|terragrunt'"
                    log_error ""
                    log_error "To manually unlock (if safe):"
                    log_error "  cd $TERRAFORM_DIR/$ENVIRONMENT/$LAYER"
                    log_error "  terragrunt force-unlock $lock_id -force"
                    rm -f "$tmp_out" "$clean_out"
                    return 1  # Fail fast
                fi
                
                # Attempt to unlock
                if [ $lock_age -gt 0 ]; then
                    log_warning "Attempting to unlock lock (ID: $lock_id, age: ${lock_age}s)..."
                else
                    log_warning "Attempting to unlock lock (ID: $lock_id)..."
                fi
                log_info "This retry may take several minutes. Terraform will re-run the full operation..."
                
                if terragrunt force-unlock -force "$lock_id" 2>&1; then
                    # Wait a moment for S3 to propagate
                    sleep 2
                    
                    # Verify lock is actually released
                    if lock_still_exists "$ENVIRONMENT" "$LAYER"; then
                        log_error "Lock still exists after force-unlock attempt!"
                        log_error "  Lock ID: $lock_id"
                        log_error "S3 propagation may be delayed, or unlock failed silently."
                        log_error ""
                        log_error "Manual intervention required:"
                        log_error "  1. Wait a few more seconds and retry"
                        log_error "  2. Check lock file in S3: s3://${TF_STATE_BUCKET:-fru-terraform-state-*}/$ENVIRONMENT/$LAYER/terraform.tfstate.tflock"
                        log_error "  3. Manually unlock: cd $TERRAFORM_DIR/$ENVIRONMENT/$LAYER && terragrunt force-unlock $lock_id -force"
                        rm -f "$tmp_out" "$clean_out"
                        return 1  # Fail fast
                    fi
                    
                    log_success "Lock verified as released"
                    if [ $lock_age -gt 0 ]; then
                        log_info "Lock was ${lock_age} seconds old when unlocked"
                    fi
                    log_info "Retrying ${description} (this will re-run the full operation)..."
                    log_info "Note: Output will stream in real-time during retry..."
                    
                    # Retry with streaming output
                    local retry_tmp_out
                    retry_tmp_out="$(mktemp)"
                    local retry_exit_code=0
                    if "${cmd[@]}" 2>&1 | tee "$retry_tmp_out"; then
                        retry_exit_code=0
                    else
                        retry_exit_code=${PIPESTATUS[0]}  # Get actual command exit code
                    fi
                    
                    # Return the retry exit code (0 for success, non-zero for failure)
                    if [ $retry_exit_code -eq 0 ]; then
                        rm -f "$tmp_out" "$clean_out" "$retry_tmp_out"
                        return 0
                    else
                        # Show output for failed retry
                        cat "$retry_tmp_out"
                        rm -f "$tmp_out" "$clean_out" "$retry_tmp_out"
                        return 1
                    fi
                else
                    log_error "Failed to force-unlock lock!"
                    log_error "  Lock ID: $lock_id"
                    if [ $lock_age -gt 0 ]; then
                        log_error "  Lock age: ${lock_age} seconds"
                    fi
                    if [ -n "$lock_who" ]; then
                        log_error "  Lock owner: $lock_who"
                    fi
                    log_error ""
                    log_error "Manual intervention required:"
                    log_error "  1. Verify no Terraform processes are running: ps aux | grep -E 'terraform|terragrunt'"
                    log_error "  2. Check lock file in S3: s3://${TF_STATE_BUCKET:-fru-terraform-state-*}/$ENVIRONMENT/$LAYER/terraform.tfstate.tflock"
                    log_error "  3. Manually unlock: cd $TERRAFORM_DIR/$ENVIRONMENT/$LAYER && terragrunt force-unlock $lock_id -force"
                    rm -f "$tmp_out" "$clean_out"
                    return 1  # Fail fast
                fi
            else
                log_error "State lock detected but lock ID could not be parsed from error output."
                log_error "This may indicate a corrupted lock file or unexpected error format."
                log_error ""
                log_error "Showing original error output:"
                cat "$clean_out"
                log_error ""
                log_error "Manual intervention required:"
                log_error "  1. Check for running Terraform processes: ps aux | grep -E 'terraform|terragrunt'"
                log_error "  2. Check lock file in S3: s3://${TF_STATE_BUCKET:-fru-terraform-state-*}/$ENVIRONMENT/$LAYER/terraform.tfstate.tflock"
                log_error "  3. Manually inspect and unlock if safe"
                rm -f "$tmp_out" "$clean_out"
                return 1  # Fail fast even if lock ID can't be parsed
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
    
    # Environment variables are now exported by load-env.sh
    # No need to re-export here - they're already available for Terragrunt's get_env()
    
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
        if ! run_with_lock_retry "plan (infrastructure)" terragrunt plan -lock-timeout=30s; then
            log_error "Terraform plan failed for infrastructure layer"
            log_info "Check the plan output above for errors"
            exit 1
        fi
        
        if [ "$DRY_RUN" = "true" ]; then
            log_info "[DRY-RUN] Would run: terragrunt apply"
            log_info "[DRY-RUN] Plan output shown above. No changes will be made."
        else
            log_info "Applying Terragrunt configuration for infrastructure layer..."
            if ! run_with_lock_retry "apply (infrastructure)" terragrunt apply -auto-approve -lock-timeout=30s; then
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
        if ! run_with_lock_retry "plan (application)" terragrunt plan -lock-timeout=30s; then
            log_error "Terraform plan failed for application layer"
            log_info "Check the plan output above for errors"
            exit 1
        fi
        
        if [ "$DRY_RUN" = "true" ]; then
            log_info "[DRY-RUN] Would run: terragrunt apply"
            log_info "[DRY-RUN] Plan output shown above. No changes will be made."
        else
            log_info "Applying Terragrunt configuration for application layer..."
            if ! run_with_lock_retry "apply (application)" terragrunt apply -auto-approve -lock-timeout=30s; then
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

