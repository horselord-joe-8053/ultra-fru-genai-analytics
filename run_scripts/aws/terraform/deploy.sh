#!/bin/bash
# Deploy infrastructure using Terragrunt
# Idempotent: terragrunt apply is safe to run multiple times
# Usage: ./deploy.sh [dev|prod] [infrastructure|application|all]

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

deploy_terragrunt() {
    log_step "Deploying infrastructure with Terragrunt"
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
    
    # Load environment variables (needed for bootstrap script)
    load_env_file
    
    # Setup Terraform state bucket (if needed)
    log_step "Ensuring Terraform state bucket exists"
    "$SCRIPT_DIR/setup-s3-bucket.sh" || exit 1
    
    # Set required environment variables for Terragrunt
    export AWS_REGION="${AWS_REGION:-us-east-1}"
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
        terragrunt plan
        
        log_warning "Terragrunt will create/modify AWS resources"
        read -p "Do you want to proceed with terragrunt apply? (yes/no): " confirm
        
        if [ "$confirm" = "yes" ]; then
            log_info "Applying Terragrunt configuration..."
            terragrunt apply
            log_success "Infrastructure layer deployed!"
        else
            log_info "Infrastructure deployment cancelled"
        fi
    fi
    
    # Deploy application layer
    if [ "$LAYER" = "application" ] || [ "$LAYER" = "all" ]; then
        log_step "Deploying application layer (ECS, ALB, Frontend)"
        
        # Check if container image is set
        if [ -z "$CONTAINER_IMAGE" ]; then
            log_warning "CONTAINER_IMAGE not set. You may need to build and push to ECR first."
            log_info "Run: ./run_scripts/aws/ecs/build-push-ecr.sh"
            read -p "Continue anyway? (yes/no): " continue_anyway
            if [ "$continue_anyway" != "yes" ]; then
                log_info "Application deployment cancelled"
                return 0
            fi
        else
            export CONTAINER_IMAGE
        fi
        
        cd "$ENV_DIR/application"
        
        log_info "Running terragrunt plan..."
        terragrunt plan
        
        log_warning "Terragrunt will create/modify AWS resources"
        read -p "Do you want to proceed with terragrunt apply? (yes/no): " confirm
        
        if [ "$confirm" = "yes" ]; then
            log_info "Applying Terragrunt configuration..."
            terragrunt apply
            log_success "Application layer deployed!"
        else
            log_info "Application deployment cancelled"
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

