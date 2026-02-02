#!/bin/bash
# Main local deployment script
# Usage: ./deploy.sh [minikube|kind|docker-desktop]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
source "$REPO_ROOT/orchestration/common/logger.sh"

K8S_TYPE="${1:-minikube}"

log_step "=== Local Kubernetes Deployment ==="
log_info "Kubernetes Type: $K8S_TYPE"

# 1. Setup local Kubernetes (if needed)
log_info "Step 1: Setting up local Kubernetes..."
"$SCRIPT_DIR/kube/setup.sh" "$K8S_TYPE"

# 2. Install NGINX Ingress
log_info "Step 2: Installing NGINX Ingress Controller..."
"$SCRIPT_DIR/kube/install-ingress.sh" "$K8S_TYPE"

# 3. Build application image (for local registry)
log_info "Step 3: Building application image..."
if [ "$K8S_TYPE" = "minikube" ]; then
  log_info "Using minikube's Docker daemon..."
  eval $(minikube docker-env)
  docker build -t fru-api:local -f "$REPO_ROOT/module_app_core/pack_with_docker/Dockerfile.api" "$REPO_ROOT" || {
    log_error "Failed to build Docker image"
    exit 1
  }
elif [ "$K8S_TYPE" = "kind" ]; then
  log_info "Building image for kind..."
  docker build -t fru-api:local -f "$REPO_ROOT/module_app_core/pack_with_docker/Dockerfile.api" "$REPO_ROOT" || {
    log_error "Failed to build Docker image"
    exit 1
  }
  kind load docker-image fru-api:local --name fru-local || {
    log_error "Failed to load image into kind cluster"
    exit 1
  }
else
  log_info "Building image for Docker Desktop..."
  docker build -t fru-api:local -f "$REPO_ROOT/module_app_core/pack_with_docker/Dockerfile.api" "$REPO_ROOT" || {
    log_error "Failed to build Docker image"
    exit 1
  }
fi

log_success "Docker image built: fru-api:local"

# 4. Update deployment.yaml to use local image
log_info "Step 4: Updating deployment to use local image..."
# Note: This assumes deployment.yaml uses an environment variable or we patch it
# For now, we'll rely on imagePullPolicy: IfNotPresent or Never

# 5. Deploy application
log_info "Step 5: Deploying application..."
"$SCRIPT_DIR/deploy-app.sh" "$K8S_TYPE"

# 6. Show access information
log_info ""
log_success "=== Deployment Complete ==="
log_info "Access methods:"
case "$K8S_TYPE" in
  minikube)
    log_info "  Option 1: LoadBalancer (requires 'minikube tunnel' running)"
    log_info "    Run: minikube tunnel"
    log_info "    Then: http://localhost"
    log_info ""
    log_info "  Option 2: NodePort"
    NODEPORT=$(kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.spec.ports[?(@.port==80)].nodePort}' 2>/dev/null || echo "")
    if [ -n "$NODEPORT" ]; then
      MINIKUBE_IP=$(minikube ip 2>/dev/null || echo "localhost")
      log_info "    Access via: http://$MINIKUBE_IP:$NODEPORT"
    fi
    log_info ""
    log_info "  Option 3: Port Forward"
    log_info "    kubectl port-forward -n ingress-nginx svc/ingress-nginx-controller 8080:80"
    log_info "    Then: http://localhost:8080"
    ;;
  kind)
    NODEPORT=$(kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.spec.ports[?(@.port==80)].nodePort}' 2>/dev/null || echo "")
    if [ -n "$NODEPORT" ]; then
      log_info "  NodePort: http://localhost:$NODEPORT"
    fi
    log_info ""
    log_info "  Port Forward: kubectl port-forward -n ingress-nginx svc/ingress-nginx-controller 8080:80"
    log_info "  Then: http://localhost:8080"
    ;;
  docker-desktop)
    EXTERNAL_IP=$(kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
    if [ -n "$EXTERNAL_IP" ] && [ "$EXTERNAL_IP" != "<pending>" ] && [ "$EXTERNAL_IP" != "null" ]; then
      log_info "  LoadBalancer: http://$EXTERNAL_IP"
    else
      log_info "  LoadBalancer pending. Use port-forward:"
      log_info "    kubectl port-forward -n ingress-nginx svc/ingress-nginx-controller 8080:80"
      log_info "    Then: http://localhost:8080"
    fi
    ;;
esac

log_info ""
log_info "Test endpoints:"
log_info "  Health: curl http://localhost/health"
log_info "  Query: curl http://localhost/query/stream?query=test"
log_info "  Analytics: curl http://localhost/analytics"

