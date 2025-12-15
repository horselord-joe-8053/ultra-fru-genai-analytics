#!/bin/bash
# Ensure pgvector extension is installed on the Aurora/Postgres database
# Usage: ./post_create_pgvector.sh <env>
# Uses the RDS Data API (no direct network access to Aurora required).
# Requires: aws cli; AWS_PROFILE (admin) and AWS_REGION set by caller.

set -euo pipefail

ENVIRONMENT="${1:-dev}"
AWS_PROFILE="${AWS_PROFILE:-admin}"
AWS_REGION="${AWS_REGION:-us-east-1}"

command_exists() { command -v "$1" >/dev/null 2>&1; }

log() {
  echo "[pgvector][$ENVIRONMENT] $*"
}

main() {
  # Explicit checks so it's clear what's missing (in addition to global dependency check)
  if ! command_exists aws; then
    log "aws CLI is required on PATH (missing: aws)."
    exit 1
  fi

  # Determine Terraform environment directory
  REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
  TERRAFORM_DIR="$REPO_ROOT/infra/terraform/environments"
  INFRA_DIR="$TERRAFORM_DIR/$ENVIRONMENT/infrastructure"

  if [ ! -d "$INFRA_DIR" ]; then
    log "Infrastructure directory not found at $INFRA_DIR; cannot fetch outputs."
    exit 1
  fi

  # Fetch required outputs from Terragrunt (cluster ARN, DB name, secret ARN)
  log "Fetching Aurora cluster information from Terraform outputs..."
  DB_CLUSTER_ARN=$(cd "$INFRA_DIR" && terragrunt output -raw db_cluster_arn 2>/dev/null || echo "")
  DB_SECRET_ARN=$(cd "$INFRA_DIR" && terragrunt output -raw db_password_secret_arn 2>/dev/null || echo "")
  DB_NAME=$(cd "$INFRA_DIR" && terragrunt output -raw aurora_database_name 2>/dev/null || echo "fru_db")

  if [ -z "$DB_CLUSTER_ARN" ] || [ -z "$DB_SECRET_ARN" ]; then
    log "Missing db_cluster_arn or db_password_secret_arn from infrastructure outputs; skipping pgvector setup."
    exit 1
  fi

  log "Using cluster ARN: $DB_CLUSTER_ARN"
  log "Using DB credentials secret ARN: $DB_SECRET_ARN"
  log "Database name: $DB_NAME"

  # Retry a few times in case the cluster is not immediately ready for Data API
  max_retries=5
  for attempt in $(seq 1 $max_retries); do
    log "Running RDS Data API attempt ${attempt}/${max_retries}..."
    if aws rds-data execute-statement \
      --resource-arn "$DB_CLUSTER_ARN" \
      --secret-arn "$DB_SECRET_ARN" \
      --database "$DB_NAME" \
      --sql "CREATE EXTENSION IF NOT EXISTS vector;" \
      --profile "$AWS_PROFILE" \
      --region "$AWS_REGION" >/dev/null; then
      log "pgvector extension ensured via Data API (attempt ${attempt}/${max_retries})."
      return 0
    else
      log "RDS Data API attempt ${attempt}/${max_retries} failed."
      if [ "$attempt" -lt "$max_retries" ]; then
        log "Retrying in 15s..."
        sleep 15
      else
        log "Failed to create pgvector extension via Data API after ${max_retries} attempts."
        exit 1
      fi
    fi
  done
}

main "$@"

