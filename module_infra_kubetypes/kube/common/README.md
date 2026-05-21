# Kubernetes Manifests for FRU API

This directory contains Kubernetes manifests for deploying the FRU API to EKS.

## Files

- **templates/deployment.template.yaml** - Kubernetes Deployment template for the API backend
- **templates/configmap.template.yaml** - Non-sensitive configuration template (database host, AWS region, etc.)
- **templates/secret.template.yaml** - Template for sensitive data (passwords, API keys)
- **service.yaml** - ClusterIP Service to expose the API internally
- **ingress.yaml** - Optional Ingress for external access via ALB

## Prerequisites

1. **EKS Cluster** - Created via Terraform or eksctl
2. **kubectl configured** - `aws eks update-kubeconfig --region <region> --name <cluster-name>`
3. **AWS Load Balancer Controller** - For Ingress (if using ingress.yaml)
4. **Terraform outputs** - Database endpoint and other infrastructure details

## Setup Instructions

### 1. Get Terraform Outputs

After deploying infrastructure with Terraform, get the required values:

```bash
cd module_infra_basic/aws/terra/environments/dev/infrastructure
terragrunt output -json > /tmp/terraform-outputs.json
```

Or manually get values:
```bash
# Database endpoint
PGHOST=$(terragrunt output -raw cluster_endpoint)

# Other values from .env or Terraform outputs
```

### 2. Create Secret from Template

The `templates/secret.template.yaml` file needs to be populated with actual values. You can:

**Option A: Use kubectl create secret directly**
```bash
kubectl create secret generic fru-secrets \
  --from-literal=db-password='<password>' \
  --from-literal=aws-access-key-id='<key>' \
  --from-literal=aws-secret-access-key='<secret>' \
  --from-literal=openai-api-key='<key>'
```

**Option B: Use envsubst to generate secret.yaml**
```bash
export PGPASSWORD="<password>"
export AWS_ACCESS_KEY_ID="<key>"
export AWS_SECRET_ACCESS_KEY="<secret>"
export OPENAI_API_KEY="<key>"

envsubst < templates/secret.template.yaml > generated/secret-generated.yaml
kubectl apply -f generated/secret-generated.yaml
```

**Option C: Use AWS Secrets Manager CSI Driver** (recommended for production)
- Install AWS Secrets Manager CSI driver
- Mount secrets directly from AWS Secrets Manager
- No need for secret.yaml

### 3. Update ConfigMap

The `templates/configmap.template.yaml` uses environment variable substitution. Update it with actual values:

**Option A: Use envsubst**
```bash
export PGHOST="<aurora-endpoint>"
export PGUSER="postgres"
export AWS_REGION="us-east-1"
export AWS_BEDROCK_INFERENCE_PROFILE_ID="us.anthropic.claude-3-5-haiku-20241022-v1:0"
export AWS_BEDROCK_MODEL_ID="anthropic.claude-3-haiku-20240307-v1:0"

envsubst < templates/configmap.template.yaml > generated/configmap-generated.yaml
kubectl apply -f generated/configmap-generated.yaml
```

**Option B: Edit manually**
```bash
kubectl edit configmap fru-config
```

### 4. Deploy Manifests

The `run_scripts/aws/eks/deploy.sh` script will automatically:
1. Generate manifests from templates in `templates/` directory
2. Substitute `${CONTAINER_IMAGE}` in deployment template
3. Apply all generated files from `generated/` directory and non-template files from root
4. Verify deployment status
5. Clean up `generated/` directory after successful apply

Or manually:
```bash
# Generate from templates
envsubst < templates/configmap.template.yaml > generated/configmap-generated.yaml
envsubst < templates/secret.template.yaml > generated/secret-generated.yaml
envsubst < templates/deployment.template.yaml > generated/deployment-generated.yaml

# Apply in order
kubectl apply -f generated/configmap-generated.yaml
kubectl apply -f generated/secret-generated.yaml
kubectl apply -f generated/deployment-generated.yaml
kubectl apply -f service.yaml
kubectl apply -f ingress.yaml  # Optional
```

## Environment Variables

### Required from Terraform Outputs
- `PGHOST` - Aurora cluster endpoint (from `terragrunt output cluster_endpoint`)
- `PGUSER` - Database username (from `terragrunt output master_username`)

### Required from .env or Secrets Manager
- `PGPASSWORD` - Database password
- `AWS_ACCESS_KEY_ID` - Bedrock admin access key
- `AWS_SECRET_ACCESS_KEY` - Bedrock admin secret key
- `OPENAI_API_KEY` - OpenAI API key

### Optional (with defaults)
- `AWS_REGION` - Default: us-east-1
- `AWS_BEDROCK_INFERENCE_PROFILE_ID` - Inference profile ID for Claude 3.5 (optional)
- `AWS_BEDROCK_MODEL_ID` - Default: anthropic.claude-3-haiku-20240307-v1:0
- `OPENAI_EMBED_MODEL` - Default: text-embedding-3-small
- `USE_AGENT_QUERY` - Default: false
- `LOG_LEVEL` - Default: INFO

## Integration with deploy.sh

The `run_scripts/aws/eks/deploy.sh` script:
1. Searches for manifests in this directory (`module_infra_kubetypes/kube/common/`)
2. Substitutes `${CONTAINER_IMAGE}` with the actual ECR image URI
3. Applies all YAML files
4. Verifies deployment

## Production Recommendations

1. **Use AWS Secrets Manager CSI Driver** instead of Kubernetes Secrets
2. **Use IAM Roles for Service Accounts (IRSA)** for AWS credentials instead of access keys
3. **Use External Secrets Operator** to sync Secrets Manager secrets to Kubernetes
4. **Enable Pod Security Policies** or Pod Security Standards
5. **Set resource limits** appropriately (already included in deployment.yaml)
6. **Use Horizontal Pod Autoscaler** for auto-scaling
7. **Enable network policies** for pod-to-pod communication

## Troubleshooting

```bash
# Check pods
kubectl get pods -l app=fru-api

# Check logs
kubectl logs -l app=fru-api --tail=100

# Check service
kubectl get svc fru-api

# Check ingress
kubectl get ingress fru-api-ingress

# Describe pod for events
kubectl describe pod <pod-name>

# Check configmap
kubectl get configmap fru-config -o yaml

# Check secret (values are base64 encoded)
kubectl get secret fru-secrets -o yaml
```

