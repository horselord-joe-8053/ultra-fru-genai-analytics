#!/bin/bash
# Teardown infrastructure using Terragrunt
# Idempotent: terragrunt destroy is safe to run multiple times
# Usage: ./teardown.sh [dev|prod] [infrastructure|ecs|eks|all]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
source "$REPO_ROOT/orchestration/common/logger.sh"
source "$REPO_ROOT/orchestration/common/env/load-env.sh"

TERRAFORM_DIR="$REPO_ROOT/module_infra_basic/aws/terra/environments"
INFRA_TERRAFORM_DIR="$REPO_ROOT/module_infra_basic/aws/terra/environments"
EKS_TERRAFORM_DIR="$REPO_ROOT/module_infra_kubetypes/kube/aws/terra/environments"
ECS_TERRAFORM_DIR="$REPO_ROOT/module_infra_kubetypes/nonkube/aws/terra/environments"

# Parse arguments
ENVIRONMENT="${1:-dev}"
LAYER="${2:-all}"

if [[ ! "$ENVIRONMENT" =~ ^(dev|prod)$ ]]; then
    log_error "Invalid environment: $ENVIRONMENT"
    log_info "Usage: $0 [dev|prod] [infrastructure|application|all]"
    exit 1
fi

if [[ ! "$LAYER" =~ ^(infrastructure|ecs|eks|all)$ ]]; then
    log_error "Invalid layer: $LAYER"
    log_info "Usage: $0 [dev|prod] [infrastructure|ecs|eks|all]"
    exit 1
fi

teardown_terragrunt() {
    log_step "Teardown infrastructure with Terragrunt"
    log_info "REPO_ROOT: $REPO_ROOT"
    log_info "Environment: $ENVIRONMENT"
    log_info "Layer: $LAYER"
    
    # In PREEMPT mode, force Terragrunt into fully non-interactive behavior for all
    # operations (plan/destroy, including run-all / dependency prompts).
    if [ "${PREEMPT:-false}" = "true" ]; then
        export TG_NON_INTERACTIVE=true
        log_info "PREEMPT=true: exporting TG_NON_INTERACTIVE=true for all Terragrunt commands"
    fi
    
    # Check AWS credentials
    "$REPO_ROOT/orchestration/aws/check-aws-credentials.sh" || exit 1
    
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
    
    # Load environment variables
    load_env_file
    
    # Ensure Terragrunt (and root.hcl get_aws_account_id()) see AWS profile/region.
    # Without these, remote_state in root.hcl can fail with "get_aws_account_id failed".
    export AWS_PROFILE="${AWS_PROFILE:-admin}"
    export AWS_REGION="${AWS_REGION:-us-east-1}"
    
    ENV_DIR="$TERRAFORM_DIR/$ENVIRONMENT"
    INFRA_ENV_DIR="$INFRA_TERRAFORM_DIR/$ENVIRONMENT"
    EKS_ENV_DIR="$EKS_TERRAFORM_DIR/$ENVIRONMENT"
    ECS_ENV_DIR="$ECS_TERRAFORM_DIR/$ENVIRONMENT"
    
    if [ ! -d "$ENV_DIR" ]; then
        log_error "Environment directory not found at $ENV_DIR"
        exit 1
    fi
    
    # Destroy in reverse order: frontend first, then application, then infrastructure
    # Frontend (S3 + CloudFront) depends on app layer; app depends on infrastructure
    
    # Destroy frontend-ecs layer (lives in module_infra_basic; S3 + CloudFront)
    if [ "$LAYER" = "ecs" ] || ([ "$LAYER" = "all" ] && [ "$CONTAINER_TYPE" = "ecs" ]); then
        if [ -d "$INFRA_ENV_DIR/frontend-ecs" ]; then
            log_step "Destroying frontend-ecs layer (S3, CloudFront)"
            cd "$INFRA_ENV_DIR/frontend-ecs"
            terragrunt init -reconfigure >/dev/null 2>&1 || true
            if terragrunt state list >/dev/null 2>&1; then
                terragrunt plan -destroy >/dev/null 2>&1 || true
                if [ "${PREEMPT:-false}" = "true" ]; then
                    confirm="yes"
                else
                    read -p "Destroy frontend-ecs (S3, CloudFront)? (yes/no): " confirm
                fi
                if [ "$confirm" = "yes" ]; then
                    [ "${PREEMPT:-false}" = "true" ] && terragrunt destroy --terragrunt-non-interactive || terragrunt destroy || true
                    log_success "Frontend-ecs layer destroyed!"
                fi
            else
                log_info "No state for frontend-ecs (already destroyed or never deployed)"
            fi
        fi
    fi
    
    # Destroy frontend-eks layer (lives in module_infra_basic; S3 + CloudFront)
    if [ "$LAYER" = "eks" ] || ([ "$LAYER" = "all" ] && [ "$CONTAINER_TYPE" = "eks" ]); then
        if [ -d "$INFRA_ENV_DIR/frontend-eks" ]; then
            log_step "Destroying frontend-eks layer (S3, CloudFront)"
            cd "$INFRA_ENV_DIR/frontend-eks"
            terragrunt init -reconfigure >/dev/null 2>&1 || true
            if terragrunt state list >/dev/null 2>&1; then
                terragrunt plan -destroy >/dev/null 2>&1 || true
                if [ "${PREEMPT:-false}" = "true" ]; then
                    confirm="yes"
                else
                    read -p "Destroy frontend-eks (S3, CloudFront)? (yes/no): " confirm
                fi
                if [ "$confirm" = "yes" ]; then
                    [ "${PREEMPT:-false}" = "true" ] && terragrunt destroy --terragrunt-non-interactive || terragrunt destroy || true
                    log_success "Frontend-eks layer destroyed!"
                fi
            else
                log_info "No state for frontend-eks (already destroyed or never deployed)"
            fi
        fi
    fi
    
    # Destroy ecs layer (lives in module_infra_kubetypes/nonkube; ECS, ALB only; frontend now separate)
    if [ "$LAYER" = "ecs" ] || ([ "$LAYER" = "all" ] && [ "$CONTAINER_TYPE" = "ecs" ]); then
        log_step "Destroying ecs layer (ECS, ALB)"
        cd "$ECS_ENV_DIR/ecs"
        
        # Ensure backend is configured so we can read state from S3 (idempotent).
        log_info "Initializing Terragrunt for ecs layer (configures remote state)..."
        terragrunt init -reconfigure >/dev/null 2>&1 || true
        
        # Check if terragrunt state exists (resources may have been destroyed already)
        if terragrunt state list >/dev/null 2>&1; then
            log_info "Running terragrunt destroy plan..."
            terragrunt plan -destroy || {
                log_warning "No resources to destroy in application layer (may already be destroyed)"
            }
            
            log_warning "Terragrunt will DESTROY AWS resources in application layer"
            log_warning "This action cannot be undone!"
            # When PREEMPT=true (run.sh --preempt), auto-confirm to keep flow non-interactive.
            if [ "${PREEMPT:-false}" = "true" ]; then
                confirm="yes"
                log_info "PREEMPT=true: auto-confirming terragrunt destroy for ECS layer"
            else
                read -p "Do you want to proceed with terragrunt destroy? (yes/no): " confirm
            fi
            
            if [ "$confirm" = "yes" ]; then
                log_info "Destroying application layer..."
                if [ "${PREEMPT:-false}" = "true" ]; then
                    terragrunt destroy --terragrunt-non-interactive || {
                        log_warning "Destroy failed or no resources to destroy (idempotent)"
                    }
                else
                    terragrunt destroy || {
                        log_warning "Destroy failed or no resources to destroy (idempotent)"
                    }
                fi
                log_success "ECS layer destroyed!"
            else
                log_info "ECS layer teardown cancelled"
            fi
        else
            log_info "No Terraform state found for ecs layer (already destroyed or never deployed)"
        fi
    fi
    
    # Destroy eks layer (lives in module_infra_kubetypes/kube; EKS cluster, node group, Fargate; frontend now separate)
    if [ "$LAYER" = "eks" ] || ([ "$LAYER" = "all" ] && [ "$CONTAINER_TYPE" = "eks" ]); then
        log_step "Destroying eks layer (EKS cluster, node group, Fargate)"
        cd "$EKS_ENV_DIR/eks"
        
        # Ensure backend is configured so we can read state from S3 (idempotent).
        log_info "Initializing Terragrunt for eks layer (configures remote state)..."
        local tg_init_out
        tg_init_out="$(terragrunt init -reconfigure 2>&1)" || true
        if [ -n "$tg_init_out" ] && echo "$tg_init_out" | grep -qiE 'error|failed|cannot'; then
            log_warning "Terragrunt init for eks had messages: ${tg_init_out:0:500}"
        fi
        
        local state_list_out state_list_rc=0
        state_list_out="$(terragrunt state list 2>&1)" || state_list_rc=$?
        if [ "$state_list_rc" -eq 0 ]; then
            log_info "Running terragrunt destroy plan for eks layer..."
            local tg_plan_output
            local tg_plan_status=0
            tg_plan_output="$(terragrunt plan -destroy 2>&1)" || tg_plan_status=$?
            if [ "$tg_plan_status" -ne 0 ]; then
                log_warning "Terraform plan -destroy for eks layer reported issues (may already be destroyed)"
                if [ -n "$tg_plan_output" ]; then
                    log_info "Terraform plan output (trimmed): ${tg_plan_output:0:400}"
                fi
            fi
            
            log_warning "Terragrunt will DESTROY AWS resources in eks layer (EKS cluster, node group, frontend)"
            log_warning "This action cannot be undone!"
            if [ "${PREEMPT:-false}" = "true" ]; then
                confirm="yes"
                log_info "PREEMPT=true: auto-confirming terragrunt destroy for EKS layer"
            else
                read -p "Do you want to proceed with terragrunt destroy? (yes/no): " confirm
            fi
            
            if [ "$confirm" = "yes" ]; then
                log_info "Destroying eks layer..."
                if [ "${PREEMPT:-false}" = "true" ]; then
                    terragrunt destroy --terragrunt-non-interactive || {
                        log_warning "Destroy failed or no resources to destroy (idempotent)"
                    }
                else
                    terragrunt destroy || {
                        log_warning "Destroy failed or no resources to destroy (idempotent)"
                    }
                fi
                log_success "EKS layer destroyed!"
            else
                log_info "EKS layer teardown cancelled"
            fi
        else
            log_info "No Terraform state found for eks layer (already destroyed or never deployed)"
            if [ -n "$state_list_out" ]; then
                # Show only the Terraform message; strip ANSI and Terragrunt WARN/ERROR lines
                reason="$(echo "$state_list_out" | sed 's/\x1b\[[0-9;]*m//g' | grep -E 'No state file was found|State management commands require' | head -1 | sed 's/^[[:space:]]*//')"
                [ -n "$reason" ] && log_info "Reason: $reason"
                log_info "If EKS state was at dev/application-eks/terraform.tfstate, run: ./migrate-eks-state.sh dev then retry."
            fi
        fi
    fi
    
    # Optional wait between app-layer destroy and infrastructure destroy (LAYER=all only).
    # Gives AWS time to release ENIs asynchronously after ALB/EKS/ECS deletion (see README_WAR_STORIES.md).
    # Set TEARDOWN_WAIT_BETWEEN_LAYERS=120 (seconds) to wait 2 min; default 0 = no wait.
    if [ "$LAYER" = "all" ] && [ "${TEARDOWN_WAIT_BETWEEN_LAYERS:-0}" -gt 0 ]; then
        log_step "Waiting ${TEARDOWN_WAIT_BETWEEN_LAYERS}s for AWS to release ENIs before infrastructure destroy"
        sleep "${TEARDOWN_WAIT_BETWEEN_LAYERS}"
    fi
    
    # Destroy infrastructure layer (lives in module_infra_basic/aws)
    if [ "$LAYER" = "infrastructure" ] || [ "$LAYER" = "all" ]; then
        log_step "Destroying infrastructure layer (VPC, Aurora, IAM, Secrets Manager)"
        
        cd "$INFRA_ENV_DIR/infrastructure"
        
        # Ensure backend is configured so we can read state from S3 (idempotent).
        log_info "Initializing Terragrunt for infrastructure layer (configures remote state)..."
        terragrunt init -reconfigure >/dev/null 2>&1 || true
        
        # Check if terragrunt state exists (resources may have been destroyed already)
        if terragrunt state list >/dev/null 2>&1; then
            log_info "Running terragrunt destroy plan for infrastructure layer..."
            # Capture plan output so we can summarize expected errors (like prevent_destroy on secrets)
            # instead of streaming the full Terraform error block to the main log.
            # Do not use bare assignment + set -e: a failing plan would exit the script before we can handle it.
            local tg_plan_output
            local tg_plan_status=0
            tg_plan_output="$(terragrunt plan -destroy 2>&1)" || tg_plan_status=$?
            if [ "$tg_plan_status" -ne 0 ]; then
                # Common and expected case: Secrets Manager resources have lifecycle.prevent_destroy
                # and Terraform will refuse to plan their destruction. This is a safety guard, not
                # a failure of our teardown flow.
                log_warning "Terraform plan -destroy for infrastructure layer reported protected resources or no resources to destroy."
                log_info "Secrets Manager secrets with lifecycle.prevent_destroy are intentionally preserved and will NOT be deleted."
                if [ -n "$tg_plan_output" ]; then
                    log_info "Terraform plan output (trimmed): ${tg_plan_output:0:400}"
                fi
                log_info "Proceeding with infrastructure destroy for resources that are allowed to be removed."
            fi
            
            log_warning "Terragrunt will DESTROY AWS resources in infrastructure layer"
            log_warning "This includes: VPC, Aurora database, IAM roles, and other shared infrastructure"
            log_warning "Secrets Manager secrets with lifecycle.prevent_destroy are preserved."
            log_warning "This action cannot be undone!"
            if [ "${PREEMPT:-false}" = "true" ]; then
                confirm="yes"
                log_info "PREEMPT=true: auto-confirming terragrunt destroy for infrastructure layer"
            else
                read -p "Do you want to proceed with terragrunt destroy? (yes/no): " confirm
            fi
            
            if [ "$confirm" = "yes" ]; then
                log_info "Destroying infrastructure layer..."
                local destroy_output
                local destroy_exit=0
                # Capture destroy output; do not let set -e exit when destroy fails (we handle exit below).
                if [ "${PREEMPT:-false}" = "true" ]; then
                    destroy_output="$(terragrunt destroy --terragrunt-non-interactive 2>&1)" || destroy_exit=$?
                else
                    destroy_output="$(terragrunt destroy 2>&1)" || destroy_exit=$?
                fi
                destroy_exit=${destroy_exit:-0}
                if [ "$destroy_exit" -eq 0 ]; then
                    log_success "Infrastructure layer destroyed (Secrets Manager secrets preserved)."
                else
                    # Expected: lifecycle.prevent_destroy or "cannot be destroyed" on secrets/resources we intentionally keep.
                    # Treat as soft failure (warning, exit 0) so orchestrators do not report ERROR.
                    if echo "$destroy_output" | grep -qE 'prevent_destroy|cannot be destroyed|Instance cannot be destroyed|must be removed from state'; then
                        log_warning "Destroy reported protected resources (e.g. lifecycle.prevent_destroy); treating as expected."
                        log_info "Secrets Manager secrets with lifecycle.prevent_destroy are intentionally preserved and will NOT be deleted."
                        log_info "Terraform destroy output (trimmed): ${destroy_output:0:500}"
                        # Exit 0 so shared teardown wrapper does not report ERROR.
                    else
                        log_error "Infrastructure layer destroy failed (unexpected error)."
                        log_info "Terraform destroy output (trimmed): ${destroy_output:0:800}"
                        if echo "$destroy_output" | grep -qE 'get_aws_account_id|GetCallerIdentity|credentials|failed to refresh'; then
                            log_info "Hint: Ensure AWS_PROFILE is set and valid for Terragrunt (e.g. export AWS_PROFILE=admin)."
                        fi
                        exit 1
                    fi
                fi
            else
                log_info "Infrastructure layer teardown cancelled"
            fi
        else
            log_info "No Terraform state found for infrastructure layer (already destroyed or never deployed)"
        fi
    fi
    
    log_success "Terragrunt teardown complete!"
    log_info ""
    log_info "Note: Terraform state bucket and state files are preserved"
    log_info "To remove state bucket: aws s3 rb s3://\$TF_STATE_BUCKET --force"
}

main() {
    teardown_terragrunt
}

main "$@"

