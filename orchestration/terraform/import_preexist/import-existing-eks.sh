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
source "$SCRIPT_DIR/common/lib_import_common.sh"

import_parse_args "$@"
import_validate_env

EKS_DIR="$REPO_ROOT/module_infra_kubetypes/kube/aws/terra/environments/$ENVIRONMENT/eks"
AWS_PROFILE="${AWS_PROFILE:-admin}"
AWS_REGION="${AWS_REGION:-us-east-1}"

log_step "Importing existing EKS-layer resources into Terraform state"
log_info "Environment: $ENVIRONMENT  Project: $PROJECT_NAME"
log_info "EKS dir: $EKS_DIR"

import_ensure_dir_and_cd "$EKS_DIR" "EKS"
import_init_soft

# 1. IAM roles (import by role name)
ROLE_CLUSTER="${PROJECT_NAME}-${ENVIRONMENT}-eks-cluster-role"
ROLE_NODE_GROUP="${PROJECT_NAME}-${ENVIRONMENT}-eks-node-group-role"
ROLE_FARGATE="${PROJECT_NAME}-${ENVIRONMENT}-eks-fargate-pod-execution-role"

log_info "Importing aws_iam_role.eks_cluster ($ROLE_CLUSTER)..."
import_one_resource "aws_iam_role.eks_cluster" "$ROLE_CLUSTER"

log_info "Importing aws_iam_role.eks_node_group[0] ($ROLE_NODE_GROUP)..."
import_one_resource "aws_iam_role.eks_node_group[0]" "$ROLE_NODE_GROUP"

log_info "Importing aws_iam_role.eks_fargate_pod_execution[0] ($ROLE_FARGATE)..."
import_one_resource "aws_iam_role.eks_fargate_pod_execution[0]" "$ROLE_FARGATE"

# 2. KMS alias (and key if alias exists)
KMS_ALIAS_NAME="alias/${PROJECT_NAME}-${ENVIRONMENT}-eks-secrets"
KEY_ID=$(aws kms describe-key --key-id "$KMS_ALIAS_NAME" --region "$AWS_REGION" --profile "$AWS_PROFILE" --query 'KeyMetadata.KeyId' --output text 2>/dev/null || echo "")
if [ -n "$KEY_ID" ] && [ "$KEY_ID" != "None" ]; then
    log_info "Importing aws_kms_key.eks_secrets[0] (key $KEY_ID)..."
    import_one_resource "aws_kms_key.eks_secrets[0]" "$KEY_ID"
    log_info "Importing aws_kms_alias.eks_secrets[0] ($KMS_ALIAS_NAME)..."
    import_one_resource "aws_kms_alias.eks_secrets[0]" "$KMS_ALIAS_NAME"
else
    log_info "  Skip KMS (alias/key not found): $KMS_ALIAS_NAME"
fi

# 3. CloudWatch log group (ID is the log group name)
LOG_GROUP_NAME="/aws/eks/${PROJECT_NAME}-${ENVIRONMENT}-cluster/cluster"
log_info "Importing aws_cloudwatch_log_group.eks_cluster ($LOG_GROUP_NAME)..."
import_one_resource "aws_cloudwatch_log_group.eks_cluster" "$LOG_GROUP_NAME"

log_success "EKS import phase completed."
log_info "Run 'terragrunt plan' in $EKS_DIR to verify, then 'terragrunt apply' to continue."
