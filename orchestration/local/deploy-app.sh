#!/bin/bash
# Deploy application manifests to local Kubernetes
# Usage: ./deploy-app.sh [minikube|kind|docker-desktop]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
source "$REPO_ROOT/lib/logger.sh"
source "$REPO_ROOT/orchestration/common/env/load-env.sh"

K8S_TYPE="${1:-minikube}"
NAMESPACE="${2:-default}"

log_step "Deploying application to local Kubernetes ($K8S_TYPE)"

# Ensure Kubernetes context
case "$K8S_TYPE" in
  minikube) kubectl config use-context minikube ;;
  kind) kubectl config use-context kind-fru-local ;;
  docker-desktop) kubectl config use-context docker-desktop ;;
esac

# Load environment variables
load_env_file 2>/dev/null || true

# Set local-specific environment variables
export PGHOST="${PGHOST:-localhost}"
export PGUSER="${PGUSER:-postgres}"
export PGPASSWORD="${PGPASSWORD:-postgres}"
export PGDATABASE="${PGDATABASE:-fru_db}"
export LOG_LEVEL="${LOG_LEVEL:-DEBUG}"
export ALLOWED_ORIGINS="${ALLOWED_ORIGINS:-http://localhost:3000,http://localhost:8080,http://localhost}"
export ENABLE_ANALYTICS_SCHEDULER="${ENABLE_ANALYTICS_SCHEDULER:-false}"
export ANALYTICS_SCHEDULER_INTERVAL_SECONDS="${ANALYTICS_SCHEDULER_INTERVAL_SECONDS:-300}"

log_info "Environment variables:"
log_info "  PGHOST: $PGHOST"
log_info "  PGUSER: $PGUSER"
log_info "  PGDATABASE: $PGDATABASE"
log_info "  LOG_LEVEL: $LOG_LEVEL"
log_info "  ALLOWED_ORIGINS: $ALLOWED_ORIGINS"

# Generate ConfigMap and Secret
log_info "Generating Kubernetes manifests..."

# Source the helper to get generate_kubernetes_manifests function
source "$REPO_ROOT/module_infra_kubetypes/kube/aws/helpers/kubernetes-manifests.sh"

# Generate all manifests (including namespace, ingress, service)
if ! generate_kubernetes_manifests "$REPO_ROOT/module_infra_kubetypes/kube/common"; then
  log_error "Failed to generate Kubernetes manifests"
  exit 1
fi

# Apply manifests
log_info "Applying Kubernetes manifests..."

# Apply generated manifests
kubectl apply -f "$REPO_ROOT/module_infra_kubetypes/kube/common/generated/namespace-generated.yaml" 2>/dev/null || true
kubectl apply -f "$REPO_ROOT/module_infra_kubetypes/kube/common/generated/configmap-generated.yaml"
kubectl apply -f "$REPO_ROOT/module_infra_kubetypes/kube/common/generated/secret-generated.yaml"
kubectl apply -f "$REPO_ROOT/module_infra_kubetypes/kube/common/generated/deployment-generated.yaml"
kubectl apply -f "$REPO_ROOT/module_infra_kubetypes/kube/common/generated/service-generated.yaml"
kubectl apply -f "$REPO_ROOT/module_infra_kubetypes/kube/common/generated/ingress-generated.yaml"

log_success "Application deployed to local Kubernetes!"
log_info "Waiting for pods to be ready..."
kubectl wait --for=condition=ready pod -l app=fru-api -n "$NAMESPACE" --timeout=5m || {
  log_warning "Some pods may not be ready yet. Check with: kubectl get pods -n $NAMESPACE"
}

kubectl get pods -n "$NAMESPACE"
kubectl get svc -n "$NAMESPACE"
kubectl get ingress -n "$NAMESPACE"

