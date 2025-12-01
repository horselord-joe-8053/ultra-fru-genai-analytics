#!/bin/bash
# Deploy infrastructure using Terraform
# Idempotent: terraform apply is safe to run multiple times

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
source "$SCRIPT_DIR/../../common/logger.sh"

TERRAFORM_DIR="$REPO_ROOT/infra/terraform"

deploy_terraform() {
    log_step "Deploying infrastructure with Terraform"
    
    # Check AWS credentials
    "$SCRIPT_DIR/../check-aws-credentials.sh" || exit 1
    
    # Check if Terraform is installed
    if ! command_exists terraform; then
        log_error "Terraform is not installed"
        log_info "Install with: brew install terraform"
        exit 1
    fi
    
    if [ ! -d "$TERRAFORM_DIR" ]; then
        log_error "Terraform directory not found at $TERRAFORM_DIR"
        exit 1
    fi
    
    cd "$TERRAFORM_DIR"
    
    log_info "Initializing Terraform..."
    terraform init
    
    log_info "Planning Terraform changes..."
    terraform plan
    
    log_warning "Terraform will create/modify AWS resources"
    read -p "Do you want to proceed with terraform apply? (yes/no): " confirm
    
    if [ "$confirm" != "yes" ]; then
        log_info "Terraform apply cancelled"
        return 0
    fi
    
    log_info "Applying Terraform configuration..."
    terraform apply
    
    log_success "Terraform deployment complete!"
    log_info "To view outputs: terraform output"
    log_info "To destroy infrastructure: terraform destroy"
}

main() {
    deploy_terraform
}

main "$@"

