#!/bin/bash
# Deploy application manifests to local Kubernetes
# Usage: ./deploy-app.sh [minikube|kind|docker-desktop]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../../.." && pwd)}"
source "$REPO_ROOT/run_scripts/shared/logger.sh"
source "$REPO_ROOT/run_scripts/shared/load-env.sh"

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

# Use the same helper script as AWS deployment
"$REPO_ROOT/run_scripts/main_application_scripts/aws/shared/helpers/kubernetes-manifests.sh" || {
  log_error "Failed to generate Kubernetes manifests"
  exit 1
}

# Apply manifests
log_info "Applying Kubernetes manifests..."
kubectl apply -f "$REPO_ROOT/infra/k8s/configmap-generated.yaml"
kubectl apply -f "$REPO_ROOT/infra/k8s/secret.yaml"
kubectl apply -f "$REPO_ROOT/infra/k8s/deployment.yaml"
kubectl apply -f "$REPO_ROOT/infra/k8s/service.yaml"
kubectl apply -f "$REPO_ROOT/infra/k8s/ingress.yaml"

log_success "Application deployed to local Kubernetes!"
log_info "Waiting for pods to be ready..."
kubectl wait --for=condition=ready pod -l app=fru-api -n "$NAMESPACE" --timeout=5m || {
  log_warning "Some pods may not be ready yet. Check with: kubectl get pods -n $NAMESPACE"
}

kubectl get pods -n "$NAMESPACE"
kubectl get svc -n "$NAMESPACE"
kubectl get ingress -n "$NAMESPACE"

