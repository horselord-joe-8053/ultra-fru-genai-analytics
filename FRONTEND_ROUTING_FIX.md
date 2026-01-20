# Frontend Routing Fix for EKS

## Problem
CloudFront is routing `/query` and `/analytics` to S3 (serving `index.html`) instead of the ALB backend because `alb_dns_name` is `null` for EKS deployments.

## Root Cause
- EKS uses Kubernetes Ingress Controller to create ALB (not Terraform)
- ALB DNS name is not known to Terraform at deployment time
- CloudFront needs ALB DNS name to route API requests

## Solution Options

### Option 1: Manual Update (Quick Fix)
1. Wait for Ingress ALB to provision (~5-10 minutes)
2. Get ALB DNS: `kubectl get ingress -n default fru-api-ingress -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'`
3. Update CloudFront distribution manually via AWS Console or CLI

### Option 2: Terraform Data Source (Recommended)
Use Terraform data source to fetch ALB DNS from Kubernetes Ingress after it's created:

```hcl
# In infra/terraform/providers/aws/modules/eks/main.tf
data "aws_lb" "eks_ingress_alb" {
  count = var.enable_fargate && var.alb_dns_name == null ? 1 : 0
  name = "k8s-default-fruapiingr" # Pattern: k8s-{namespace}-{ingress-name}
}

# Then pass to frontend module:
alb_dns_name = var.enable_fargate && var.alb_dns_name == null ? (length(data.aws_lb.eks_ingress_alb) > 0 ? data.aws_lb.eks_ingress_alb[0].dns_name : null) : var.alb_dns_name
```

### Option 3: Two-Stage Deployment
1. Deploy EKS + Ingress (wait for ALB)
2. Get ALB DNS from Ingress
3. Update Terraform variable and redeploy frontend

## Current Workaround
Frontend is accessible, but API routes (`/query`, `/analytics`) return HTML instead of API responses.

## Next Steps
1. Check if ALB is ready: `kubectl get ingress -n default fru-api-ingress`
2. If ADDRESS is populated, update CloudFront with ALB DNS
3. Or implement Option 2 for automatic detection

