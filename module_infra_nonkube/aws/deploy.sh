#!/bin/bash
# Main ECS deployment orchestrator
# This script orchestrates the full ECS deployment process
# Usage: ./deploy.sh [--skip-build] [--skip-frontend]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../../.." && pwd)}"
source "$REPO_ROOT/orchestration/shared/logger.sh"
source "$REPO_ROOT/orchestration/shared/load-env.sh"

# Parse command line arguments
SKIP_BUILD=false
SKIP_FRONTEND=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --skip-build)
            SKIP_BUILD=true
            shift
            ;;
        --skip-frontend)
            SKIP_FRONTEND=true
            shift
            ;;
        *)
            log_error "Unknown option: $1"
            log_info "Usage: $0 [--skip-build] [--skip-frontend]"
            exit 1
            ;;
    esac
done

main() {
    log_step "Starting AWS ECS deployment"
    
    # Step 1: Check AWS credentials
    log_step "Substep 1/4: Checking AWS credentials"
    "$REPO_ROOT/run_scripts/main_application_scripts/aws/check-aws-credentials.sh" || exit 1
    
    # Step 2: Build and push to ECR
    if [ "$SKIP_BUILD" = false ]; then
        log_step "Substep 2/4: Building and pushing Docker image to ECR"
        "$REPO_ROOT/run_scripts/main_application_scripts/aws/shared/build-push-ecr.sh" || exit 1
    else
        log_info "Substep 2/4: Skipping ECR build/push (--skip-build flag set)"
    fi
    
    # Step 3: Deploy frontend
    if [ "$SKIP_FRONTEND" = false ]; then
        log_step "Substep 3/4: Deploying frontend to S3"
        # Ensure frontend is built
        if [ ! -d "$REPO_ROOT/module_app_core/frontend/dist" ]; then
            log_info "Building frontend first..."
            cd "$REPO_ROOT/module_app_core/frontend"
            if [ ! -d "node_modules" ]; then
                npm install
            fi
            npm run build
        fi
        "$REPO_ROOT/run_scripts/main_application_scripts/aws/shared/deploy-frontend.sh" || exit 1
    else
        log_info "Substep 3/4: Skipping frontend deployment (--skip-frontend flag set)"
    fi
    
    # Step 4: Infrastructure setup reminder
    log_step "Substep 4/4: Infrastructure setup"
    log_warning "ECS infrastructure setup is not fully automated yet"
    log_info "You need to set up (manually or via Terraform):"
    log_info "  - VPC and subnets"
    log_info "  - Aurora PostgreSQL cluster"
    log_info "  - ECS cluster"
    log_info "  - ECS task definition"
    log_info "  - ECS service"
    log_info "  - Application Load Balancer"
    log_info "  - Security groups"
    log_info "  - IAM roles"
    log_info ""
    log_info "Or use Terraform: ./run_scripts/aws/terraform/deploy.sh"
    
    log_success "ECS deployment preparation complete!"
    log_info "Next steps:"
    log_info "  1. Set up infrastructure (see above)"
    log_info "  2. Update ECS task definition with ECR image URI"
    log_info "  3. Create/update ECS service"
}

main "$@"

