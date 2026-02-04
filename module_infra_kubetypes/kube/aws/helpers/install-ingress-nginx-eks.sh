#!/bin/bash
# Install NGINX Ingress Controller for EKS (AWS)
# ==============================================
# The controller's LoadBalancer Service provisions an NLB on AWS. The NGINX
# controller then updates Ingress resources' status with that NLB hostname,
# which CloudFront and validation scripts use for the API URL.
#
# Usage: run from EKS deploy flow, or standalone:
#   ./install-ingress-nginx-eks.sh
#
# Prerequisites: kubectl configured for the EKS cluster, Helm installed.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../../../.." && pwd)}"
source "$REPO_ROOT/orchestration/common/logger.sh"

log_step "Installing NGINX Ingress Controller for EKS (NLB)"

if ! command -v helm >/dev/null 2>&1; then
  log_error "Helm not installed. Install via: brew install helm"
  exit 1
fi

log_info "Adding NGINX Ingress Helm repository..."
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx >/dev/null 2>&1 || true
helm repo update >/dev/null 2>&1

VALUES_FILE="$REPO_ROOT/module_infra_kubetypes/kube/common/ingress-nginx-values-eks.yaml"
if [ ! -f "$VALUES_FILE" ]; then
  log_error "Helm values file not found: $VALUES_FILE"
  exit 1
fi

log_info "Installing NGINX Ingress Controller (LoadBalancer → NLB)..."
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx \
  --create-namespace \
  --values "$VALUES_FILE" \
  --wait --timeout 5m

log_success "NGINX Ingress Controller installed"
kubectl get svc -n ingress-nginx ingress-nginx-controller 2>/dev/null || true
