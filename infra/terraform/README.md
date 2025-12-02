# Terraform Infrastructure as Code

This directory contains Terraform modules and Terragrunt configurations for deploying the FRU project to AWS.

## Structure

```
infra/terraform/
├── modules/              # Reusable Terraform modules
│   ├── vpc/             # VPC, subnets, NAT gateways, VPC endpoints
│   ├── aurora/           # Aurora PostgreSQL cluster with pgvector
│   ├── iam/              # IAM roles (execution + runtime)
│   ├── secrets-manager/  # Secrets Manager for sensitive data
│   ├── ecs/              # ECS cluster, service, task definition
│   ├── alb/              # Application Load Balancer
│   ├── frontend/         # S3 + CloudFront for frontend
│   ├── infrastructure/   # Wrapper module (VPC + Aurora + IAM + Secrets)
│   └── application/      # Wrapper module (ECS + ALB + Frontend)
└── environments/         # Terragrunt environment configurations
    ├── terragrunt.hcl   # Root configuration
    ├── dev/
    │   ├── terragrunt.hcl
    │   ├── infrastructure/
    │   └── application/
    └── prod/
        ├── terragrunt.hcl
        ├── infrastructure/
        └── application/
```

## Security Best Practices

### IAM Role Separation

- **Execution Role**: Used by ECS service to start tasks
  - ECR: Pull container images
  - CloudWatch: Write logs
  - Secrets Manager: Read secrets for task definition

- **Runtime Role**: Assumed by running containers
  - Bedrock: Invoke models
  - Secrets Manager: Read secrets at runtime
  - RDS IAM Auth: Connect to Aurora (if enabled)

### Secrets Management

- **Never store secrets in environment variables**
- All sensitive data (OPENAI_API_KEY, PGPASSWORD) stored in Secrets Manager
- Secrets referenced in ECS task definition via `secrets` block
- Only non-sensitive values (PGHOST, PGPORT, PGDATABASE) as environment variables

### Database Authentication

- **IAM Database Authentication** (recommended for production)
  - No passwords needed
  - ECS tasks authenticate using IAM roles
  - More secure than password-based auth

- **Secrets Manager** (fallback)
  - Store password in Secrets Manager
  - Reference in ECS task definition
  - Rotate regularly

## Prerequisites

1. **Terraform** >= 1.5.0
   ```bash
   brew install terraform
   ```

2. **Terragrunt** >= 0.50.0
   ```bash
   brew install terragrunt
   ```

3. **AWS CLI** configured
   ```bash
   aws configure
   ```

4. **S3 Bucket for Terraform State**
   - Create an S3 bucket for storing Terraform state
   - Create a DynamoDB table for state locking
   - Set environment variables:
     ```bash
     export TF_STATE_BUCKET="fru-terraform-state-<account-id>"
     export TF_STATE_LOCK_TABLE="fru-terraform-locks"
     ```

## Usage

### Quick Start (Using Scripts)

```bash
# Deploy to dev environment
./run_scripts/aws/terraform/deploy.sh dev all

# Deploy only infrastructure layer
./run_scripts/aws/terraform/deploy.sh dev infrastructure

# Deploy only application layer
./run_scripts/aws/terraform/deploy.sh prod application
```

### Manual Deployment

1. **Set Environment Variables**

   ```bash
   export AWS_REGION="us-east-1"
   export ENVIRONMENT="dev"
   export OPENAI_API_KEY="sk-..."
   export DB_PASSWORD="SecurePassword123!"
   export CONTAINER_IMAGE="123456789012.dkr.ecr.us-east-1.amazonaws.com/fru-api:latest"
   ```

2. **Deploy Infrastructure Layer**

   ```bash
   cd infra/terraform/environments/dev/infrastructure
   terragrunt plan
   terragrunt apply
   ```

3. **Deploy Application Layer**

   ```bash
   cd infra/terraform/environments/dev/application
   terragrunt plan
   terragrunt apply
   ```

### View Outputs

```bash
cd infra/terraform/environments/dev/infrastructure
terragrunt output

cd ../application
terragrunt output
```

## Module Documentation

Each module has its own README.md with:
- Purpose and features
- Usage examples
- Input variables
- Outputs
- Security considerations

See individual module directories for details.

## Environment-Specific Configuration

### Dev Environment

- Smaller instance sizes
- Single AZ (cost savings)
- No deletion protection
- IAM auth optional

### Prod Environment

- Larger instance sizes
- Multi-AZ (high availability)
- Deletion protection enabled
- IAM auth enabled
- Enhanced monitoring

## After Deployment

1. **Enable pgvector Extension**

   Connect to Aurora and run:
   ```sql
   CREATE EXTENSION IF NOT EXISTS vector;
   ```

2. **Set Up IAM Database User** (if using IAM auth)

   ```sql
   CREATE USER fru_app_user;
   GRANT rds_iam TO fru_app_user;
   GRANT ALL ON DATABASE fru_db TO fru_app_user;
   ```

3. **Run ETL Script**

   ```bash
   export PGHOST=<aurora-endpoint>
   export PGPORT=5432
   export PGUSER=fru_user
   export PGPASSWORD=<password>  # Or use IAM auth
   export PGDATABASE=fru_db
   python backend/etl/load_openai_embeddings_to_pgvector.py
   ```

4. **Deploy Frontend**

   ```bash
   cd frontend
   npm run build
   aws s3 sync dist/ s3://$(terragrunt output -raw s3_bucket_id)/
   aws cloudfront create-invalidation \
     --distribution-id $(terragrunt output -raw cloudfront_distribution_id) \
     --paths "/*"
   ```

## Troubleshooting

### State Lock Issues

If Terraform state is locked:
```bash
aws dynamodb delete-item \
  --table-name fru-terraform-locks \
  --key '{"LockID":{"S":"<lock-id>"}}'
```

### Module Not Found

Ensure you're running Terragrunt from the correct directory:
```bash
cd infra/terraform/environments/dev/infrastructure
terragrunt plan
```

### Secrets Not Found

Ensure secrets are created in Secrets Manager before deploying application layer:
```bash
cd infra/terraform/environments/dev/infrastructure
terragrunt apply
```

## Destroying Infrastructure

```bash
cd infra/terraform/environments/dev/application
terragrunt destroy

cd ../infrastructure
terragrunt destroy
```

**Warning**: This will delete all resources. Ensure you have backups!

