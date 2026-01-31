# Manual Deployment and Testing Guide

## Prerequisites

1. **AWS Credentials**: Ensure `.env` file has all required AWS credentials:
   - `AWS_ADMIN_ACCESS_KEY_ID`
   - `AWS_ADMIN_SECRET_ACCESS_KEY`
   - `AWS_BEDROCK_ACCESS_KEY_ID`
   - `AWS_BEDROCK_SECRET_ACCESS_KEY`
   - `AWS_REGION` (default: `us-east-1`)
   - `AWS_PROFILE` (default: `admin`)

2. **Environment Variables**: Ensure `.env` has:
   - `IMAGE_PREFIX=fru-api-img-default-prefix` (or your custom prefix)
   - `TF_STATE_BUCKET` (Terraform state bucket name)
   - `ENVIRONMENT=dev` (or `prod`)

3. **Tools**: Verify all dependencies are installed:
   ```bash
   ./run_scripts/common/check-dependencies.sh
   ```

---

## Step 1: Deploy to AWS

### Option A: Complete ECS Deployment (Recommended)

From the repository root:

```bash
./run_scripts/aws/run.sh ecs-full dev
```

**What this does:**
1. Builds and pushes Docker image to ECR (tagged with git SHA: `git-<commit-sha>`)
2. Sets up Terraform state bucket (if needed)
3. Deploys infrastructure (VPC, Aurora, IAM, Secrets Manager)
4. Ensures pgvector extension exists
5. Initializes database schema
6. Deploys application layer (ECS, ALB, CloudFront)
7. Deploys frontend to S3
8. Runs post-deployment verification

**Expected duration:** 15-30 minutes (depending on infrastructure creation)

### Option B: Application Update Only (If infrastructure already exists)

If you only need to update the application code:

```bash
./run_scripts/aws/run.sh terraform dev application
```

**What this does:**
- Builds new Docker image with current git SHA
- Updates ECS task definition with new image
- Triggers ECS service update

**Expected duration:** 5-10 minutes

### Option C: Dry-Run (Preview Changes)

To preview what would be deployed without making changes:

```bash
./run_scripts/aws/run.sh ecs-full dev --dry-run
```

---

## Step 2: Run Test Query

**Note:** Deployment verification is automatically performed as Step 6/6 of the deployment process. The deployment script will output API and frontend URLs automatically.

From the repository root:

```bash
./module_test_verification/test_query_1.sh --test-env aws
```

**What this does:**
- Connects to the deployed AWS API endpoint
- Runs query: "Top 3 problems for low-rating feedbacks"
- Tests with code: `AVG` (as configured in the script)
- Generates test results in `module_test_verification/test_results/query_1_<timestamp>/`

**Expected duration:** 1-2 minutes

**Test output location:**
```
module_test_verification/test_results/query_1_<timestamp>/
├── query_1_AVG_<timestamp>.json
└── query_1_AVG_<timestamp>.log
```

---

## Troubleshooting

### Issue: Docker Authentication Error

**Error:** `Error response from daemon: Get "https://registry-1.docker.io/v2/": unauthorized`

**Solution:**
```bash
# Login to ECR
aws ecr get-login-password --region us-east-1 --profile admin | \
  docker login --username AWS --password-stdin \
  744139897900.dkr.ecr.us-east-1.amazonaws.com
```

### Issue: Image Build Fails

**Check:**
1. Docker daemon is running: `docker ps`
2. ECR repository exists: `aws ecr describe-repositories --profile admin`
3. AWS credentials are valid: `aws sts get-caller-identity --profile admin`

### Issue: Terraform Deployment Fails

**Check:**
1. Terraform state bucket exists: `aws s3 ls | grep terraform`
2. AWS permissions are sufficient
3. Review Terraform plan output for specific errors

### Issue: Test Query Fails

**Check:**
1. API endpoint is accessible: `curl https://<api-endpoint>/health`
2. Database connection is working
3. Bedrock model access is granted
4. Check ECS task logs: `aws logs tail /ecs/fru-api --follow --profile admin`

---

## Quick Reference

### Deployment Commands

| Command | Purpose | Duration |
|---------|---------|----------|
| `./run_scripts/aws/run.sh ecs-full dev` | Full deployment | 15-30 min |
| `./run_scripts/aws/run.sh terraform dev application` | App update only | 5-10 min |
| `./run_scripts/aws/run.sh ecs-full dev --dry-run` | Preview changes | 1-2 min |

### Testing Commands

| Command | Purpose | Duration |
|---------|---------|----------|
| `./module_test_verification/test_query_1.sh --test-env aws` | Test query 1 | 1-2 min |
| `./module_test_verification/test_query_10.sh --test-env aws` | Test query 10 | 1-2 min |

### Verification Commands

| Command | Purpose |
|---------|---------|
| `./run_scripts/aws/verification/auto_verify_and_manual_hint.sh ecs-full dev` | Manual verification (auto-run in Step 6/6) |
| `aws ecs describe-services --cluster fru-ecs-cluster --services fru-api-service --profile admin` | Check ECS service |
| `aws elbv2 describe-load-balancers --profile admin` | Check ALB status |

---

## Notes

1. **Image Tagging**: Images are automatically tagged with git commit SHA (e.g., `git-f81e88c`)
   - **Uncommitted changes**: 
     - **Dev/Staging**: Allowed with `-dirty-<hash>` suffix (for development/testing)
     - **Production**: **BLOCKED** - All changes must be committed before production deployment
     - Override: Set `ALLOW_DIRTY_DEPLOYMENT=true` (NOT RECOMMENDED for production)
   - This ensures Terraform detects code changes

2. **Data Loading**: 
   - Automatically detects if CSV file or schema has changed
   - Compares file hashes to determine if reload is needed
   - Auto-reloads in non-interactive mode if source changed
   - Prompts user in interactive mode

2. **Environment Variables**: 
   - `IMAGE_PREFIX` in `.env` is replaced with actual ECR URI for AWS deployments
   - `CONTAINER_IMAGE` is dynamically generated (don't set it manually)

3. **State Management**: 
   - Terraform state is stored in S3 bucket specified by `TF_STATE_BUCKET`
   - State locking uses DynamoDB table (auto-created)

4. **Rollback**: 
   - To rollback, deploy previous git commit:
     ```bash
     git checkout <previous-commit>
     ./run_scripts/aws/run.sh terraform dev application
     ```

---

## Summary

**Complete workflow:**
```bash
# 1. Deploy (includes automatic verification in Step 6/6)
./run_scripts/aws/run.sh ecs-full dev

# 2. Test
./module_test_verification/test_query_1.sh --test-env aws
```

**Quick update workflow:**
```bash
# 1. Update application only
./run_scripts/aws/run.sh terraform dev application

# 2. Test
./module_test_verification/test_query_1.sh --test-env aws
```

