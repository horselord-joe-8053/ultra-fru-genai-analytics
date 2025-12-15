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

# AWS Credentials for Admin (Infrastructure Operations)
# Used by: Terraform, AWS CLI, ECR scripts, S3 operations
AWS_ADMIN_ACCESS_KEY_ID=<admin-access-key-id>
AWS_ADMIN_SECRET_ACCESS_KEY=<admin-secret-access-key>

# AWS Credentials for Bedrock (Application Runtime)
# Used by: Flask API (boto3) for Bedrock API calls
AWS_BEDROCK_ACCESS_KEY_ID=<bedrock-admin-access-key-id>
AWS_BEDROCK_SECRET_ACCESS_KEY=<bedrock-admin-secret-access-key>

# AWS Profile Selection
# Infrastructure scripts default to 'admin' profile
# Application runtime uses 'bedrock' profile (or 'admin' for local Docker)
AWS_PROFILE=admin

# Terraform State Bucket (will be created in Step 5)
TF_STATE_BUCKET=fru-terraform-state-<your-account-id>

# Container Image (will be set after Step 7)
CONTAINER_IMAGE=<ecr-repository-uri>:latest
```

**Why We Need Both Admin and Bedrock Profiles:**

This follows the **principle of least privilege** and **separation of concerns**:

1. **Admin Profile** (`AWS_ADMIN_*` credentials → `[admin]` profile):
   - **Used by**: Infrastructure scripts (Terraform, AWS CLI, ECR, S3 operations)
   - **Permissions needed**: Full admin access to create/modify AWS resources
   - **Purpose**: Deploy infrastructure, manage ECR repositories, create S3 buckets, run Terraform
   - **Security**: If infrastructure scripts are compromised, attacker has admin access (expected for infrastructure management)

2. **Bedrock Profile** (`AWS_BEDROCK_*` credentials → `[bedrock]` profile):
   - **Used by**: Application code (Flask API via boto3) for Bedrock API calls
   - **Permissions needed**: Only Bedrock access (BedrockFullAccess policy)
   - **Purpose**: Application runtime calls to Bedrock for LLM inference
   - **Security**: If application is compromised, damage is limited to Bedrock operations only

**How It Works:**
- Credentials from `.env` are synced to `~/.aws/credentials` profiles via `setup-aws-profiles.sh`
- Infrastructure scripts use `--profile admin` (or `AWS_PROFILE=admin`)
- Application code uses `AWS_PROFILE=bedrock` (or `admin` for local Docker - see note below)
- No credentials are exported as environment variables (more secure)

**Note:** 
- In production (ECS/EKS), the application should use **IAM roles** instead of access keys
- For local Docker development, we use `AWS_PROFILE=admin` (instead of `bedrock`) to allow more operations during testing and development
- The access keys in `.env` are primarily for local development and initial setup

**Important Notes:**
- Replace `<your-account-id>` with your AWS account ID (get it with: `aws sts get-caller-identity --profile admin --query Account --output text`)
- The `BEDROCK_MODEL_ID` can be changed to other Claude models if needed:
  - `anthropic.claude-3-haiku-20240229-v1:0` (fastest, cheapest)
  - `anthropic.claude-3-sonnet-20240229-v1:0` (balanced)
  - `anthropic.claude-3-opus-20240229-v1:0` (most capable)
- Database credentials will be updated after Aurora is deployed (Step 9)

---

## Step 5: Create S3 Bucket for Terraform State

**⚠️ Important:** This step must be done **before running Terraform**. Terraform cannot create its own state bucket because it needs the bucket to exist before it can store state files. This is a one-time bootstrap step.

**Note:** The Terraform configuration in `infra/terraform/environments/root.hcl` expects this bucket to exist and will use it automatically once created.

**Option A: Automated Script (Recommended)**

The deployment script (`./run_scripts/aws/run.sh`) automatically runs this step, but you can also run it manually:

```bash
# Ensure TF_STATE_BUCKET is set in .env
# Then run:
./run_scripts/aws/terraform/setup-s3-bucket.sh
```

This script will:
- ✅ Check if bucket exists (idempotent)
- ✅ Create bucket if it doesn't exist
- ✅ Enable versioning
- ✅ Enable encryption (AES256)
- ✅ Block public access
- ✅ Use region from `AWS_REGION` in `.env` (defaults to us-east-1)

**Option B: Manual Creation**

If you prefer to create it manually:

```bash
# Get your AWS account ID
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --profile admin --query Account --output text)
export TF_STATE_BUCKET="fru-terraform-state-${AWS_ACCOUNT_ID}"
export AWS_REGION="us-east-1"

# Create bucket
aws s3api create-bucket \
  --bucket "$TF_STATE_BUCKET" \
  --region "$AWS_REGION" \
  --profile admin

# Enable versioning
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

# Block public access
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

**Note:** If you use the automated script, it will use `TF_STATE_BUCKET` from your `.env` file automatically.

### 5.4 Setup AWS Profiles (New - Required)

**Migration Note:** If you have old `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` in your `.env` file, you should:
1. Identify which credentials they are (admin or bedrock)
2. Replace them with the new `AWS_ADMIN_*` and `AWS_BEDROCK_*` variables
3. Remove the old `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` lines

After setting up credentials in `.env`, sync them to AWS profiles:

```bash
# This creates [admin] and [bedrock] profiles in ~/.aws/credentials
./run_scripts/aws/setup-aws-profiles.sh
```

This script:
- Reads `AWS_ADMIN_*` and `AWS_BEDROCK_*` from `.env`
- Creates/updates `[admin]` and `[bedrock]` profiles in `~/.aws/credentials`
- Sets proper file permissions (600)
- Backs up existing credentials file

**Note:** This is automatically run by `./run_scripts/aws/run.sh`, but you can run it manually if needed.

---

## Step 6: Enable Bedrock Model Access

### 6.1 Check Bedrock Model Access (Automated)

**Note**: As of October 2025, AWS Bedrock automatically enables access to most serverless foundation models by default. However, Anthropic models (Claude) may still require a one-time usage form submission.

**Option A: Use Automated Script (Recommended)**

```bash
# Check if model access is enabled
./run_scripts/aws/bedrock/enable-model-access.sh

# If access is not enabled, attempt automated enablement
./run_scripts/aws/bedrock/enable-model-access.sh --enable

# Check specific model
./run_scripts/aws/bedrock/enable-model-access.sh --model anthropic.claude-3-haiku-20240307-v1:0
```

The script will:
- ✅ Check if Bedrock service is accessible
- ✅ Verify access to your specified model (default: Claude 3 Haiku)
- ⚠️ Attempt automated enablement if `--enable` flag is used
- ✅ Provide clear manual instructions if automated enablement is not possible

**Option B: Manual Enablement via AWS Console**

If automated enablement is not possible, follow these steps:

1. Log in to AWS Console with `admin` user (or root)
2. Navigate to **Amazon Bedrock** service: https://console.aws.amazon.com/bedrock/
3. Go to **"Model access"** in the left sidebar
4. Click **"Manage model access"**
5. Select the Claude models you want to use:
   - **Claude 3 Haiku** (recommended for cost)
   - **Claude 3 Sonnet** (optional)
   - **Claude 3 Opus** (optional)
6. **For Anthropic models**: Complete the one-time usage form when prompted
7. Click **"Save changes"**
8. Wait for model access to be enabled (may take a few minutes)

### 6.2 Verify Bedrock Access

After enabling access, verify it works:

```bash
# Using the automated script
./run_scripts/aws/bedrock/enable-model-access.sh

# Or manually with AWS CLI
export AWS_ACCESS_KEY_ID=<bedrock-admin-access-key-id>
export AWS_SECRET_ACCESS_KEY=<bedrock-admin-secret-access-key>
export AWS_REGION=us-east-1

# List available models
aws bedrock list-foundation-models --region us-east-1

# Check specific model
aws bedrock get-foundation-model \
  --model-identifier anthropic.claude-3-haiku-20240307-v1:0 \
  --region us-east-1
```

You should see Claude models in the list and be able to access the specific model.

**Note**: If you see errors, the model access may still be propagating. Wait a few minutes and try again.

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

**Option A: Automated (via run.sh)**

The deployment script (`./run_scripts/aws/run.sh`) automatically builds and pushes the image if it doesn't exist in ECR. This is the recommended approach.

**Option B: Manual Execution**

```bash
./run_scripts/aws/common_ecs_eks/build-push-ecr.sh
```

This script will:
- Check AWS credentials
- Create ECR repository `fru-api` (if it doesn't exist)
- Build Docker image from `infra/docker/Dockerfile.api`
- Tag and push image to ECR
- Export `CONTAINER_IMAGE` environment variable

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
✅ AWS_ADMIN_ACCESS_KEY_ID (for infrastructure operations)
✅ AWS_ADMIN_SECRET_ACCESS_KEY
✅ AWS_BEDROCK_ACCESS_KEY_ID (for application runtime)
✅ AWS_BEDROCK_SECRET_ACCESS_KEY
✅ AWS_PROFILE (admin - for infrastructure scripts)
✅ TF_STATE_BUCKET
✅ CONTAINER_IMAGE
```

**Note:** After setting credentials, run `./run_scripts/aws/setup-aws-profiles.sh` to sync them to `~/.aws/credentials` profiles.

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

**Option A: Using run.sh (Recommended - Full Automation)**

```bash
# This will automatically:
# 1. Setup S3 state bucket
# 2. Deploy infrastructure
# 3. Deploy application
# 4. Verify deployment
./run_scripts/aws/run.sh ecs-full dev
```

**Option B: Using terraform/deploy.sh**

```bash
# Deploy infrastructure only
./run_scripts/aws/terraform/deploy.sh dev infrastructure
```

**Option C: Manual Terraform Commands**

```bash
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

**Option A: Using run.sh (Recommended - Full Automation)**

```bash
# This is included in the ecs-full workflow
./run_scripts/aws/run.sh ecs-full dev
```

**Option B: Using terraform/deploy.sh**

```bash
# Deploy application only (after infrastructure is deployed)
./run_scripts/aws/terraform/deploy.sh dev application
```

**Option C: Manual Terraform Commands**

```bash
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

**Option A: Automated (via run.sh - Recommended)**

The deployment script automatically builds and deploys the frontend:
```bash
./run_scripts/aws/run.sh ecs-full dev
```

**Option B: Manual Execution**

```bash
./run_scripts/aws/common_ecs_eks/deploy-frontend.sh
```

This script will:
- Check if S3 bucket exists (creates if needed)
- Configure static website hosting
- Sync frontend files to S3
- Output the website URL

**Option C: Manual with Terraform Outputs**

```bash
# Get S3 bucket from Terraform outputs
cd infra/terraform/environments/dev/application
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

After running the deployment script (`./run_scripts/aws/run.sh`), the script will automatically run verification checks. However, you can also verify manually:

### 14.1 Automatic Verification

The deployment script automatically runs `post_run_verify.sh` which checks:
- ✅ ECS service status and running task count
- ✅ API health endpoint response
- ✅ Terraform outputs (ALB DNS, CloudFront domain)
- ✅ Kubernetes pod status (for EKS deployments)

### 14.2 Manual Verification - Get Deployment URLs

**For ECS Deployment:**

```bash
# Get ALB DNS name (API endpoint)
cd infra/terraform/environments/dev/application
terragrunt output alb_dns_name

# Get CloudFront domain (Frontend URL)
terragrunt output cloudfront_domain_name

# Get ECS cluster and service names
terragrunt output ecs_cluster_id
terragrunt output ecs_service_name
```

**For EKS Deployment:**

```bash
# Check pod status
kubectl get pods -l app=fru-api

# Get service endpoint
kubectl get svc fru-api

# Get ingress hostname
kubectl get ingress fru-api-ingress
```

### 14.3 Test API Health Endpoint

```bash
# Get ALB DNS name first
cd infra/terraform/environments/dev/application
export ALB_DNS=$(terragrunt output -raw alb_dns_name)

# Test health endpoint
curl http://${ALB_DNS}/health

# Expected response:
# {"status": "ok", "database": "connected", "openai": "configured", "aws": "configured"}
```

### 14.4 Test Query Endpoint

```bash
# Test with a sample query
curl -X POST http://${ALB_DNS}/query \
  -H "Content-Type: application/json" \
  -d '{"query": "Why are Samsung customers unhappy?"}'

# Expected: JSON response with answer from Claude via Bedrock
```

### 14.5 Check ECS Service Status

```bash
# Get cluster and service names
export CLUSTER_NAME=$(terragrunt output -raw ecs_cluster_id)
export SERVICE_NAME=$(terragrunt output -raw ecs_service_name)

# Check service status
aws ecs describe-services \
  --cluster ${CLUSTER_NAME} \
  --services ${SERVICE_NAME} \
  --profile admin

# Check running tasks
aws ecs list-tasks \
  --cluster ${CLUSTER_NAME} \
  --service-name ${SERVICE_NAME} \
  --profile admin
```

### 14.6 Check CloudWatch Logs

```bash
# View recent logs
aws logs tail /ecs/fru-api --follow --profile admin

# Or view logs for a specific task
aws logs tail /ecs/fru-api --follow --filter-pattern "ERROR" --profile admin
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

## Step 15: Access and Use Your Deployment

### 15.1 Access the Frontend

After deployment, get your frontend URL:

```bash
cd infra/terraform/environments/dev/application
terragrunt output cloudfront_domain_name
```

**Open the CloudFront domain in your browser** (e.g., `https://d1234567890.cloudfront.net`)

The frontend will:
- Display the FRU GenAI Analytics interface
- Allow you to ask natural language questions
- Show analytics dashboards
- Proxy API requests to your backend

**Try asking questions like:**
- "Why are Samsung customers unhappy?"
- "What are the top-selling fridge models?"
- "Which stores have the best performance?"

### 15.2 Test the API Directly

**Get your API endpoint:**

```bash
cd infra/terraform/environments/dev/application
export ALB_DNS=$(terragrunt output -raw alb_dns_name)
echo "API URL: http://${ALB_DNS}"
```

**Test the health endpoint:**

```bash
curl http://${ALB_DNS}/health
```

**Test a query:**

```bash
curl -X POST http://${ALB_DNS}/query \
  -H "Content-Type: application/json" \
  -d '{"query": "Why are Samsung customers unhappy?"}'
```

### 15.3 Monitor Your Deployment

**View ECS Service Metrics:**
- AWS Console → ECS → Clusters → Your cluster → Services → Your service
- Monitor: CPU utilization, memory usage, request count

**View CloudWatch Logs:**
```bash
aws logs tail /ecs/fru-api --follow --profile admin
```

**View Aurora Metrics:**
- AWS Console → RDS → Databases → Your Aurora cluster
- Monitor: CPU utilization, connections, read/write IOPS

### 15.4 Manual Verification Checklist

After deployment, verify:

- [ ] **ECS Service**: Tasks are running and healthy
  ```bash
  aws ecs describe-services --cluster <cluster-name> --services <service-name> --profile admin
  ```

- [ ] **API Health**: `/health` endpoint returns `{"status": "ok", "database": "connected"}`
  ```bash
  curl http://<alb-dns>/health
  ```

- [ ] **Database Connection**: API can connect to Aurora
  - Check health endpoint response
  - Check CloudWatch logs for connection errors

- [ ] **Bedrock Access**: API can call Bedrock models
  - Test with a query endpoint call
  - Check CloudWatch logs for Bedrock errors

- [ ] **Frontend Access**: CloudFront domain is accessible
  - Open in browser
  - Verify frontend loads and can make API calls

- [ ] **Security Groups**: Only necessary ports are open
  - ALB: Port 80/443 from internet
  - ECS tasks: Only from ALB security group
  - Aurora: Only from ECS security group

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
5. ✅ Creating S3 bucket for Terraform state (automated via `setup-s3-bucket.sh`)
6. ✅ Enabling Bedrock model access (automated via `enable-model-access.sh`)
7. ✅ Building and pushing container to ECR (automated via `build-push-ecr.sh`)
8. ✅ Deploying infrastructure with Terraform (automated via `terraform/deploy.sh`)
9. ✅ Initializing database schema
10. ✅ Loading data and embeddings
11. ✅ Deploying frontend (automated via `deploy-frontend.sh`)
12. ✅ Verifying deployment (automated via `post_run_verify.sh`)

**Your FRU GenAI Analytics system should now be running on AWS! 🎉**

**Quick Start:**
```bash
# Deploy everything with one command:
./run_scripts/aws/run.sh ecs-full dev

# The script will automatically verify deployment and show you how to access your application
```

