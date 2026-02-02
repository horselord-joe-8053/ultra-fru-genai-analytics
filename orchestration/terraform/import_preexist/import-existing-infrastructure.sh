#!/bin/bash
#
# Import existing AWS infrastructure resources into Terraform state (infrastructure layer).
#
# PURPOSE:
#   When AWS resources (RDS subnet group, IAM roles, Secrets Manager secrets) already exist
#   but are not in Terraform state, "terragrunt apply" fails with "already exists" errors.
#   This script imports those resources so Terraform can manage them.
#
# WHEN TO USE:
#   - Resources were created manually or by another stack and you want this stack to own them.
#   - Terraform state was lost/recreated but AWS resources still exist.
#   - First-time adoption of Terraform for existing infrastructure.
#
# WHAT IT IMPORTS (per environment):
#   - module.aurora.aws_db_subnet_group.aurora
#   - module.iam.aws_iam_role.ecs_task_execution
#   - module.iam.aws_iam_role.ecs_task_runtime
# (Secrets Manager is in infrastructure-longterm layer; use import-existing-longterm.sh for that.)
#
# Imports are idempotent: if a resource is already in state, the import is skipped (or reported as "already managed").
#
# USAGE:
#   ./import-existing-infrastructure.sh [dev|prod] [project_name]
#
#   Examples:
#     ./import-existing-infrastructure.sh dev
#     ./import-existing-infrastructure.sh prod fru
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

INFRA_DIR="$REPO_ROOT/module_infra_basic/aws/terra/environments/$ENVIRONMENT/infrastructure"

log_step "Importing existing infrastructure into Terraform state"
log_info "Environment: $ENVIRONMENT"
log_info "Project name: $PROJECT_NAME"
log_info "Infrastructure dir: $INFRA_DIR"

if [ ! -d "$INFRA_DIR" ]; then
    log_error "Infrastructure directory not found: $INFRA_DIR"
    exit 1
fi

cd "$INFRA_DIR"

# Ensure Terragrunt is initialized (required for import)
log_info "Ensuring Terragrunt is initialized..."
if ! terragrunt init -input=false; then
    log_error "terragrunt init failed"
    exit 1
fi

# Resource address : AWS resource ID (name or ARN as required by provider)
# Secrets Manager moved to infrastructure-longterm; use import-existing-longterm.sh for those.
imports=(
    "module.aurora.aws_db_subnet_group.aurora:${PROJECT_NAME}-${ENVIRONMENT}-aurora-subnet-group"
    "module.iam.aws_iam_role.ecs_task_execution:${PROJECT_NAME}-${ENVIRONMENT}-ecs-task-execution-role"
    "module.iam.aws_iam_role.ecs_task_runtime:${PROJECT_NAME}-${ENVIRONMENT}-ecs-task-runtime-role"
)

failed=0
for import_spec in "${imports[@]}"; do
    IFS=':' read -r resource id <<< "$import_spec"
    log_info "Importing $resource..."
    tmp_log="$(mktemp)"
    if terragrunt import "$resource" "$id" >"$tmp_log" 2>&1; then
        if grep -qiE "Import (prepared|successful|complete)|Resource already managed" "$tmp_log"; then
            log_success "  OK: $resource"
        elif grep -qiE "Error|error" "$tmp_log"; then
            log_warning "  Import may have issues for $resource"
            tail -5 "$tmp_log" | while IFS= read -r line; do log_info "    $line"; done
        else
            log_success "  OK: $resource"
        fi
    else
        # Already in state is common when re-running
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

if [ "$failed" -gt 0 ]; then
    log_warning "Some imports failed ($failed). Run 'terragrunt plan' to see remaining differences."
else
    log_success "Import phase completed."
fi
log_info "Run 'terragrunt plan' in $INFRA_DIR to verify state."
