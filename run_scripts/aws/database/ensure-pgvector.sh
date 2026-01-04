#!/bin/bash
# Ensure pgvector extension is installed on the Aurora/Postgres database
# Usage: ./ensure-pgvector.sh <env>
# Uses the RDS Data API (no direct network access to Aurora required).
# Requires: aws cli; AWS_PROFILE (admin) and AWS_REGION set by caller.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
source "$SCRIPT_DIR/../../common/logger.sh"

ENVIRONMENT="${1:-dev}"
AWS_PROFILE="${AWS_PROFILE:-admin}"
AWS_REGION="${AWS_REGION:-us-east-1}"

ensure_pgvector() {
    local env="${1:-$ENVIRONMENT}"
    
    if ! command_exists aws; then
        log_error "aws CLI is required on PATH (missing: aws)."
        exit 1
    fi
    
    # Determine Terraform environment directory
    TERRAFORM_DIR="$REPO_ROOT/infra/terraform/environments"
    INFRA_DIR="$TERRAFORM_DIR/$env/infrastructure"
    
    if [ ! -d "$INFRA_DIR" ]; then
        log_warning "Infrastructure directory not found at $INFRA_DIR; skipping pgvector extension step"
        return 0
    fi
    
    # Fetch required outputs from Terragrunt (cluster ARN, DB name, secret ARN)
    log_info "Fetching Aurora cluster information from Terraform outputs..."
    DB_CLUSTER_ARN=$(cd "$INFRA_DIR" && terragrunt output -raw db_cluster_arn 2>/dev/null || echo "")
    DB_SECRET_ARN=$(cd "$INFRA_DIR" && terragrunt output -raw db_password_secret_arn 2>/dev/null || echo "")
    DB_NAME=$(cd "$INFRA_DIR" && terragrunt output -raw aurora_database_name 2>/dev/null || echo "fru_db")
    
    if [ -z "$DB_CLUSTER_ARN" ] || [ -z "$DB_SECRET_ARN" ]; then
        log_warning "Missing db_cluster_arn or db_password_secret_arn from infrastructure outputs; skipping pgvector extension step"
        return 0
    fi
    
    log_info "Using cluster ARN: $DB_CLUSTER_ARN"
    log_info "Using DB credentials secret ARN: $DB_SECRET_ARN"
    log_info "Database name: $DB_NAME"
    
    # Retry a few times in case the cluster is not immediately ready for Data API
    max_retries=5
    for attempt in $(seq 1 $max_retries); do
        log_info "Running RDS Data API attempt ${attempt}/${max_retries}..."
        if aws rds-data execute-statement \
            --resource-arn "$DB_CLUSTER_ARN" \
            --secret-arn "$DB_SECRET_ARN" \
            --database "$DB_NAME" \
            --sql "CREATE EXTENSION IF NOT EXISTS vector;" \
            --profile "$AWS_PROFILE" \
            --region "$AWS_REGION" >/dev/null; then
            log_success "pgvector extension ensured via Data API (attempt ${attempt}/${max_retries})."
            return 0
        else
            log_info "RDS Data API attempt ${attempt}/${max_retries} failed."
            if [ "$attempt" -lt "$max_retries" ]; then
                log_info "Retrying in 15s..."
                sleep 15
            else
                log_error "Failed to create pgvector extension via Data API after ${max_retries} attempts."
                exit 1
            fi
        fi
    done
}

# If executed directly
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    ensure_pgvector "$@"
    exit $?
fi

