#!/bin/bash
# Install AWS Load Balancer Controller with IRSA
# This script creates the IAM role, service account, and installs the controller

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../../../../.." && pwd)}"
source "$REPO_ROOT/run_scripts/shared/logger.sh"

CLUSTER_NAME="${1:-fru-dev-cluster}"
NAMESPACE="${2:-kube-system}"
AWS_REGION="${AWS_REGION:-us-east-1}"
AWS_PROFILE="${AWS_PROFILE:-admin}"
ACCOUNT_ID=$(aws sts get-caller-identity --profile "$AWS_PROFILE" --query Account --output text)

log_step "Installing AWS Load Balancer Controller for cluster: $CLUSTER_NAME"

# Get OIDC issuer URL
log_info "Fetching OIDC issuer URL..."
OIDC_URL=$(aws eks describe-cluster --name "$CLUSTER_NAME" --profile "$AWS_PROFILE" --region "$AWS_REGION" --query "cluster.identity.oidc.issuer" --output text | sed 's|https://||')
if [ -z "$OIDC_URL" ]; then
    log_error "Failed to get OIDC issuer URL for cluster $CLUSTER_NAME"
    exit 1
fi
log_info "OIDC Issuer: $OIDC_URL"

# IAM Role name
ROLE_NAME="${CLUSTER_NAME}-aws-load-balancer-controller"
SERVICE_ACCOUNT_NAME="aws-load-balancer-controller"

# Check if role already exists
if aws iam get-role --role-name "$ROLE_NAME" --profile "$AWS_PROFILE" >/dev/null 2>&1; then
    log_info "IAM role $ROLE_NAME already exists, skipping creation"
else
    log_info "Creating IAM role: $ROLE_NAME"
    
    # Create IAM role with trust policy for IRSA
    cat > /tmp/trust-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::${ACCOUNT_ID}:oidc-provider/${OIDC_URL}"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "${OIDC_URL}:sub": "system:serviceaccount:${NAMESPACE}:${SERVICE_ACCOUNT_NAME}",
          "${OIDC_URL}:aud": "sts.amazonaws.com"
        }
      }
    }
  ]
}
EOF

    aws iam create-role \
        --role-name "$ROLE_NAME" \
        --assume-role-policy-document file:///tmp/trust-policy.json \
        --profile "$AWS_PROFILE" >/dev/null 2>&1 || {
        log_error "Failed to create IAM role"
        exit 1
    }
    rm /tmp/trust-policy.json
    log_success "IAM role created"
fi

# Attach AWS managed policy for Load Balancer Controller
log_info "Attaching IAM policy to role..."
aws iam attach-role-policy \
    --role-name "$ROLE_NAME" \
    --policy-arn "arn:aws:iam::aws:policy/ElasticLoadBalancingFullAccess" \
    --profile "$AWS_PROFILE" >/dev/null 2>&1 || {
    log_warning "Policy attachment failed (may already be attached)"
}

# Get role ARN
ROLE_ARN=$(aws iam get-role --role-name "$ROLE_NAME" --profile "$AWS_PROFILE" --query 'Role.Arn' --output text)
log_info "IAM Role ARN: $ROLE_ARN"

# Create Kubernetes service account with IRSA annotation
log_info "Creating Kubernetes service account..."
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1 || true

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: $SERVICE_ACCOUNT_NAME
  namespace: $NAMESPACE
  annotations:
    eks.amazonaws.com/role-arn: $ROLE_ARN
EOF

log_success "Service account created"

# Install AWS Load Balancer Controller via Helm
log_info "Installing AWS Load Balancer Controller via Helm..."

# Check if already installed
if helm list -n "$NAMESPACE" | grep -q aws-load-balancer-controller; then
    log_info "Controller already installed, upgrading..."
    helm upgrade aws-load-balancer-controller eks/aws-load-balancer-controller \
        --namespace "$NAMESPACE" \
        --set clusterName="$CLUSTER_NAME" \
        --set serviceAccount.create=false \
        --set serviceAccount.name="$SERVICE_ACCOUNT_NAME" \
        --set region="$AWS_REGION" \
        --wait \
        --timeout 5m 2>&1 || {
        log_error "Helm upgrade failed"
        exit 1
    }
else
    helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
        --namespace "$NAMESPACE" \
        --set clusterName="$CLUSTER_NAME" \
        --set serviceAccount.create=false \
        --set serviceAccount.name="$SERVICE_ACCOUNT_NAME" \
        --set region="$AWS_REGION" \
        --wait \
        --timeout 5m 2>&1 || {
        log_error "Helm install failed"
        exit 1
    }
fi

log_success "AWS Load Balancer Controller installed successfully!"
log_info "Checking controller status..."
sleep 5
kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=aws-load-balancer-controller || true

