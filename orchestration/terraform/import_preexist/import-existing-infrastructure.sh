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
source "$SCRIPT_DIR/common/lib_import_common.sh"

import_parse_args "$@"
import_validate_env

INFRA_DIR="$REPO_ROOT/module_infra_basic/aws/terra/environments/$ENVIRONMENT/infrastructure"

log_step "Importing existing infrastructure into Terraform state"
log_info "Environment: $ENVIRONMENT"
log_info "Project name: $PROJECT_NAME"
log_info "Infrastructure dir: $INFRA_DIR"

import_ensure_dir_and_cd "$INFRA_DIR" "Infrastructure"
import_init_strict

# Resource address : AWS resource ID (name or ARN as required by provider)
# Secrets Manager moved to infrastructure-longterm; use import-existing-longterm.sh for those.
import_batch \
    "module.aurora.aws_db_subnet_group.aurora:${PROJECT_NAME}-${ENVIRONMENT}-aurora-subnet-group" \
    "module.iam.aws_iam_role.ecs_task_execution:${PROJECT_NAME}-${ENVIRONMENT}-ecs-task-execution-role" \
    "module.iam.aws_iam_role.ecs_task_runtime:${PROJECT_NAME}-${ENVIRONMENT}-ecs-task-runtime-role"

log_info "Run 'terragrunt plan' in $INFRA_DIR to verify state."
