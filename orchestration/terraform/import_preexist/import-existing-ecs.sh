#!/bin/bash
#
# Import existing ECS-layer AWS resources into Terraform state (CloudWatch log group, ALB, target group).
# Use when apply fails with "already exists" for these resources (state/reality mismatch).
#
# USAGE: ./import-existing-ecs.sh [dev|prod] [project_name]
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common/lib_import_common.sh"

import_parse_args "$@"
import_validate_env

ECS_DIR="$REPO_ROOT/module_infra_kubetypes/nonkube/aws/terra/environments/$ENVIRONMENT/ecs"
AWS_PROFILE="${AWS_PROFILE:-admin}"
AWS_REGION="${AWS_REGION:-us-east-1}"

log_step "Importing existing ECS-layer resources into Terraform state"
log_info "Environment: $ENVIRONMENT  Project: $PROJECT_NAME"

import_ensure_dir_and_cd "$ECS_DIR" "ECS"
import_init_soft

# 1. CloudWatch log group – ID is the name
LOG_GROUP_NAME="/ecs/${PROJECT_NAME}-${ENVIRONMENT}"
log_info "Importing aws_cloudwatch_log_group.ecs ($LOG_GROUP_NAME)..."
import_one_resource "aws_cloudwatch_log_group.ecs" "$LOG_GROUP_NAME"

# 2. ALB – ID is the ARN
ALB_NAME="${PROJECT_NAME}-${ENVIRONMENT}-alb"
ALB_ARN=$(aws elbv2 describe-load-balancers --names "$ALB_NAME" --region "$AWS_REGION" --profile "$AWS_PROFILE" --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null || echo "")
if [ -n "$ALB_ARN" ] && [ "$ALB_ARN" != "None" ]; then
    log_info "Importing module.alb.aws_lb.main..."
    import_one_resource "module.alb.aws_lb.main" "$ALB_ARN"
else
    log_info "  Skip (ALB not found): module.alb.aws_lb.main"
fi

# 3. Target group – ID is the ARN
TG_NAME="${PROJECT_NAME}-${ENVIRONMENT}-tg"
TG_ARN=$(aws elbv2 describe-target-groups --names "$TG_NAME" --region "$AWS_REGION" --profile "$AWS_PROFILE" --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null || echo "")
if [ -n "$TG_ARN" ] && [ "$TG_ARN" != "None" ]; then
    log_info "Importing module.alb.aws_lb_target_group.ecs..."
    import_one_resource "module.alb.aws_lb_target_group.ecs" "$TG_ARN"
else
    log_info "  Skip (target group not found): module.alb.aws_lb_target_group.ecs"
fi

log_success "ECS import phase completed."
log_info "Run 'terragrunt plan' in $ECS_DIR to verify."
