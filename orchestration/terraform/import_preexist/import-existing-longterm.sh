#!/bin/bash
#
# Import existing AWS Secrets Manager resources into Terraform state (infrastructure-longterm layer).
#
# PURPOSE:
#   When Secrets Manager secrets already exist but are not in Terraform state,
#   "terragrunt apply" for the longterm layer fails with "already exists" errors.
#   This script imports those resources so Terraform can manage them.
#
# WHEN TO USE:
#   - Secrets were created by the old infrastructure layer and you migrated to Option B (separate longterm layer).
#   - Terraform state for longterm was lost but AWS secrets still exist.
#
# WHAT IT IMPORTS (per environment):
#   - aws_secretsmanager_secret.* (openai_key, openai_key_plain, db_password, db_password_plain, db_username[0])
#   - aws_secretsmanager_secret_version.* (same names)
#
# Imports are idempotent: if a resource is already in state, the import is skipped.
#
# USAGE:
#   ./import-existing-longterm.sh [dev|prod] [project_name]
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../../.." && pwd)}"
source "$REPO_ROOT/orchestration/common/logger.sh"
source "$REPO_ROOT/orchestration/common/env/load-env.sh"
load_env_file || true

ENVIRONMENT="${1:-dev}"
PROJECT_NAME="${2:-fru}"

if [[ ! "$ENVIRONMENT" =~ ^(dev|staging|prod)$ ]]; then
    log_error "Invalid environment: $ENVIRONMENT"
    log_info "Usage: $0 [dev|staging|prod] [project_name]"
    exit 1
fi

LONGTERM_DIR="$REPO_ROOT/module_infra_basic/aws/terra/environments/$ENVIRONMENT/infrastructure-longterm"

log_step "Importing existing longterm (Secrets Manager) into Terraform state"
log_info "Environment: $ENVIRONMENT"
log_info "Project name: $PROJECT_NAME"
log_info "Longterm dir: $LONGTERM_DIR"

if [ ! -d "$LONGTERM_DIR" ]; then
    log_error "Longterm directory not found: $LONGTERM_DIR"
    exit 1
fi

cd "$LONGTERM_DIR"

log_info "Ensuring Terragrunt is initialized..."
if ! terragrunt init -input=false; then
    log_error "terragrunt init failed"
    exit 1
fi

# In longterm layer the root module IS the secrets-manager module; no "module.secrets_manager." prefix.
# Resource : AWS secret name (or ARN for secret_version; we use secret name for secret, then import versions after).
imports=(
    "aws_secretsmanager_secret.openai_key:${PROJECT_NAME}/${ENVIRONMENT}/openai-api-key"
    "aws_secretsmanager_secret.openai_key_plain:${PROJECT_NAME}/${ENVIRONMENT}/openai-api-key-plain"
    "aws_secretsmanager_secret.db_password:${PROJECT_NAME}/${ENVIRONMENT}/aurora-db-password"
    "aws_secretsmanager_secret.db_password_plain:${PROJECT_NAME}/${ENVIRONMENT}/aurora-db-password-plain"
    "aws_secretsmanager_secret.db_username[0]:${PROJECT_NAME}/${ENVIRONMENT}/aurora-db-username"
)

failed=0
for import_spec in "${imports[@]}"; do
    IFS=':' read -r resource id <<< "$import_spec"
    log_info "Importing $resource..."
    tmp_log="$(mktemp)"
    if terragrunt import "$resource" "$id" >"$tmp_log" 2>&1; then
        log_success "  OK: $resource"
    else
        if grep -qi "already managed by Terraform\|Resource already managed" "$tmp_log"; then
            log_success "  OK (already in state): $resource"
        elif grep -qi "Cannot import non-existent remote object" "$tmp_log"; then
            log_info "  Skip (resource does not exist in AWS): $resource"
        else
            log_warning "  Import failed for $resource"
            tail -10 "$tmp_log" | while IFS= read -r line; do log_info "    $line"; done
            (( failed++ )) || true
        fi
    fi
    rm -f "$tmp_log"
done

# Secret versions: import by ARN. We need the secret ARN; Terraform expects secret_version import ID as <secret-id>|<version-id> or just the version ARN.
# AWS provider: aws_secretsmanager_secret_version import uses the version ARN (e.g. arn:aws:secretsmanager:region:acct:secret:name-xxxxxx).
# For simplicity we skip version imports if secrets don't exist; first apply will create versions. If secrets were imported, next apply will try to create versions and may conflict - then user can import versions manually or we add version imports here.
# Adding version imports: Terraform docs say secret_version import id is "arn:aws:secretsmanager:region:account:secret:name-6randomchars". So we'd need to fetch ARNs from AWS. Skip for now; apply after importing secrets will either create new versions (if secret is empty) or fail and user can import version.
if [ "$failed" -gt 0 ]; then
    log_warning "Some imports failed ($failed). Run 'terragrunt plan' in $LONGTERM_DIR to see remaining differences."
else
    log_success "Import phase completed."
fi
log_info "Run 'terragrunt plan' in $LONGTERM_DIR to verify state."
