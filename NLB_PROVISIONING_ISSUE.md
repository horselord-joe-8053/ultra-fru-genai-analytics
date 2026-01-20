# NLB Provisioning Issue - Root Cause

## Problem

NLB is stuck in `<pending>` state for 5+ minutes. Events show:
- ✅ LoadBalancer was created 54 minutes ago
- ❌ LoadBalancer was deleted 13 minutes ago  
- ⏳ Service recreated 5 minutes ago, but NLB still pending

## Root Causes

### 1. Missing Subnet Tags (Most Likely)

**EKS requires subnets to be tagged** for LoadBalancer provisioning:

**Public Subnets** (for internet-facing LoadBalancers):
```bash
kubernetes.io/role/elb = "1"
kubernetes.io/cluster/<cluster-name> = "shared" or "owned"
```

**Private Subnets** (for internal LoadBalancers):
```bash
kubernetes.io/role/internal-elb = "1"
kubernetes.io/cluster/<cluster-name> = "shared" or "owned"
```

**Check**:
```bash
aws ec2 describe-tags --filters "Name=resource-id,Values=<subnet-id>" \
  --query 'Tags[?contains(Key, `kubernetes`)]'
```

**Fix**: Tag subnets with required tags.

### 2. Missing IAM Permissions

**EKS Cluster Role** needs ELB permissions:
- `elasticloadbalancing:CreateLoadBalancer`
- `elasticloadbalancing:DescribeLoadBalancers`
- `elasticloadbalancing:ModifyLoadBalancerAttributes`
- `elasticloadbalancing:SetLoadBalancerPoliciesOfListener`
- `ec2:DescribeAccountAttributes`
- `ec2:DescribeInternetGateways`
- `ec2:DescribeVpcs`
- `ec2:DescribeSubnets`
- `ec2:DescribeSecurityGroups`
- `ec2:DescribeInstances`
- `ec2:DescribeNetworkInterfaces`
- `ec2:DescribeTags`
- `ec2:CreateTags`
- `ec2:AuthorizeSecurityGroupIngress`
- `ec2:RevokeSecurityGroupIngress`

**Check**:
```bash
aws iam list-attached-role-policies --role-name <cluster-role>
aws iam list-role-policies --role-name <cluster-role>
```

**Fix**: Attach `AmazonEKSClusterPolicy` (should already be attached) or add custom policy.

### 3. Subnet Configuration

**NLB requires**:
- At least 2 subnets in different AZs
- Subnets must be in the same VPC as EKS cluster
- For internet-facing NLB: Subnets must have route to Internet Gateway

**Check**:
```bash
aws eks describe-cluster --name <cluster-name> --query 'cluster.resourcesVpcConfig.subnetIds'
aws ec2 describe-subnets --subnet-ids <subnet-ids> --query 'Subnets[*].{SubnetId:SubnetId,AvailabilityZone:AvailabilityZone,MapPublicIpOnLaunch:MapPublicIpOnLaunch}'
```

## Solution

### Option 1: Tag Subnets (Recommended)

```bash
# Get cluster name and subnets
CLUSTER_NAME="fru-dev-cluster"
SUBNETS=$(aws eks describe-cluster --name $CLUSTER_NAME --query 'cluster.resourcesVpcConfig.subnetIds' --output text)

# Tag each subnet
for subnet in $SUBNETS; do
  # Tag for cluster
  aws ec2 create-tags \
    --resources $subnet \
    --tags Key=kubernetes.io/cluster/$CLUSTER_NAME,Value=shared
  
  # Tag for ELB (public subnets)
  aws ec2 create-tags \
    --resources $subnet \
    --tags Key=kubernetes.io/role/elb,Value=1
done
```

### Option 2: Use Terraform to Tag Subnets

Add to `infra/terraform/providers/aws/modules/eks/main.tf`:

```hcl
# Tag subnets for LoadBalancer support
resource "aws_ec2_tag" "subnet_cluster_tag" {
  for_each = toset(var.public_subnet_ids)
  
  resource_id = each.value
  key         = "kubernetes.io/cluster/${var.project_name}-${var.environment}-cluster"
  value       = "shared"
}

resource "aws_ec2_tag" "subnet_elb_tag" {
  for_each = toset(var.public_subnet_ids)
  
  resource_id = each.value
  key         = "kubernetes.io/role/elb"
  value       = "1"
}
```

### Option 3: Check IAM Permissions

Verify cluster role has ELB permissions:

```bash
CLUSTER_ROLE=$(aws eks describe-cluster --name fru-dev-cluster --query 'cluster.roleArn' --output text | awk -F'/' '{print $NF}')
aws iam get-role-policy --role-name $CLUSTER_ROLE --policy-name <policy-name>
```

## Immediate Fix

**Tag subnets now**:

```bash
cd /Users/jameswang9311/Documents/My_PJs/fru-genai-analytics-all

CLUSTER_NAME="fru-dev-cluster"
SUBNETS=$(aws eks describe-cluster --name $CLUSTER_NAME --region us-east-1 --profile admin --query 'cluster.resourcesVpcConfig.subnetIds' --output text)

for subnet in $SUBNETS; do
  echo "Tagging subnet: $subnet"
  aws ec2 create-tags \
    --resources $subnet \
    --tags Key=kubernetes.io/cluster/$CLUSTER_NAME,Value=shared \
    --profile admin --region us-east-1
  
  aws ec2 create-tags \
    --resources $subnet \
    --tags Key=kubernetes.io/role/elb,Value=1 \
    --profile admin --region us-east-1
done

# Then delete and recreate service
kubectl delete svc fru-api
kubectl apply -f infra/k8s/service.yaml
```

## Verification

After tagging, check:
```bash
# Check tags
aws ec2 describe-tags --filters "Name=resource-id,Values=<subnet-id>" --query 'Tags[?contains(Key, `kubernetes`)]'

# Check service
kubectl get svc fru-api -w

# Should see EXTERNAL-IP populated within 2-3 minutes
```

