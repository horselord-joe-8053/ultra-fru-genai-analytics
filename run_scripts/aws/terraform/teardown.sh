#!/bin/bash
# Teardown infrastructure using Terragrunt
# Idempotent: terragrunt destroy is safe to run multiple times
# Usage: ./teardown.sh [dev|prod] [infrastructure|application|all]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
source "$SCRIPT_DIR/../../common/logger.sh"
source "$SCRIPT_DIR/../../common/load-env.sh"

TERRAFORM_DIR="$REPO_ROOT/infra/terraform/environments"

# Parse arguments
ENVIRONMENT="${1:-dev}"
LAYER="${2:-all}"

if [[ ! "$ENVIRONMENT" =~ ^(dev|prod)$ ]]; then
    log_error "Invalid environment: $ENVIRONMENT"
    log_info "Usage: $0 [dev|prod] [infrastructure|application|all]"
    exit 1
fi

if [[ ! "$LAYER" =~ ^(infrastructure|application|all)$ ]]; then
    log_error "Invalid layer: $LAYER"
    log_info "Usage: $0 [dev|prod] [infrastructure|application|all]"
    exit 1
fi

teardown_terragrunt() {
    log_step "Teardown infrastructure with Terragrunt"
    log_info "REPO_ROOT: $REPO_ROOT"
    log_info "Environment: $ENVIRONMENT"
    log_info "Layer: $LAYER"
    
    # Check AWS credentials
    "$SCRIPT_DIR/../aws/check-aws-credentials.sh" || exit 1
    
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
    
    # Set required environment variables for Terragrunt
    export AWS_REGION="${AWS_REGION:-us-east-1}"
    export ENVIRONMENT="$ENVIRONMENT"
    
    ENV_DIR="$TERRAFORM_DIR/$ENVIRONMENT"
    
    if [ ! -d "$ENV_DIR" ]; then
        log_error "Environment directory not found at $ENV_DIR"
        exit 1
    fi
    
    # Destroy in reverse order: application first, then infrastructure
    # This is because application depends on infrastructure
    
    # Destroy application layer
    if [ "$LAYER" = "application" ] || [ "$LAYER" = "all" ]; then
        log_step "Destroying application layer (ECS, ALB, Frontend)"
        
        cd "$ENV_DIR/application"
        
        # Check if terragrunt state exists (resources may have been destroyed already)
        if [ -f ".terragrunt-cache" ] || terragrunt state list --terragrunt-config appl.hcl >/dev/null 2>&1; then
            log_info "Running terragrunt destroy plan..."
            terragrunt plan -destroy --terragrunt-config appl.hcl || {
                log_warning "No resources to destroy in application layer (may already be destroyed)"
            }
            
            log_warning "Terragrunt will DESTROY AWS resources in application layer"
            log_warning "This action cannot be undone!"
            read -p "Do you want to proceed with terragrunt destroy? (yes/no): " confirm
            
            if [ "$confirm" = "yes" ]; then
                log_info "Destroying application layer..."
                terragrunt destroy --terragrunt-config appl.hcl || {
                    log_warning "Destroy failed or no resources to destroy (idempotent)"
                }
                log_success "Application layer destroyed!"
            else
                log_info "Application layer teardown cancelled"
            fi
        else
            log_info "No Terraform state found for application layer (already destroyed or never deployed)"
        fi
    fi
    
    # Destroy infrastructure layer
    if [ "$LAYER" = "infrastructure" ] || [ "$LAYER" = "all" ]; then
        log_step "Destroying infrastructure layer (VPC, Aurora, IAM, Secrets Manager)"
        
        cd "$ENV_DIR/infrastructure"
        
        # Check if terragrunt state exists (resources may have been destroyed already)
        if [ -f ".terragrunt-cache" ] || terragrunt state list --terragrunt-config infra.hcl >/dev/null 2>&1; then
            log_info "Running terragrunt destroy plan..."
            terragrunt plan -destroy --terragrunt-config infra.hcl || {
                log_warning "No resources to destroy in infrastructure layer (may already be destroyed)"
            }
            
            log_warning "Terragrunt will DESTROY AWS resources in infrastructure layer"
            log_warning "This includes: VPC, Aurora database, IAM roles, Secrets Manager"
            log_warning "This action cannot be undone!"
            read -p "Do you want to proceed with terragrunt destroy? (yes/no): " confirm
            
            if [ "$confirm" = "yes" ]; then
                log_info "Destroying infrastructure layer..."
                terragrunt destroy --terragrunt-config infra.hcl || {
                    log_warning "Destroy failed or no resources to destroy (idempotent)"
                }
                log_success "Infrastructure layer destroyed!"
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

