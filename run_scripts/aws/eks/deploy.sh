#!/bin/bash
# Main EKS deployment orchestrator
# This script orchestrates the full EKS deployment process
# Usage: ./deploy.sh [--skip-build] [--skip-frontend] [--manifests-dir <path>]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
source "$SCRIPT_DIR/../../common/logger.sh"
source "$SCRIPT_DIR/../../common/load-env.sh"

# Load environment variables early
load_env_file 2>/dev/null || true

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

# Helper function to check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Check kubectl installation and configuration
check_kubectl() {
    log_step "Checking kubectl installation and configuration"
    
    # Check if kubectl is installed
    if ! command_exists kubectl; then
        log_error "kubectl is not installed"
        log_info "Install with: brew install kubectl"
        return 1
    fi
    log_success "kubectl is installed"
    
    # Check if kubectl context is configured
    if ! kubectl config current-context >/dev/null 2>&1; then
        log_error "kubectl context is not configured"
        log_info "Configure kubectl context for your EKS cluster:"
        log_info "  aws eks update-kubeconfig --region <region> --name <cluster-name>"
        log_info "Or if using eksctl: eksctl utils write-kubeconfig --cluster <cluster-name>"
        return 1
    fi
    
    local current_context=$(kubectl config current-context)
    log_success "kubectl context is configured: $current_context"
    
    # Check if cluster is accessible
    log_info "Checking cluster accessibility..."
    if ! kubectl cluster-info >/dev/null 2>&1; then
        log_error "Cannot access EKS cluster"
        log_info "Verify your AWS credentials and cluster configuration"
        log_info "Try: kubectl cluster-info"
        return 1
    fi
    log_success "EKS cluster is accessible"
    
    return 0
}

# Find Kubernetes manifests directory
find_manifests_dir() {
    if [ -n "$MANIFESTS_DIR" ]; then
        if [ -d "$MANIFESTS_DIR" ]; then
            echo "$MANIFESTS_DIR"
            return 0
        else
            log_error "Manifests directory not found: $MANIFESTS_DIR"
            return 1
        fi
    fi
    
    # Try common locations
    local possible_dirs=(
        "$REPO_ROOT/infra/k8s"
        "$REPO_ROOT/infra/kubernetes"
        "$REPO_ROOT/k8s"
        "$REPO_ROOT/kubernetes"
    )
    
    for dir in "${possible_dirs[@]}"; do
        if [ -d "$dir" ]; then
            echo "$dir"
            return 0
        fi
    done
    
    return 1
}

# Generate ConfigMap and Secret from templates
generate_manifests() {
    local manifests_dir=$1
    
    log_info "Generating ConfigMap and Secret from templates..."
    
    # Load environment variables from .env
    load_env_file 2>/dev/null || true
    
    # Generate ConfigMap from template
    local configmap_template="$manifests_dir/configmap.yaml"
    local configmap_output="$manifests_dir/configmap-generated.yaml"
    
    if [ -f "$configmap_template" ]; then
        log_info "Generating ConfigMap from template..."
        if command_exists envsubst; then
            # Export all variables that might be in the template
            export PGHOST="${PGHOST:-}"
            export PGUSER="${PGUSER:-postgres}"
            export AWS_REGION="${AWS_REGION:-us-east-1}"
            export BEDROCK_MODEL_ID="${BEDROCK_MODEL_ID:-anthropic.claude-3-haiku-20240307-v1:0}"
            export OPENAI_EMBED_MODEL="${OPENAI_EMBED_MODEL:-text-embedding-3-small}"
            export USE_AGENT_QUERY="${USE_AGENT_QUERY:-false}"
            export LOG_LEVEL="${LOG_LEVEL:-INFO}"
            
            envsubst < "$configmap_template" > "$configmap_output"
            log_success "ConfigMap generated: configmap-generated.yaml"
        else
            log_warning "envsubst not found, using template as-is"
            cp "$configmap_template" "$configmap_output"
        fi
    fi
    
    # Generate Secret from template
    local secret_template="$manifests_dir/secret.yaml.template"
    local secret_output="$manifests_dir/secret.yaml"
    
    if [ -f "$secret_template" ]; then
        log_info "Generating Secret from template..."
        if command_exists envsubst; then
            # Export sensitive variables
            export PGPASSWORD="${PGPASSWORD:-}"
            export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-}"
            export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-}"
            export OPENAI_API_KEY="${OPENAI_API_KEY:-}"
            
            envsubst < "$secret_template" > "$secret_output"
            log_success "Secret generated: secret.yaml"
        else
            log_warning "envsubst not found, cannot generate secret from template"
            log_info "You'll need to create secret manually: kubectl create secret generic fru-secrets ..."
        fi
    fi
}

# Apply Kubernetes manifests
apply_manifests() {
    local manifests_dir=$1
    local container_image="${CONTAINER_IMAGE:-}"
    
    log_step "Applying Kubernetes manifests"
    
    # Generate ConfigMap and Secret from templates first
    generate_manifests "$manifests_dir"
    
    if [ -z "$container_image" ]; then
        log_warning "CONTAINER_IMAGE not set"
        log_info "Manifests will be applied without image substitution"
        log_info "Make sure your manifests reference the correct image"
    else
        log_info "Using container image: $container_image"
    fi
    
    # Find YAML files (exclude templates, prefer generated files)
    local yaml_files=()
    
    # Prefer generated files if they exist, otherwise use templates
    if [ -f "$manifests_dir/configmap-generated.yaml" ]; then
        yaml_files+=("$manifests_dir/configmap-generated.yaml")
    elif [ -f "$manifests_dir/configmap.yaml" ]; then
        yaml_files+=("$manifests_dir/configmap.yaml")
    fi
    
    if [ -f "$manifests_dir/secret.yaml" ]; then
        yaml_files+=("$manifests_dir/secret.yaml")
    fi
    
    # Add other YAML files (deployment, service, ingress, etc.)
    while IFS= read -r file; do
        local basename_file=$(basename "$file")
        # Skip templates and already-added files
        if [[ "$basename_file" != "configmap.yaml" && \
              "$basename_file" != "configmap-generated.yaml" && \
              "$basename_file" != "secret.yaml.template" && \
              "$basename_file" != "secret.yaml" && \
              "$basename_file" != ".gitignore" && \
              "$basename_file" != "README.md" ]]; then
            yaml_files+=("$file")
        fi
    done < <(find "$manifests_dir" \( -name "*.yaml" -o -name "*.yml" \) | sort)
    
    if [ ${#yaml_files[@]} -eq 0 ]; then
        log_warning "No YAML files found in $manifests_dir"
        return 0
    fi
    
    log_info "Found ${#yaml_files[@]} manifest file(s)"
    
    # Apply each manifest
    for yaml_file in "${yaml_files[@]}"; do
        log_info "Applying: $(basename "$yaml_file")"
        
        # If CONTAINER_IMAGE is set, substitute it in the manifest
        if [ -n "$container_image" ]; then
            # Use envsubst if available, otherwise use sed
            if command_exists envsubst; then
                export CONTAINER_IMAGE="$container_image"
                envsubst < "$yaml_file" | kubectl apply -f -
            else
                # Fallback to sed (simple substitution)
                sed "s|\${CONTAINER_IMAGE}|$container_image|g; s|<CONTAINER_IMAGE>|$container_image|g" "$yaml_file" | kubectl apply -f -
            fi
        else
            kubectl apply -f "$yaml_file"
        fi
    done
    
    log_success "Manifests applied successfully"
}

# Verify deployment status
verify_deployment() {
    log_step "Verifying deployment status"
    
    # Check pods
    log_info "Checking pod status..."
    if kubectl get pods >/dev/null 2>&1; then
        kubectl get pods
        local pending_pods=$(kubectl get pods --field-selector=status.phase!=Running,status.phase!=Succeeded 2>/dev/null | tail -n +2 | wc -l | tr -d ' ')
        if [ "$pending_pods" -gt 0 ]; then
            log_warning "Some pods are not running yet"
            log_info "Check status with: kubectl get pods"
        else
            log_success "All pods are running"
        fi
    else
        log_warning "No pods found (may be normal if manifests don't create pods yet)"
    fi
    
    # Check services
    log_info "Checking service status..."
    if kubectl get svc >/dev/null 2>&1; then
        kubectl get svc
    else
        log_info "No services found"
    fi
    
    # Check ingress (if applicable)
    log_info "Checking ingress status..."
    if kubectl get ingress >/dev/null 2>&1; then
        kubectl get ingress
    else
        log_info "No ingress found (may be normal)"
    fi
}

main() {
    log_step "Starting AWS EKS deployment"
    
    # Step 1: Check AWS credentials
    log_step "Step 1/5: Checking AWS credentials"
    "$SCRIPT_DIR/../check-aws-credentials.sh" || exit 1
    
    # Step 2: Check kubectl and cluster access
    log_step "Step 2/5: Checking kubectl and EKS cluster access"
    if ! check_kubectl; then
        log_error "kubectl check failed"
        exit 1
    fi
    
    # Step 3: Build and push to ECR
    if [ "$SKIP_BUILD" = false ]; then
        log_step "Step 3/5: Building and pushing Docker image to ECR"
        "$SCRIPT_DIR/../common_ecs_eks/build-push-ecr.sh" || exit 1
    else
        log_info "Step 3/5: Skipping ECR build/push (--skip-build flag set)"
    fi
    
    # Step 4: Deploy frontend
    if [ "$SKIP_FRONTEND" = false ]; then
        log_step "Step 4/5: Deploying frontend to S3"
        # Ensure frontend is built
        if [ ! -d "$REPO_ROOT/frontend/dist" ]; then
            log_info "Building frontend first..."
            cd "$REPO_ROOT/frontend"
            if [ ! -d "node_modules" ]; then
                npm install
            fi
            npm run build
        fi
        "$SCRIPT_DIR/../common_ecs_eks/deploy-frontend.sh" || exit 1
    else
        log_info "Step 4/5: Skipping frontend deployment (--skip-frontend flag set)"
    fi
    
    # Step 5: Apply Kubernetes manifests
    log_step "Step 5/5: Applying Kubernetes manifests"
    local manifests_dir
    if manifests_dir=$(find_manifests_dir); then
        log_info "Found manifests directory: $manifests_dir"
        apply_manifests "$manifests_dir"
        verify_deployment
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
