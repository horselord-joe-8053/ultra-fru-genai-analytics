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
source "$SCRIPT_DIR/common/lib_import_common.sh"

import_parse_args "$@"
import_validate_env

LONGTERM_DIR="$REPO_ROOT/module_infra_longterm/aws/terra/environments/$ENVIRONMENT/infrastructure-longterm"

log_step "Importing existing longterm (Secrets Manager) into Terraform state"
log_info "Environment: $ENVIRONMENT"
log_info "Project name: $PROJECT_NAME"
log_info "Longterm dir: $LONGTERM_DIR"

import_ensure_dir_and_cd "$LONGTERM_DIR" "Longterm"
import_init_strict

# In longterm layer the root module IS the secrets-manager module; no "module.secrets_manager." prefix.
import_batch \
    "aws_secretsmanager_secret.openai_key:${PROJECT_NAME}/${ENVIRONMENT}/openai-api-key" \
    "aws_secretsmanager_secret.openai_key_plain:${PROJECT_NAME}/${ENVIRONMENT}/openai-api-key-plain" \
    "aws_secretsmanager_secret.db_password:${PROJECT_NAME}/${ENVIRONMENT}/aurora-db-password" \
    "aws_secretsmanager_secret.db_password_plain:${PROJECT_NAME}/${ENVIRONMENT}/aurora-db-password-plain" \
    "aws_secretsmanager_secret.db_username[0]:${PROJECT_NAME}/${ENVIRONMENT}/aurora-db-username"

log_info "Run 'terragrunt plan' in $LONGTERM_DIR to verify state."
