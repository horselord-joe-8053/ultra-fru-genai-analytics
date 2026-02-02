#!/bin/bash
#
# Import existing EKS-layer AWS resources into Terraform state (IAM roles, KMS alias, CloudWatch log group).
#
# PURPOSE:
#   When the brutal removal script (or manual teardown) deletes the EKS cluster but leaves IAM roles,
#   KMS alias, and CloudWatch log group in AWS, the next "terragrunt apply" for EKS fails with
#   "EntityAlreadyExists" / "AlreadyExistsException". This script imports those resources so
#   Terraform manages them and apply can succeed.
#
# WHEN TO USE:
#   - After running remove-all-aws-resources.sh and then re-deploying EKS (resources left behind).
#   - Terraform state was lost/recreated but EKS-supporting resources still exist in AWS.
#
# WHAT IT IMPORTS (per environment):
#   - aws_iam_role.eks_cluster
#   - aws_iam_role.eks_node_group[0]
#   - aws_iam_role.eks_fargate_pod_execution[0]
#   - aws_kms_key.eks_secrets[0] (if alias exists; key ID looked up from alias)
#   - aws_kms_alias.eks_secrets[0]
#   - aws_cloudwatch_log_group.eks_cluster
#
# Imports are idempotent: if a resource is already in state, the import is skipped.
# Safe to run always: if resources were already torn down via Terraform (or never created),
# Terraform reports "Cannot import non-existent remote object" and the script skips them;
# the next apply will then create those resources. No double-create, no broken state.
#
# USAGE:
#   ./import-existing-eks.sh [dev|prod] [project_name]
#
#   Examples:
#     ./import-existing-eks.sh dev
#     ./import-existing-eks.sh prod fru
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../../.." && pwd)}"
source "$REPO_ROOT/orchestration/common/logger.sh"
source "$REPO_ROOT/orchestration/common/env/load-env.sh"
load_env_file || true

ENVIRONMENT="${1:-dev}"
PROJECT_NAME="${2:-fru}"
EKS_DIR="$REPO_ROOT/module_infra_kubetypes/kube/aws/terra/environments/$ENVIRONMENT/eks"
AWS_PROFILE="${AWS_PROFILE:-admin}"
AWS_REGION="${AWS_REGION:-us-east-1}"

if [[ ! "$ENVIRONMENT" =~ ^(dev|staging|prod)$ ]]; then
    log_error "Invalid environment: $ENVIRONMENT"
    log_info "Usage: $0 [dev|staging|prod] [project_name]"
    exit 1
fi

if [ ! -d "$EKS_DIR" ]; then
    log_error "EKS directory not found: $EKS_DIR"
    exit 1
fi

log_step "Importing existing EKS-layer resources into Terraform state"
log_info "Environment: $ENVIRONMENT  Project: $PROJECT_NAME"
log_info "EKS dir: $EKS_DIR"

cd "$EKS_DIR"
log_info "Ensuring Terragrunt is initialized..."
terragrunt init -input=false || true

run_import() {
    local addr="$1" id="$2"
    local tmp_log; tmp_log="$(mktemp)"
    if terragrunt import "$addr" "$id" >"$tmp_log" 2>&1; then
        log_success "  OK: $addr"
    elif grep -qi "already managed by Terraform\|Resource already managed" "$tmp_log"; then
        log_success "  OK (already in state): $addr"
    elif grep -qi "Cannot import non-existent remote object" "$tmp_log"; then
        log_info "  Skip (resource does not exist in AWS): $addr"
    else
        log_warning "  Import failed or skip: $addr"
        tail -5 "$tmp_log" | while IFS= read -r line; do log_info "    $line"; done
    fi
    rm -f "$tmp_log"
}

# 1. IAM roles (import by role name)
ROLE_CLUSTER="${PROJECT_NAME}-${ENVIRONMENT}-eks-cluster-role"
ROLE_NODE_GROUP="${PROJECT_NAME}-${ENVIRONMENT}-eks-node-group-role"
ROLE_FARGATE="${PROJECT_NAME}-${ENVIRONMENT}-eks-fargate-pod-execution-role"

log_info "Importing aws_iam_role.eks_cluster ($ROLE_CLUSTER)..."
run_import "aws_iam_role.eks_cluster" "$ROLE_CLUSTER"

log_info "Importing aws_iam_role.eks_node_group[0] ($ROLE_NODE_GROUP)..."
run_import "aws_iam_role.eks_node_group[0]" "$ROLE_NODE_GROUP"

log_info "Importing aws_iam_role.eks_fargate_pod_execution[0] ($ROLE_FARGATE)..."
run_import "aws_iam_role.eks_fargate_pod_execution[0]" "$ROLE_FARGATE"

# 2. KMS alias (and key if alias exists)
KMS_ALIAS_NAME="alias/${PROJECT_NAME}-${ENVIRONMENT}-eks-secrets"
KEY_ID=$(aws kms describe-key --key-id "$KMS_ALIAS_NAME" --region "$AWS_REGION" --profile "$AWS_PROFILE" --query 'KeyMetadata.KeyId' --output text 2>/dev/null || echo "")
if [ -n "$KEY_ID" ] && [ "$KEY_ID" != "None" ]; then
    log_info "Importing aws_kms_key.eks_secrets[0] (key $KEY_ID)..."
    run_import "aws_kms_key.eks_secrets[0]" "$KEY_ID"
    log_info "Importing aws_kms_alias.eks_secrets[0] ($KMS_ALIAS_NAME)..."
    run_import "aws_kms_alias.eks_secrets[0]" "$KMS_ALIAS_NAME"
else
    log_info "  Skip KMS (alias/key not found): $KMS_ALIAS_NAME"
fi

# 3. CloudWatch log group (ID is the log group name)
LOG_GROUP_NAME="/aws/eks/${PROJECT_NAME}-${ENVIRONMENT}-cluster/cluster"
log_info "Importing aws_cloudwatch_log_group.eks_cluster ($LOG_GROUP_NAME)..."
run_import "aws_cloudwatch_log_group.eks_cluster" "$LOG_GROUP_NAME"

log_success "EKS import phase completed."
log_info "Run 'terragrunt plan' in $EKS_DIR to verify, then 'terragrunt apply' to continue."
