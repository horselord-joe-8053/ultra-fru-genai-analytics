# AWS Load Balancer Controller Installation

## Problem Identified

The AWS Load Balancer Controller is **NOT installed** in the EKS cluster. This is why:
- The Ingress resource exists with correct annotations
- But no ALB is being created
- The Ingress ADDRESS field remains empty

## Solution

The AWS Load Balancer Controller must be installed manually or via automation. According to the EKS module README, it should be installed after cluster creation.

## Installation Steps

### Option 1: Manual Installation (Quick Fix)

```bash
# 1. Install CRDs
kubectl apply -k "https://github.com/aws/eks-charts/stable/aws-load-balancer-controller/crds?ref=master"

# 2. Add EKS Helm repo (if not already added)
helm repo add eks https://aws.github.io/eks-charts
helm repo update

# 3. Create IAM Service Account (if not exists)
# Note: The EKS Terraform module should have created the IAM role for IRSA
# Check if service account exists first

# 4. Install AWS Load Balancer Controller via Helm
helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  --namespace kube-system \
  --set clusterName=fru-dev-cluster \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set region=us-east-1
```

### Option 2: Automated Installation (Terraform/Helm Provider)

We should add this to the EKS Terraform module using the Helm provider:

```hcl
# In infra/terraform/providers/aws/modules/eks/main.tf

# Helm provider for AWS Load Balancer Controller
data "helm_repository" "eks" {
  name = "eks"
  url  = "https://aws.github.io/eks-charts"
}

resource "helm_release" "aws_load_balancer_controller" {
  name       = "aws-load-balancer-controller"
  repository = data.helm_repository.eks.url
  chart      = "aws-load-balancer-controller"
  namespace  = "kube-system"
  version    = "1.6.0"  # Check for latest version

  set {
    name  = "clusterName"
    value = aws_eks_cluster.main.name
  }

  set {
    name  = "serviceAccount.create"
    value = "false"
  }

  set {
    name  = "serviceAccount.name"
    value = "aws-load-balancer-controller"
  }

  set {
    name  = "region"
    value = var.aws_region
  }

  depends_on = [
    aws_eks_cluster.main,
    aws_iam_role.aws_load_balancer_controller  # Need to create this IAM role for IRSA
  ]
}
```

## Required IAM Setup

The controller needs an IAM role with permissions to create/manage ALBs. This should use IRSA (IAM Roles for Service Accounts).

### IAM Role for Service Account

```hcl
# In infra/terraform/providers/aws/modules/eks/main.tf

# IAM role for AWS Load Balancer Controller
resource "aws_iam_role" "aws_load_balancer_controller" {
  name = "${var.project_name}-${var.environment}-aws-load-balancer-controller"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = aws_iam_openid_connect_provider.eks.arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${replace(aws_eks_cluster.main.identity[0].oidc[0].issuer, "https://", "")}:sub" = "system:serviceaccount:kube-system:aws-load-balancer-controller"
          "${replace(aws_eks_cluster.main.identity[0].oidc[0].issuer, "https://", "")}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })
}

# Attach AWS Load Balancer Controller policy
resource "aws_iam_role_policy_attachment" "aws_load_balancer_controller" {
  policy_arn = "arn:aws:iam::aws:policy/ElasticLoadBalancingFullAccess"  # Or create custom policy with least privilege
  role       = aws_iam_role.aws_load_balancer_controller.name
}

# Kubernetes Service Account annotation
resource "kubernetes_service_account" "aws_load_balancer_controller" {
  metadata {
    name      = "aws-load-balancer-controller"
    namespace = "kube-system"
    annotations = {
      "eks.amazonaws.com/role-arn" = aws_iam_role.aws_load_balancer_controller.arn
    }
  }
}
```

## Verification

After installation, verify:

```bash
# Check controller pod is running
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller

# Check controller logs
kubectl logs -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller

# Re-check Ingress (should start provisioning ALB)
kubectl get ingress -n default fru-api-ingress

# Watch Ingress events
kubectl describe ingress -n default fru-api-ingress
```

## Expected Timeline

After controller installation:
- Controller starts: ~30 seconds
- ALB provisioning begins: Immediately when Ingress is processed
- ALB becomes ready: 5-10 minutes
- Ingress ADDRESS populated: When ALB is ready

## Next Steps

1. **Immediate**: Install controller manually (Option 1)
2. **Short-term**: Add controller installation to Terraform (Option 2)
3. **Long-term**: Include in deployment automation scripts

## Current Status

- ❌ AWS Load Balancer Controller: NOT INSTALLED
- ✅ Ingress resource: EXISTS (with correct annotations)
- ❌ ALB: NOT CREATED (because no controller to create it)
- ❌ CloudFront update: BLOCKED (no ALB DNS available)

