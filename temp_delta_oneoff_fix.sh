#!/bin/bash
# One-off: Create Delta table via local Docker using the same ECR image.
# Use when you deployed EKS-only (or skipped data-lake) and need the Delta table
# without ECS. Run from repo root. Delete after refactor (local Docker path) is done.
#
# Prereqs: Docker, AWS CLI, ECR login, CONTAINER_IMAGE and S3 bucket set.
# Usage: ./temp_delta_oneoff_fix.sh [dev|prod]

set -e

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"
source "$REPO_ROOT/orchestration/common/logger.sh"
source "$REPO_ROOT/orchestration/common/env/load-env.sh"
load_env_file 2>/dev/null || true

ENVIRONMENT="${1:-dev}"
AWS_PROFILE="${AWS_PROFILE:-admin}"
AWS_REGION="${AWS_REGION:-us-east-1}"
export AWS_PROFILE AWS_REGION

# 1) CONTAINER_IMAGE
if [ -z "$CONTAINER_IMAGE" ]; then
    log_info "Resolving CONTAINER_IMAGE..."
    source "$REPO_ROOT/orchestration/common/env/load-image-identifiers.sh"
    load_image_identifiers "aws" || true
fi
if [ -z "$CONTAINER_IMAGE" ]; then
    log_error "CONTAINER_IMAGE not set. Run from a deploy that set it, or export CONTAINER_IMAGE=your-ecr-uri:tag"
    exit 1
fi
log_info "Using image: $CONTAINER_IMAGE"

# 2) ECR login (same registry as image)
REGISTRY="${CONTAINER_IMAGE%%/*}"
log_info "Logging into ECR: $REGISTRY"
aws ecr get-login-password --region "$AWS_REGION" --profile "$AWS_PROFILE" | \
    docker login --username AWS --password-stdin "$REGISTRY" || { log_error "ECR login failed"; exit 1; }

# 3) S3 bucket (from Terraform output or env)
if [ -z "$S3_BUCKET_ID" ]; then
    INFRA_DIR="$REPO_ROOT/module_infra_basic/aws/terra/environments/$ENVIRONMENT/infrastructure"
    if [ -d "$INFRA_DIR" ]; then
        log_info "Getting S3 bucket from Terraform output..."
        S3_BUCKET_ID=$(cd "$INFRA_DIR" && terragrunt output -raw s3_data_bucket_id 2>/dev/null) || true
    fi
fi
if [ -z "$S3_BUCKET_ID" ]; then
    log_error "S3_BUCKET_ID not set. Export it or run from infra that has Terraform output s3_data_bucket_id."
    exit 1
fi
log_info "S3 bucket: $S3_BUCKET_ID"

# 4) Spark packages and paths (Python helper; PYTHONPATH so spark_jobs resolves)
export PYTHONPATH="$REPO_ROOT/module_app_core${PYTHONPATH:+:$PYTHONPATH}"
PYTHON_CMD="${PYTHON_CMD:-python3}"
CSV_PATH="s3://$S3_BUCKET_ID/raw/fridge_sales_with_rating.csv"
DELTA_PATH="s3://$S3_BUCKET_ID/delta/fru_sales"
HELPER_OUTPUT=$("$PYTHON_CMD" -c "
import sys
sys.path.insert(0, '$REPO_ROOT/module_app_core')
from spark_jobs.utils.spark_config import get_spark_packages, to_spark_path
csv_path = '$CSV_PATH'
delta_path = '$DELTA_PATH'
print(get_spark_packages(is_aws_deployment=True) + '|' + to_spark_path(csv_path) + '|' + to_spark_path(delta_path))
" 2>/dev/null) || { log_error "Python helper failed (check PYTHONPATH and DELTA_LAKE_PACKAGE in .env)"; exit 1; }
SPARK_PACKAGES=$(echo "$HELPER_OUTPUT" | cut -d'|' -f1)
INPUT_S3A=$(echo "$HELPER_OUTPUT" | cut -d'|' -f2)
OUTPUT_S3A=$(echo "$HELPER_OUTPUT" | cut -d'|' -f3)
log_info "Input (s3a): $INPUT_S3A"
log_info "Output (s3a): $OUTPUT_S3A"

# 5) S3A config for local Docker: use default credentials chain (env vars).
# Use numeric values for all time params (Hadoop rejects duration strings like "30s"/"60s").
# Prefer run-spark-job-docker-ecr.sh which uses Python get_s3a_spark_config as single source of truth.
S3A_CONF="--conf spark.hadoop.fs.s3a.impl=org.apache.hadoop.fs.s3a.S3AFileSystem"
S3A_CONF="$S3A_CONF --conf spark.hadoop.fs.s3a.aws.credentials.provider=com.amazonaws.auth.DefaultAWSCredentialsProviderChain"
S3A_CONF="$S3A_CONF --conf spark.hadoop.fs.s3a.connection.timeout=60000"
S3A_CONF="$S3A_CONF --conf spark.hadoop.fs.s3a.connection.establish.timeout=30000"
S3A_CONF="$S3A_CONF --conf spark.hadoop.fs.s3a.threads.keepalivetime=60"

# 6) AWS creds for container (from profile)
export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
if [ -z "$AWS_ACCESS_KEY_ID" ] && [ -n "$AWS_PROFILE" ]; then
    eval "$(aws configure export-credentials --profile "$AWS_PROFILE" --format env 2>/dev/null)" || true
fi
if [ -z "$AWS_ACCESS_KEY_ID" ]; then
    log_error "AWS credentials not set. Export AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY or set AWS_PROFILE with credentials."
    exit 1
fi

# 7) docker run (DOCKER_RUN_REMOTE_PLATFORM for ECR image on Apple Silicon / ARM64)
DOCKER_PLATFORM="${DOCKER_RUN_REMOTE_PLATFORM:-linux/amd64}"
SPARK_CMD="/opt/spark/bin/spark-submit --packages $SPARK_PACKAGES $S3A_CONF /app/spark_jobs/ingest_delta.py $INPUT_S3A $OUTPUT_S3A"
log_info "Running Delta table creation (local Docker)..."
docker run --rm --platform "$DOCKER_PLATFORM" \
    -e AWS_ACCESS_KEY_ID \
    -e AWS_SECRET_ACCESS_KEY \
    -e AWS_SESSION_TOKEN \
    -e AWS_REGION \
    "$CONTAINER_IMAGE" \
    /bin/sh -c "$SPARK_CMD" || { log_error "Delta table creation failed"; exit 1; }

log_success "Delta table created at $OUTPUT_S3A"
log_info "You can remove this script after refactor (Delta via local Docker) is in place."
