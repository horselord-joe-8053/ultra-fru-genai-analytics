#!/bin/bash
# Ensure pgvector extension is installed on the Aurora/Postgres database
# Usage: ./ensure-pgvector.sh <env> [--force-refresh-data]
# Uses the RDS Data API (no direct network access to Aurora required).
# Requires: aws cli; AWS_PROFILE (admin) and AWS_REGION set by caller.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../../.." && pwd)}"
source "$REPO_ROOT/run_scripts/shared/logger.sh"

ENVIRONMENT="${1:-dev}"
FORCE_REFRESH_DATA="${FORCE_REFRESH_DATA:-false}"

# Parse arguments
ARGS=()
for arg in "$@"; do
    if [ "$arg" = "--force-refresh-data" ]; then
        FORCE_REFRESH_DATA=true
    else
        ARGS+=("$arg")
    fi
done

# Update ENVIRONMENT from parsed args if provided
if [ ${#ARGS[@]} -gt 0 ]; then
    ENVIRONMENT="${ARGS[0]:-$ENVIRONMENT}"
fi

AWS_PROFILE="${AWS_PROFILE:-admin}"
AWS_REGION="${AWS_REGION:-us-east-1}"

ensure_pgvector() {
    local env="${1:-$ENVIRONMENT}"
    
    if ! command_exists aws; then
        log_error "aws CLI is required on PATH (missing: aws)."
        exit 1
    fi
    
    # Determine Terraform environment directory
    TERRAFORM_DIR="$REPO_ROOT/infra/terraform/providers/aws/environments"
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
    
    # If --force-refresh-data is set, drop extension first
    if [ "$FORCE_REFRESH_DATA" = "true" ]; then
        log_info "FORCE_REFRESH_DATA=true: Dropping existing pgvector extension (if any)..."
        aws rds-data execute-statement \
            --resource-arn "$DB_CLUSTER_ARN" \
            --secret-arn "$DB_SECRET_ARN" \
            --database "$DB_NAME" \
            --sql "DROP EXTENSION IF EXISTS vector CASCADE;" \
            --profile "$AWS_PROFILE" \
            --region "$AWS_REGION" >/dev/null 2>&1 || true
        log_info "Extension dropped (if it existed). Proceeding with fresh installation..."
    else
        # Check if pgvector extension already exists
        log_info "Checking if pgvector extension is already installed..."
        local extension_exists=false
        local check_result
        
        if check_result=$(aws rds-data execute-statement \
            --resource-arn "$DB_CLUSTER_ARN" \
            --secret-arn "$DB_SECRET_ARN" \
            --database "$DB_NAME" \
            --sql "SELECT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'vector');" \
            --profile "$AWS_PROFILE" \
            --region "$AWS_REGION" \
            --output text \
            --query 'records[0][0].booleanValue' 2>&1); then
            if [ "$check_result" = "True" ] || [ "$check_result" = "true" ] || [ "$check_result" = "1" ]; then
                extension_exists=true
            fi
        fi
        
        if [ "$extension_exists" = true ]; then
            log_info "pgvector extension already installed"
            log_success "Skipping pgvector installation (idempotent - extension exists)"
            return 0
        fi
        
        log_info "pgvector extension not found. Proceeding with installation..."
    fi
    
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
            log_success "pgvector extension created via Data API (attempt ${attempt}/${max_retries})."
            
            # Wait for extension to be fully ready (not just created, but actually usable)
            if [ -f "$REPO_ROOT/run_scripts/main_application_scripts/aws/database/wait-for-pgvector-ready.sh" ]; then
                source "$REPO_ROOT/run_scripts/main_application_scripts/aws/database/wait-for-pgvector-ready.sh"
                if wait_for_pgvector_ready "$DB_CLUSTER_ARN" "$DB_SECRET_ARN" "$DB_NAME" 60 2; then
                    log_success "pgvector extension is fully ready and usable"
                    return 0
                else
                    log_warning "pgvector extension created but readiness check failed"
                    log_warning "Extension may still be initializing - this is usually fine"
                    return 0  # Still return success - extension was created
                fi
            else
                log_info "wait-for-pgvector-ready.sh not found, skipping readiness check"
            return 0
            fi
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

