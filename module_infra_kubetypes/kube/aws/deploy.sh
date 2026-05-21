#!/bin/bash
# Main EKS deployment orchestrator
# This script orchestrates the full EKS deployment process
# Usage: ./deploy.sh [--skip-build] [--skip-frontend] [--manifests-dir <path>]
#   --skip-build: Skip ECR build/push; use IMAGE_TAG=latest (or set IMAGE_TAG/CONTAINER_IMAGE to override).
#
# NOTE: Unlike ECS, EKS deployment requires kubectl access to the cluster API server endpoint
# - ECS: Uses AWS APIs (public endpoints) - works from anywhere with AWS credentials, no VPC access needed
# - EKS: Uses kubectl - requires network access to API server (needs public endpoint or VPC access for private endpoint)
# - With public endpoint: Works from anywhere (still IAM-authenticated), pods remain private
# - With private endpoint: Requires EC2 runner/VPN inside VPC for kubectl access (adds complexity)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Resolve repo root. Prefer existing REPO_ROOT if set (from parent orchestrator).
# This script lives at module_infra_kubetypes/kube/aws/ so ../../.. = repo root.
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../../.." && pwd)}"
source "$REPO_ROOT/lib/logger.sh"
source "$REPO_ROOT/orchestration/common/env/load-env.sh"

# Use app venv when present so Python/pip and scripts (e.g. kubeconfig edit) use consistent deps
if [ -f "$REPO_ROOT/venv/bin/activate" ]; then
    set +u
    source "$REPO_ROOT/venv/bin/activate"
    set -u
fi

# Source helper scripts (module_infra_kubetypes/kube/aws/helpers and shared prepare-frontend)
source "$SCRIPT_DIR/helpers/check-kubectl.sh"
source "$SCRIPT_DIR/helpers/kubernetes-manifests.sh"
# source "$REPO_ROOT/run_scripts/main_application_scripts/aws/shared/helpers/prepare-frontend.sh"
source "$REPO_ROOT/orchestration/common/deploy/prepare-frontend.sh"
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
    log_step "Substep 1/6: Checking AWS credentials"
    "$REPO_ROOT/orchestration/aws/check-aws-credentials.sh" || exit 1
    
    # Step 2: Check kubectl and cluster access
    log_step "Substep 2/6: Checking kubectl and EKS cluster access"
    if ! check_kubectl_complete; then
        log_error "kubectl check failed"
        exit 1
    fi
    
    # Step 3: Build and push to ECR
    if [ "$SKIP_BUILD" = false ]; then
        log_step "Substep 3/6: Building and pushing Docker image to ECR"
        "$REPO_ROOT/module_infra_basic/aws/build-push-ecr.sh" || exit 1
    else
        log_info "Substep 3/6: Skipping ECR build/push (--skip-build flag set)"
        # When skipping build, default to tag 'latest' so deployment uses an image that exists in ECR.
        # Override by setting IMAGE_TAG (or CONTAINER_IMAGE) before running deploy.
        if [ -z "${IMAGE_TAG:-}" ] && [ -z "${CONTAINER_IMAGE:-}" ]; then
            export IMAGE_TAG="latest"
            log_info "Using IMAGE_TAG=latest for manifest apply (set IMAGE_TAG or CONTAINER_IMAGE to override)"
        fi
    fi
    
    # Step 4: Deploy frontend
    if [ "$SKIP_FRONTEND" = false ]; then
        log_step "Substep 4/6: Deploying frontend to S3"
        # Ensure frontend is built (using helper)
        if ! build_frontend_if_needed; then
            log_error "Frontend preparation failed"
            exit 1
        fi
        # Export so deploy-frontend.sh gets correct REPO_ROOT, ENVIRONMENT, CONTAINER_TYPE (for frontend-eks vs frontend-ecs and terragrunt output)
        export REPO_ROOT
        export ENVIRONMENT="${ENVIRONMENT:-dev}"
        export CONTAINER_TYPE="${CONTAINER_TYPE:-eks}"
        "$REPO_ROOT/module_infra_frontend/aws/deploy-frontend.sh" || exit 1
    else
        log_info "Substep 4/6: Skipping frontend deployment (--skip-frontend flag set)"
    fi
    
    # Step 4.5: Install NGINX Ingress Controller (provisions NLB so Ingress gets hostname)
    log_step "Substep 4.5/6: Installing NGINX Ingress Controller (EKS NLB)"
    "$SCRIPT_DIR/helpers/install-ingress-nginx-eks.sh" || exit 1
    
    # Step 5: Apply Kubernetes manifests
    log_step "Substep 5/6: Applying Kubernetes manifests"
    local manifests_dir
    if manifests_dir=$(find_manifests_directory); then
        log_info "Found manifests directory: $manifests_dir"
        
        # Get namespace from Terraform output (for CloudFront update)
        local environment="${ENVIRONMENT:-dev}"
        local terraform_dir="$REPO_ROOT/module_infra_kubetypes/kube/aws/terra/environments/$environment/eks"
        local namespace="default"  # Default fallback
        
        if [ -d "$terraform_dir" ] && command_exists terragrunt; then
            log_info "Fetching namespace from Terraform output..."
            if namespace_output=$(cd "$terraform_dir" && AWS_PROFILE="${AWS_PROFILE:-admin}" terragrunt output -raw namespace 2>/dev/null); then
                if [ -n "$namespace_output" ] && [ "$namespace_output" != "null" ]; then
                    namespace="$namespace_output"
                    log_info "Using namespace from Terraform: $namespace"
                else
                    log_warning "Namespace from Terraform is empty, using default"
                fi
            else
                log_warning "Could not fetch namespace from Terraform, using default"
            fi
        else
            log_warning "Terraform directory not found or terragrunt not available, using default namespace"
        fi
        
        apply_kubernetes_manifests "$manifests_dir"
        verify_kubernetes_deployment "$namespace"

        # After backend is healthy and ingress is applied, wire CloudFront to the EKS ALB
        # This updates the Terraform-managed CloudFront distribution so that /query, /query/stream,
        # and /analytics are routed to the ingress ALB instead of the old ALB/placeholder.
        # Get ingress name from Terraform output
        local ingress_name="fru-api-ingress"  # Default fallback
        if [ -d "$terraform_dir" ] && command_exists terragrunt; then
            if ingress_name_output=$(cd "$terraform_dir" && AWS_PROFILE="${AWS_PROFILE:-admin}" terragrunt output -raw ingress_name 2>/dev/null); then
                if [ -n "$ingress_name_output" ] && [ "$ingress_name_output" != "null" ]; then
                    ingress_name="$ingress_name_output"
                    log_info "Using ingress name from Terraform: $ingress_name"
                fi
            fi
        fi
        log_step "Substep 5b: Updating CloudFront to point API paths to the EKS Ingress ALB"
        "$SCRIPT_DIR/helpers/update-cloudfront-loadbalancer.sh" "$ingress_name" "$namespace" || exit 1
        
        # Phase 3: Post-deployment version verification
        if [ "$DRY_RUN" != "true" ]; then
            log_step "Substep 5c: Verifying deployment versions"
            source "$SCRIPT_DIR/helpers/verify-deployment-versions.sh"
            
            # Get expected versions
            local expected_backend=""
            if [ -n "${CONTAINER_IMAGE:-}" ]; then
                expected_backend=$(echo "$CONTAINER_IMAGE" | cut -d: -f2)
            fi
            
            local expected_frontend=""
            if [ -f "$REPO_ROOT/.frontend-version.txt" ]; then
                expected_frontend=$(cat "$REPO_ROOT/.frontend-version.txt" 2>/dev/null || echo "")
            fi
            
            # Get CloudFront domain from Terraform
            local cloudfront_domain=""
            if [ -d "$terraform_dir" ] && command_exists terragrunt; then
                cloudfront_domain=$(cd "$terraform_dir" && AWS_PROFILE="${AWS_PROFILE:-admin}" terragrunt output -raw cloudfront_domain_name 2>/dev/null || echo "")
                if [ "$cloudfront_domain" = "null" ] || [ -z "$cloudfront_domain" ]; then
                    cloudfront_domain=""
                fi
            fi
            
            # Get deployment name (default to fru-api)
            local deployment_name="fru-api"
            if [ -d "$terraform_dir" ] && command_exists terragrunt; then
                local deployment_name_output
                deployment_name_output=$(cd "$terraform_dir" && AWS_PROFILE="${AWS_PROFILE:-admin}" terragrunt output -raw deployment_name 2>/dev/null || echo "")
                if [ -n "$deployment_name_output" ] && [ "$deployment_name_output" != "null" ]; then
                    deployment_name="$deployment_name_output"
                fi
            fi
            
            if [ -n "$expected_backend" ] || [ -n "$expected_frontend" ]; then
                verify_deployment_versions "$expected_backend" "$expected_frontend" "$cloudfront_domain" "$namespace" "$deployment_name" || true
                # Don't fail deployment if verification has issues - these are warnings
            else
                log_info "Skipping version verification (expected versions not available)"
            fi
        fi
    else
        log_warning "Kubernetes manifests directory not found"
        log_info "Searched in:"
        log_info "  - module_infra_kubetypes/kube/common/"
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
        log_info "  module_infra_kubetypes/kube/common/"
        log_info "    ├── deployment.yaml"
        log_info "    ├── service.yaml"
        log_info "    ├── configmap.yaml"
        log_info "    └── ingress.yaml"
    log_info ""
        log_info "Reference CONTAINER_IMAGE in manifests using: \${CONTAINER_IMAGE} or <CONTAINER_IMAGE>"
    fi
    
    # Phase 5: Save deployment state
    if [ "$DRY_RUN" != "true" ]; then
        log_step "Saving deployment state"
        source "$REPO_ROOT/orchestration/common/deploy/save-deployment-state.sh"
        
        # Get versions
        local backend_version=""
        if [ -n "${CONTAINER_IMAGE:-}" ]; then
            backend_version=$(echo "$CONTAINER_IMAGE" | cut -d: -f2)
        fi
        
        local frontend_version=""
        if [ -f "$REPO_ROOT/.frontend-version.txt" ]; then
            frontend_version=$(cat "$REPO_ROOT/.frontend-version.txt" 2>/dev/null || echo "")
        fi
        
        # Get latest invalidation ID from log
        local invalidation_id=""
        if [ -f "$REPO_ROOT/.cloudfront-invalidations.log" ]; then
            invalidation_id=$(tail -1 "$REPO_ROOT/.cloudfront-invalidations.log" 2>/dev/null | cut -d'|' -f3 || echo "")
        fi
        
        local environment="${ENVIRONMENT:-dev}"
        local container_type="${CONTAINER_TYPE:-eks}"
        
        save_deployment_state "$environment" "$container_type" "$backend_version" "$frontend_version" "$invalidation_id" || true
    fi
    
    log_success "EKS deployment complete!"
    log_info "Next steps:"
    log_info "  1. Verify deployment: kubectl get pods,svc,ingress"
    log_info "  2. Check logs: kubectl logs -l app=fru-api"
    log_info "  3. Access service: kubectl port-forward svc/fru-api 5000:5000"
}

main "$@"
