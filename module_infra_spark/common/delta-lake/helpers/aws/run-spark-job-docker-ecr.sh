#!/bin/bash
# Run Spark job to create Delta table using local Docker with ECR image.
# Same image as EKS/ECS; works for both deployment types. No ECS/EKS required.
#
# Usage: run-spark-job-docker-ecr.sh <INPUT_PATH> <OUTPUT_PATH> <SPARK_PACKAGES>
#   INPUT_PATH: S3 CSV path (s3a://)
#   OUTPUT_PATH: S3 Delta table path (s3a://)
#   SPARK_PACKAGES: Maven coordinates
#   CONTAINER_IMAGE: from env (ECR URI:tag)

set -e

INPUT_PATH="$1"
OUTPUT_PATH="$2"
SPARK_PACKAGES="$3"
CONTAINER_IMAGE="${CONTAINER_IMAGE:-}"
AWS_PROFILE="${AWS_PROFILE:-admin}"
AWS_REGION="${AWS_REGION:-us-east-1}"

if [ -z "$INPUT_PATH" ] || [ -z "$OUTPUT_PATH" ] || [ -z "$SPARK_PACKAGES" ]; then
    echo "Error: INPUT_PATH, OUTPUT_PATH, and SPARK_PACKAGES are required" >&2
    exit 1
fi
if [ -z "$CONTAINER_IMAGE" ]; then
    echo "Error: CONTAINER_IMAGE environment variable is required (set by run.sh / load-image-identifiers.sh)" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../../../../../.." && pwd)}"
source "$REPO_ROOT/lib/logger.sh"
source "$REPO_ROOT/orchestration/common/env/load-env.sh"
[ -f "$REPO_ROOT/.env" ] && load_env_file 2>/dev/null || true

# ECR login (same registry as image)
REGISTRY="${CONTAINER_IMAGE%%/*}"
log_info "Logging into ECR: $REGISTRY"
if ! aws ecr get-login-password --region "$AWS_REGION" --profile "$AWS_PROFILE" 2>/dev/null | \
    docker login --username AWS --password-stdin "$REGISTRY" 2>/dev/null; then
    log_error "ECR login failed. Ensure AWS credentials and ECR permissions."
    exit 1
fi

# S3A config: single source of truth from Python (spark_config.get_s3a_spark_config) so all
# time-related params are numeric (Hadoop rejects duration strings like "30s"/"60s"). For local
# Docker we override credentials provider to DefaultAWSCredentialsProviderChain (env vars in container).
S3A_CONF=$(PYTHONPATH="${REPO_ROOT}/module_app_core" "${PYTHON_CMD:-python3}" -c '
from spark_jobs.utils.spark_config import get_s3a_spark_config
import shlex
args = list(get_s3a_spark_config())
for i in range(len(args)):
    if i + 1 < len(args) and args[i] == "--conf" and "credentials.provider" in args[i + 1]:
        args[i + 1] = args[i + 1].replace(
            "org.apache.hadoop.fs.s3a.auth.IAMInstanceCredentialsProvider",
            "com.amazonaws.auth.DefaultAWSCredentialsProviderChain",
        )
        break
print(" ".join(shlex.quote(a) for a in args))
' 2>/dev/null) || true
if [ -z "$S3A_CONF" ]; then
    log_info "Falling back to inline S3A config (Python helper unavailable); ensure all time params are numeric."
    S3A_CONF="--conf spark.hadoop.fs.s3a.impl=org.apache.hadoop.fs.s3a.S3AFileSystem"
    S3A_CONF="$S3A_CONF --conf spark.hadoop.fs.s3a.aws.credentials.provider=com.amazonaws.auth.DefaultAWSCredentialsProviderChain"
    S3A_CONF="$S3A_CONF --conf spark.hadoop.fs.s3a.connection.timeout=60000"
    S3A_CONF="$S3A_CONF --conf spark.hadoop.fs.s3a.connection.establish.timeout=30000"
    S3A_CONF="$S3A_CONF --conf spark.hadoop.fs.s3a.threads.keepalivetime=60"
fi

# AWS creds for container (from profile or env)
if [ -z "${AWS_ACCESS_KEY_ID:-}" ] && [ -n "$AWS_PROFILE" ]; then
    if command -v aws >/dev/null 2>&1; then
        eval "$(aws configure export-credentials --profile "$AWS_PROFILE" --format env 2>/dev/null)" || true
    fi
fi
if [ -z "${AWS_ACCESS_KEY_ID:-}" ]; then
    log_error "AWS credentials not set. Export AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY or set AWS_PROFILE."
    exit 1
fi

SPARK_CMD="/opt/spark/bin/spark-submit --packages $SPARK_PACKAGES $S3A_CONF /app/spark_jobs/ingest_delta.py $INPUT_PATH $OUTPUT_PATH"
log_info "Running Delta table creation (local Docker + ECR image)..."
log_info "Image: $CONTAINER_IMAGE"

# ECR image is built for linux/amd64 (EKS/ECS). On ARM64 (e.g. Apple Silicon), use DOCKER_RUN_REMOTE_PLATFORM so Docker uses amd64 (emulated).
DOCKER_PLATFORM="${DOCKER_RUN_REMOTE_PLATFORM:-linux/amd64}"
docker run --rm --platform "$DOCKER_PLATFORM" \
    -e AWS_ACCESS_KEY_ID \
    -e AWS_SECRET_ACCESS_KEY \
    -e AWS_SESSION_TOKEN \
    -e AWS_REGION \
    "$CONTAINER_IMAGE" \
    /bin/sh -c "$SPARK_CMD" || { log_error "Delta table creation failed"; exit 1; }

log_success "Delta table creation complete"
