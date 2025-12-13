# AWS Setup Guide for FRU GenAI Analytics

This guide provides step-by-step instructions to set up the entire FRU (Fridges R Us) GenAI Analytics project on AWS from scratch, starting with a root AWS account.

## Prerequisites

- AWS Account with root access
- AWS CLI installed and configured (or ready to configure)
- Basic understanding of AWS services (IAM, S3, ECR, ECS, RDS/Aurora, Bedrock)

---

## Step 1: Create IAM Users

### 1.1 Create Bedrock Admin User

1. Log in to AWS Console with your root account
2. Navigate to **IAM** → **Users** → **Create user**
3. User name: `bedrock-admin`
4. Select **"Provide user access to the AWS Management Console"** (optional, for console access)
5. Click **Next**
6. Under **"Set permissions"**, select **"Attach policies directly"**
7. Search for and attach: **`AmazonBedrockFullAccess`**
8. Click **Next** → **Create user**

### 1.2 Create Admin User

1. Navigate to **IAM** → **Users** → **Create user**
2. User name: `admin`
3. Select **"Provide user access to the AWS Management Console"** (optional)
4. Click **Next**
5. Under **"Set permissions"**, select **"Attach policies directly"**
6. Search for and attach: **`AdministratorAccess`**
7. Click **Next** → **Create user**

---

## Step 2: Generate Access Keys for Bedrock Admin

1. Navigate to **IAM** → **Users** → Select `bedrock-admin`
2. Go to **"Security credentials"** tab
3. Scroll to **"Access keys"** section
4. Click **"Create access key"**
5. Select **"Application running outside AWS"** (for local development)
6. Click **Next** → **Create access key**
7. **IMPORTANT**: Copy both:
   - **Access key ID**
   - **Secret access key** (shown only once)
8. Store these securely (you'll add them to `.env` file in Step 4)

---

## Step 3: Configure AWS CLI with Admin Credentials

### 3.1 Get Admin Access Keys

1. Navigate to **IAM** → **Users** → Select `admin`
2. Go to **"Security credentials"** tab
3. Create access key following the same process as Step 2
4. Copy the **Access key ID** and **Secret access key**

### 3.2 Configure AWS CLI Profile

Choose one of the following methods:

**Option A: Using AWS CLI configure (Recommended)**
```bash
aws configure --profile admin
```
Enter when prompted:
- AWS Access Key ID: `<admin-access-key-id>`
- AWS Secret Access Key: `<admin-secret-access-key>`
- Default region name: `us-east-1` (or your preferred region)
- Default output format: `json`

**Option B: Manual configuration**
Edit `~/.aws/credentials`:
```ini
[admin]
aws_access_key_id = <admin-access-key-id>
aws_secret_access_key = <admin-secret-access-key>
```

Edit `~/.aws/config`:
```ini
[profile admin]
region = us-east-1
output = json
```

### 3.3 Verify Configuration

```bash
aws sts get-caller-identity --profile admin
```

You should see your AWS account ID and the `admin` user ARN.

---

## Step 4: Set Up Environment Variables (.env file)

### 4.1 Create .env File

At the project root, create or edit `.env` file:

```bash
cd /path/to/fru-genai-analytics-all
./run_scripts/local/setup-env.sh
```

Or create manually:

```bash
touch .env
```

### 4.2 Configure .env File

Edit `.env` and add the following (replace placeholders with actual values):

```bash
# Database Configuration (will be updated after Aurora is created)
PGHOST=<aurora-endpoint>
PGPORT=5432
PGUSER=fru_user
PGPASSWORD=<secure-password>
PGDATABASE=fru_db

# OpenAI Configuration (REQUIRED)
OPENAI_API_KEY=sk-your-openai-api-key-here

# AWS Configuration
AWS_REGION=us-east-1
BEDROCK_MODEL_ID=anthropic.claude-3-haiku-20240229-v1:0

# AWS Credentials for Bedrock (from Step 2)
AWS_ACCESS_KEY_ID=<bedrock-admin-access-key-id>
AWS_SECRET_ACCESS_KEY=<bedrock-admin-secret-access-key>

# AWS Profile for Admin Operations (from Step 3)
AWS_PROFILE=admin

# Terraform State Bucket (will be created in Step 5)
TF_STATE_BUCKET=fru-terraform-state-<your-account-id>

# Container Image (will be set after Step 7)
CONTAINER_IMAGE=<ecr-repository-uri>:latest
```

**Why Use Bedrock-Admin Credentials Instead of Admin Credentials?**

This follows the **principle of least privilege** for security:

- **`AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` (bedrock-admin)**: Used by the **application code** (Flask API) to call Bedrock APIs. The application only needs Bedrock access, not full admin permissions. If the application is compromised, the damage is limited to Bedrock operations only.

- **`AWS_PROFILE=admin`**: Used by **infrastructure tools** (Terraform, AWS CLI, ECR scripts) for managing AWS resources. These tools need admin access to create/modify infrastructure, but this is separate from application runtime.

**Separation of Concerns:**
- **Admin credentials** → Infrastructure management (Terraform, ECR, S3, etc.)
- **Bedrock-admin credentials** → Application runtime (Bedrock API calls)

**Note:** In production (ECS deployment), the application should use **IAM roles** instead of access keys in `.env`. The access keys in `.env` are primarily for local development and initial setup.

**Important Notes:**
- Replace `<your-account-id>` with your AWS account ID (get it with: `aws sts get-caller-identity --profile admin --query Account --output text`)
- The `BEDROCK_MODEL_ID` can be changed to other Claude models if needed:
  - `anthropic.claude-3-haiku-20240229-v1:0` (fastest, cheapest)
  - `anthropic.claude-3-sonnet-20240229-v1:0` (balanced)
  - `anthropic.claude-3-opus-20240229-v1:0` (most capable)
- Database credentials will be updated after Aurora is deployed (Step 9)

---

## Step 5: Create S3 Bucket for Terraform State

### 5.1 Get Your AWS Account ID

```bash
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --profile admin --query Account --output text)
echo $AWS_ACCOUNT_ID
```

### 5.2 Create S3 Bucket

```bash
# Set your preferred bucket name (must be globally unique)
export TF_STATE_BUCKET="fru-terraform-state-${AWS_ACCOUNT_ID}"
export AWS_REGION="us-east-1"

# Create bucket
aws s3api create-bucket \
  --bucket "$TF_STATE_BUCKET" \
  --region "$AWS_REGION" \
  --profile admin

# Enable versioning (recommended for state files)
aws s3api put-bucket-versioning \
  --bucket "$TF_STATE_BUCKET" \
  --versioning-configuration Status=Enabled \
  --profile admin

# Enable encryption
aws s3api put-bucket-encryption \
  --bucket "$TF_STATE_BUCKET" \
  --server-side-encryption-configuration '{
    "Rules": [{
      "ApplyServerSideEncryptionByDefault": {
        "SSEAlgorithm": "AES256"
      }
    }]
  }' \
  --profile admin

# Block public access (security best practice)
aws s3api put-public-access-block \
  --bucket "$TF_STATE_BUCKET" \
  --public-access-block-configuration \
    "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true" \
  --profile admin
```

### 5.3 Update .env File

Add the bucket name to your `.env` file:
```bash
TF_STATE_BUCKET=fru-terraform-state-<your-account-id>
```

---

## Step 6: Enable Bedrock Model Access

### 6.1 Enable Bedrock in AWS Console

1. Log in to AWS Console with `admin` user (or root)
2. Navigate to **Amazon Bedrock** service
3. Go to **"Model access"** in the left sidebar
4. Click **"Manage model access"**
5. Select the Claude models you want to use:
   - **Claude 3 Haiku** (recommended for cost)
   - **Claude 3 Sonnet** (optional)
   - **Claude 3 Opus** (optional)
6. Click **"Save changes"**
7. Wait for model access to be enabled (may take a few minutes)

### 6.2 Verify Bedrock Access

```bash
# Test with bedrock-admin credentials
export AWS_ACCESS_KEY_ID=<bedrock-admin-access-key-id>
export AWS_SECRET_ACCESS_KEY=<bedrock-admin-secret-access-key>
export AWS_REGION=us-east-1

# List available models
aws bedrock list-foundation-models --region us-east-1
```

You should see Claude models in the list.

---

## Step 7: Build and Push Container Image to ECR

### 7.1 Set Up Environment

```bash
# Load environment variables from .env
export $(grep -v '^#' .env | xargs)

# Or manually set
export AWS_REGION=us-east-1
export AWS_PROFILE=admin
```

### 7.2 Run Build and Push Script

```bash
./run_scripts/aws/ecs/build-push-ecr.sh
```

This script will:
- Check AWS credentials
- Create ECR repository `fru-api` (if it doesn't exist)
- Build Docker image from `infra/docker/Dockerfile.api`
- Tag and push image to ECR

### 7.3 Get Container Image URI

After the script completes, it will output the image URI. It will be in the format:
```
<account-id>.dkr.ecr.<region>.amazonaws.com/fru-api:latest
```

### 7.4 Update .env File

Add the container image URI to your `.env` file:
```bash
CONTAINER_IMAGE=<account-id>.dkr.ecr.us-east-1.amazonaws.com/fru-api:latest
```

**Example:**
```bash
CONTAINER_IMAGE=123456789012.dkr.ecr.us-east-1.amazonaws.com/fru-api:latest
```

---

## Step 8: Verify All Required Environment Variables

Before proceeding to Terraform deployment, ensure your `.env` file has all required variables:

```bash
# Required variables checklist:
✅ OPENAI_API_KEY
✅ AWS_REGION
✅ BEDROCK_MODEL_ID
✅ AWS_ACCESS_KEY_ID (bedrock-admin)
✅ AWS_SECRET_ACCESS_KEY (bedrock-admin)
✅ AWS_PROFILE (admin)
✅ TF_STATE_BUCKET
✅ CONTAINER_IMAGE
```

**Optional but recommended:**
- `PGPASSWORD` (will be set by Terraform/Secrets Manager, but can be pre-set)
- `DB_PASSWORD` (for Terraform to create database password in Secrets Manager)

---

## Step 9: Deploy Infrastructure with Terraform

### 9.1 Prerequisites Check

Ensure you have:
- **Terraform** >= 1.5.0 installed: `terraform --version`
- **Terragrunt** >= 0.50.0 installed: `terragrunt --version`

Install if needed:
```bash
# macOS
brew install terraform terragrunt

# Linux
# Follow instructions at https://www.terraform.io/downloads
# and https://terragrunt.gruntwork.io/docs/getting-started/install/
```

### 9.2 Set Environment Variables

```bash
# Load .env file
export $(grep -v '^#' .env | xargs)

# Set additional variables for Terraform
export ENVIRONMENT=dev
export AWS_REGION=${AWS_REGION:-us-east-1}
export AWS_PROFILE=${AWS_PROFILE:-admin}
```

### 9.3 Deploy Infrastructure Layer

The infrastructure layer includes: VPC, Aurora PostgreSQL, IAM roles, Secrets Manager.

```bash
# Using automated script (recommended)
./run_scripts/aws/terraform/deploy.sh dev infrastructure

# Or manually
cd infra/terraform/environments/dev/infrastructure
terragrunt plan
terragrunt apply
```

**What this creates:**
- VPC with public/private subnets
- Aurora PostgreSQL cluster with pgvector extension
- IAM roles (execution and runtime)
- Secrets Manager secrets (OPENAI_API_KEY, DB_PASSWORD)
- Security groups

**Important:** After deployment, note the outputs:
- Aurora endpoint (for `PGHOST` in `.env`)
- Database password (if not using IAM auth)

### 9.4 Deploy Application Layer

The application layer includes: ECS cluster, ECS service, ALB, Frontend (S3 + CloudFront).

```bash
# Using automated script (recommended)
./run_scripts/aws/terraform/deploy.sh dev application

# Or manually
cd infra/terraform/environments/dev/application
terragrunt plan
terragrunt apply
```

**What this creates:**
- ECS Fargate cluster
- ECS service running your container
- Application Load Balancer (ALB)
- S3 bucket for frontend
- CloudFront distribution (optional)

### 9.5 Get Deployment Outputs

```bash
# Get infrastructure outputs
cd infra/terraform/environments/dev/infrastructure
terragrunt output

# Get application outputs
cd ../application
terragrunt output
```

**Important outputs to note:**
- `aurora_endpoint` → Update `PGHOST` in `.env`
- `alb_dns_name` → Your API endpoint URL
- `s3_bucket_id` → Frontend bucket name
- `cloudfront_distribution_id` → Frontend URL (if CloudFront enabled)

---

## Step 10: Update Database Configuration

### 10.1 Get Aurora Endpoint

```bash
cd infra/terraform/environments/dev/infrastructure
export AURORA_ENDPOINT=$(terragrunt output -raw aurora_endpoint)
echo $AURORA_ENDPOINT
```

### 10.2 Get Database Password

If using Secrets Manager:
```bash
aws secretsmanager get-secret-value \
  --secret-id fru/dev/db-password \
  --profile admin \
  --query SecretString --output text
```

Or check Terraform outputs if password was set there.

### 10.3 Update .env File

Update your `.env` file with the actual values:
```bash
PGHOST=<aurora-endpoint-from-step-10.1>
PGPASSWORD=<password-from-step-10.2>
```

---

## Step 11: Initialize Database Schema

### 11.1 Connect to Aurora

You'll need PostgreSQL client tools installed:
```bash
# macOS
brew install postgresql@16

# Linux
sudo apt-get install postgresql-client
```

### 11.2 Apply Schema

```bash
# Load environment variables
export $(grep -v '^#' .env | xargs)

# Connect and apply schema
psql "postgresql://${PGUSER}:${PGPASSWORD}@${PGHOST}:${PGPORT}/${PGDATABASE}" \
  -f sql/schema_pgvector.sql
```

This creates:
- `vector` extension (pgvector)
- `fru_sales_embeddings` table
- Indexes for vector search

---

## Step 12: Load Data and Embeddings

### 12.1 Set Up Data Path

Ensure your CSV file is accessible:
```bash
# Local file path
export FRU_CSV_PATH="data/raw/fridge_sales_with_rating.csv"
```

Or if data is in S3:
```bash
# Download from S3 first
aws s3 cp s3://your-bucket/data/fridge_sales_with_rating.csv \
  data/raw/fridge_sales_with_rating.csv \
  --profile admin
```

### 12.2 Run ETL Script

```bash
# Load all environment variables
export $(grep -v '^#' .env | xargs)

# Run ETL to load embeddings
python backend/etl/load_openai_embeddings_to_pgvector.py
```

This script will:
- Read CSV file
- Generate OpenAI embeddings for customer feedback
- Insert data + embeddings into Aurora PostgreSQL

**Note:** This requires:
- Valid `OPENAI_API_KEY` in `.env`
- Valid database credentials
- Network access to Aurora (from your local machine or ECS task)

---

## Step 13: Deploy Frontend (Optional)

### 13.1 Build Frontend

```bash
cd frontend
npm install
npm run build
```

### 13.2 Deploy to S3

```bash
# Get S3 bucket from Terraform outputs
cd ../infra/terraform/environments/dev/application
export S3_BUCKET=$(terragrunt output -raw s3_bucket_id)

# Sync frontend build to S3
cd ../../../../..
aws s3 sync frontend/dist/ s3://${S3_BUCKET}/ --profile admin

# If CloudFront is enabled, invalidate cache
export CLOUDFRONT_ID=$(cd infra/terraform/environments/dev/application && terragrunt output -raw cloudfront_distribution_id)
aws cloudfront create-invalidation \
  --distribution-id ${CLOUDFRONT_ID} \
  --paths "/*" \
  --profile admin
```

---

## Step 14: Verify Deployment

### 14.1 Check ECS Service Status

```bash
# Get cluster and service names from Terraform outputs
cd infra/terraform/environments/dev/application
export CLUSTER_NAME=$(terragrunt output -raw ecs_cluster_name)
export SERVICE_NAME=$(terragrunt output -raw ecs_service_name)

# Check service status
aws ecs describe-services \
  --cluster ${CLUSTER_NAME} \
  --services ${SERVICE_NAME} \
  --profile admin
```

### 14.2 Test API Endpoint

```bash
# Get ALB DNS name
cd infra/terraform/environments/dev/application
export ALB_DNS=$(terragrunt output -raw alb_dns_name)

# Test query endpoint
curl -X POST http://${ALB_DNS}/query \
  -H "Content-Type: application/json" \
  -d '{"query": "Why are Samsung customers unhappy?"}'
```

### 14.3 Check CloudWatch Logs

```bash
# Get log group name
export LOG_GROUP="/ecs/fru-api"

# View recent logs
aws logs tail ${LOG_GROUP} --follow --profile admin
```

---

## Step 15: Security Checklist

Before going to production, ensure:

- [ ] **IAM Roles**: ECS tasks use IAM roles (not access keys in containers)
- [ ] **Secrets Manager**: All secrets stored in Secrets Manager (not environment variables)
- [ ] **VPC**: Services in private subnets, only ALB in public
- [ ] **Security Groups**: Minimal required access only
- [ ] **Encryption**: S3 buckets encrypted, Aurora encrypted at rest
- [ ] **Bedrock Access**: Only bedrock-admin user has Bedrock permissions
- [ ] **Database Auth**: Consider IAM database authentication (more secure than passwords)
- [ ] **CloudWatch**: Logging and monitoring enabled
- [ ] **Backup**: Aurora automated backups enabled

---

## Troubleshooting

### Issue: Terraform state bucket not found

**Solution:** Ensure bucket name in `.env` matches the bucket created in Step 5, and that your AWS profile has access.

### Issue: ECR push fails with "no basic auth credentials"

**Solution:** Re-authenticate with ECR:
```bash
aws ecr get-login-password --region us-east-1 --profile admin | \
  docker login --username AWS --password-stdin <account-id>.dkr.ecr.us-east-1.amazonaws.com
```

### Issue: Bedrock access denied

**Solution:** 
1. Verify bedrock-admin user has `AmazonBedrockFullAccess` policy
2. Ensure model access is enabled in Bedrock console (Step 6)
3. Check region matches (some models only available in specific regions)

### Issue: Cannot connect to Aurora

**Solution:**
1. Verify security group allows your IP (for local connection)
2. Check Aurora endpoint is correct
3. Verify credentials in Secrets Manager
4. Ensure Aurora is in a private subnet (use bastion host or VPN for access)

### Issue: Container fails to start

**Solution:**
1. Check CloudWatch logs for errors
2. Verify all secrets exist in Secrets Manager
3. Check ECS task definition has correct image URI
4. Verify IAM roles have correct permissions

---

## Next Steps

After successful deployment:

1. **Monitor**: Set up CloudWatch alarms for service health
2. **Scale**: Adjust ECS service desired count based on load
3. **Optimize**: Review Aurora instance sizes and scaling
4. **Backup**: Configure automated Aurora backups
5. **CI/CD**: Set up automated deployments (GitHub Actions, CodePipeline, etc.)

---

## Summary

This guide covered:
1. ✅ Creating IAM users (bedrock-admin, admin)
2. ✅ Generating access keys
3. ✅ Configuring AWS CLI
4. ✅ Setting up .env file
5. ✅ Creating S3 bucket for Terraform state
6. ✅ Enabling Bedrock model access
7. ✅ Building and pushing container to ECR
8. ✅ Deploying infrastructure with Terraform
9. ✅ Initializing database schema
10. ✅ Loading data and embeddings
11. ✅ Deploying frontend
12. ✅ Verifying deployment

Your FRU GenAI Analytics system should now be running on AWS! 🎉

