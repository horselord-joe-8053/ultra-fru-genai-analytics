#!/bin/bash
# Main EKS deployment orchestrator
# This script orchestrates the full EKS deployment process
# Usage: ./deploy.sh [--skip-build] [--skip-frontend] [--manifests-dir <path>]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../../.." && pwd)}"
source "$REPO_ROOT/run_scripts/shared/logger.sh"
source "$REPO_ROOT/run_scripts/shared/load-env.sh"

# Source helper scripts
source "$REPO_ROOT/run_scripts/main_application_scripts/aws/shared/helpers/check-kubectl.sh"
source "$REPO_ROOT/run_scripts/main_application_scripts/aws/shared/helpers/kubernetes-manifests.sh"
source "$REPO_ROOT/run_scripts/main_application_scripts/aws/shared/helpers/prepare-frontend.sh"

# Load environment variables early
load_env_file 2>/dev/null || true

# Check for dry-run mode (from parent script)
DRY_RUN="${DRY_RUN:-false}"

# Parse command line arguments
SKIP_BUILD=false
SKIP_FRONTEND=false
MANIFESTS_DIR=""

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
        --manifests-dir)
            MANIFESTS_DIR="$2"
            shift 2
            ;;
        *)
            log_error "Unknown option: $1"
            log_info "Usage: $0 [--skip-build] [--skip-frontend] [--manifests-dir <path>]"
            exit 1
            ;;
    esac
done

# Note: Helper functions are now sourced from:
# - check-kubectl.sh (check_kubectl_complete, check_kubectl_installation, etc.)
# - kubernetes-manifests.sh (find_manifests_directory, apply_kubernetes_manifests, verify_kubernetes_deployment, etc.)
# - prepare-frontend.sh (build_frontend_if_needed)

main() {
    log_step "Starting AWS EKS deployment"
    
    # Step 1: Check AWS credentials
    log_step "Substep 1/5: Checking AWS credentials"
    "$REPO_ROOT/run_scripts/main_application_scripts/aws/check-aws-credentials.sh" || exit 1
    
    # Step 2: Check kubectl and cluster access
    log_step "Substep 2/5: Checking kubectl and EKS cluster access"
    if ! check_kubectl_complete; then
        log_error "kubectl check failed"
        exit 1
    fi
    
    # Step 3: Build and push to ECR
    if [ "$SKIP_BUILD" = false ]; then
        log_step "Substep 3/5: Building and pushing Docker image to ECR"
        "$REPO_ROOT/run_scripts/main_application_scripts/aws/shared/build-push-ecr.sh" || exit 1
    else
        log_info "Substep 3/5: Skipping ECR build/push (--skip-build flag set)"
    fi
    
    # Step 4: Deploy frontend
    if [ "$SKIP_FRONTEND" = false ]; then
        log_step "Substep 4/5: Deploying frontend to S3"
        # Ensure frontend is built (using helper)
        if ! build_frontend_if_needed; then
            log_error "Frontend preparation failed"
            exit 1
        fi
        "$REPO_ROOT/run_scripts/main_application_scripts/aws/shared/deploy-frontend.sh" || exit 1
    else
        log_info "Substep 4/5: Skipping frontend deployment (--skip-frontend flag set)"
    fi
    
    # Step 5: Apply Kubernetes manifests
    log_step "Substep 5/5: Applying Kubernetes manifests"
    local manifests_dir
    if manifests_dir=$(find_manifests_directory); then
        log_info "Found manifests directory: $manifests_dir"
        apply_kubernetes_manifests "$manifests_dir"
        verify_kubernetes_deployment
    else
        log_warning "Kubernetes manifests directory not found"
        log_info "Searched in:"
        log_info "  - infra/k8s/"
        log_info "  - infra/kubernetes/"
        log_info "  - k8s/"
        log_info "  - kubernetes/"
        log_info ""
        log_info "To use a custom directory, use: --manifests-dir <path>"
        log_info ""
        log_info "Create Kubernetes manifests for your application:"
        log_info "  - Deployment: API backend pods"
        log_info "  - Service: Expose API internally"
        log_info "  - ConfigMap: Non-sensitive configuration"
        log_info "  - Secret: Sensitive data (or use AWS Secrets Manager)"
        log_info "  - Ingress: External access (optional)"
        log_info ""
        log_info "Example structure:"
        log_info "  infra/k8s/"
        log_info "    ├── deployment.yaml"
        log_info "    ├── service.yaml"
        log_info "    ├── configmap.yaml"
        log_info "    └── ingress.yaml"
    log_info ""
        log_info "Reference CONTAINER_IMAGE in manifests using: \${CONTAINER_IMAGE} or <CONTAINER_IMAGE>"
    fi
    
    log_success "EKS deployment complete!"
    log_info "Next steps:"
    log_info "  1. Verify deployment: kubectl get pods,svc,ingress"
    log_info "  2. Check logs: kubectl logs -l app=fru-api"
    log_info "  3. Access service: kubectl port-forward svc/fru-api 5000:5000"
}

main "$@"
