#!/bin/bash
# Install NGINX Ingress Controller for local Kubernetes
# Usage: ./install-ingress.sh [minikube|kind|docker-desktop]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../../.." && pwd)}"  # kube -> local -> orchestration -> repo
source "$REPO_ROOT/lib/logger.sh"

K8S_TYPE="${1:-minikube}"

log_step "Installing NGINX Ingress Controller for $K8S_TYPE"

# Check Helm
if ! command -v helm >/dev/null 2>&1; then
  log_error "Helm not installed. Install via: brew install helm"
  exit 1
fi

# Add Helm repo
log_info "Adding NGINX Ingress Helm repository..."
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx >/dev/null 2>&1 || true
helm repo update >/dev/null 2>&1

# Determine values file
VALUES_FILE="$REPO_ROOT/module_infra_kubetypes/kube/common/ingress-nginx-values-local.yaml"

if [ ! -f "$VALUES_FILE" ]; then
  log_error "Helm values file not found: $VALUES_FILE"
  exit 1
fi

# Install NGINX Ingress
log_info "Installing NGINX Ingress Controller..."
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx \
  --create-namespace \
  --values "$VALUES_FILE" \
  --wait --timeout 5m

log_success "NGINX Ingress Controller installed"

# Get access method based on Kubernetes type
log_info "NGINX Ingress access information:"
case "$K8S_TYPE" in
  minikube)
    log_info "Option 1: Start minikube tunnel (for LoadBalancer support)"
    log_info "  Run: minikube tunnel"
    log_info "  Then access via: http://localhost"
    log_info ""
    log_info "Option 2: Use NodePort"
    NODEPORT=$(kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.spec.ports[?(@.port==80)].nodePort}' 2>/dev/null || echo "")
    if [ -n "$NODEPORT" ]; then
      MINIKUBE_IP=$(minikube ip 2>/dev/null || echo "localhost")
      log_info "  Access via: http://$MINIKUBE_IP:$NODEPORT"
    fi
    ;;
    
  kind)
    NODEPORT=$(kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.spec.ports[?(@.port==80)].nodePort}' 2>/dev/null || echo "")
    if [ -n "$NODEPORT" ]; then
      log_info "Access via NodePort: http://localhost:$NODEPORT"
    else
      log_info "Use port-forward: kubectl port-forward -n ingress-nginx svc/ingress-nginx-controller 8080:80"
    fi
    ;;
    
  docker-desktop)
    EXTERNAL_IP=$(kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
    if [ -n "$EXTERNAL_IP" ] && [ "$EXTERNAL_IP" != "<pending>" ]; then
      log_info "Access via LoadBalancer: http://$EXTERNAL_IP"
    else
      log_info "LoadBalancer pending. Use port-forward: kubectl port-forward -n ingress-nginx svc/ingress-nginx-controller 8080:80"
    fi
    ;;
esac

kubectl get svc -n ingress-nginx ingress-nginx-controller

