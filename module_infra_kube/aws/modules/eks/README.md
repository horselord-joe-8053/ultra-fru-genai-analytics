# EKS Module

This module creates an Amazon EKS (Elastic Kubernetes Service) cluster with either Fargate profiles or managed node groups.

## Features

- EKS cluster with configurable Kubernetes version
- Support for Fargate (serverless) or managed node groups
- OIDC provider for IRSA (IAM Roles for Service Accounts)
- Secrets encryption with KMS
- Control plane logging
- Configurable endpoint access (private/public)
- Security groups for cluster and nodes

## Endpoint Access: EKS vs ECS

**Why EKS needs public endpoint (unlike ECS):**

- **ECS Deployment**: Uses AWS APIs (`ecs.amazonaws.com`) - public endpoints accessible from anywhere with AWS credentials. No VPC network access needed for deployment.

- **EKS Deployment**: Uses `kubectl` - direct network connection to Kubernetes API server endpoint. If endpoint is private (in VPC), `kubectl` from outside VPC cannot access it.

**Implications:**
- **ECS**: Works from anywhere (AWS APIs are public but authenticated)
- **EKS with public endpoint**: Works from anywhere (`kubectl` can reach API server, still authenticated via IAM)
- **EKS with private endpoint**: Requires EC2 runner/VPN inside VPC for `kubectl` access (adds complexity)

**Security Note:**
- Public endpoint is still secure: IAM authentication required, pods remain in private subnets
- Consider restricting `endpoint_public_access_cidrs` to specific IPs for additional security

## Usage

```hcl
module "eks" {
  source = "../eks"

  project_name      = "fru"
  environment       = "dev"
  aws_region        = "us-east-1"
  vpc_id            = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_subnet_ids
  public_subnet_ids  = module.vpc.public_subnet_ids

  cluster_version = "1.28"
  enable_fargate = true

  tags = {
    Environment = "dev"
    Project     = "FRU-GenAI"
  }
}
```

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|----------|
| project_name | Project name prefix | string | - | yes |
| environment | Environment (dev/prod) | string | - | yes |
| aws_region | AWS region | string | - | yes |
| vpc_id | VPC ID | string | - | yes |
| private_subnet_ids | Private subnet IDs | list(string) | - | yes |
| public_subnet_ids | Public subnet IDs | list(string) | - | yes |
| cluster_version | Kubernetes version | string | "1.28" | no |
| enable_fargate | Use Fargate instead of managed node groups | bool | true | no |
| node_group_instance_types | EC2 instance types for node groups | list(string) | ["t3.medium"] | no |
| node_group_desired_size | Desired node count | number | 2 | no |
| node_group_min_size | Minimum node count | number | 1 | no |
| node_group_max_size | Maximum node count | number | 3 | no |
| endpoint_private_access | Enable private API endpoint | bool | true | no |
| endpoint_public_access | Enable public API endpoint | bool | false | no |
| enabled_cluster_log_types | Control plane logging types | list(string) | ["api", "audit", "authenticator", "controllerManager", "scheduler"] | no |

## Outputs

| Name | Description |
|------|-------------|
| cluster_id | EKS cluster ID |
| cluster_name | EKS cluster name |
| cluster_arn | EKS cluster ARN |
| cluster_endpoint | EKS cluster API endpoint |
| cluster_oidc_issuer_url | OIDC issuer URL for IRSA |
| cluster_oidc_provider_arn | OIDC provider ARN |
| kubeconfig_command | Command to update kubeconfig |

## Fargate vs Managed Node Groups

### Fargate (Recommended for Dev)
- **Pros**: No node management, serverless, pay-per-use
- **Cons**: Slightly more expensive, less control
- **Use case**: Development, simple workloads

### Managed Node Groups
- **Pros**: More control, potentially cheaper for production
- **Cons**: Need to manage nodes, EC2 instances
- **Use case**: Production, workloads requiring specific instance types

## Post-Deployment

After deploying this module, you need to:

1. **Configure kubectl**:
   ```bash
   aws eks update-kubeconfig --region us-east-1 --name fru-dev-cluster --profile admin
   ```

2. **Install AWS Load Balancer Controller** (for ALB Ingress):
   ```bash
   kubectl apply -k "https://github.com/aws/eks-charts/stable/aws-load-balancer-controller/crds?ref=master"
   helm repo add eks https://aws.github.io/eks-charts
   helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
     --set clusterName=fru-dev-cluster \
     --set serviceAccount.create=false \
     --set serviceAccount.name=aws-load-balancer-controller
   ```

3. **Deploy Kubernetes manifests**:
   ```bash
   kubectl apply -f module_infra_kube/shared/
   ```

## Dependencies

- VPC with private and public subnets
- IAM permissions for EKS cluster and node group creation
- AWS Load Balancer Controller (installed after cluster creation)

