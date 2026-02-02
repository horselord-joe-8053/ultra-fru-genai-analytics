#!/bin/bash
#
# Import existing ECS-layer AWS resources into Terraform state (CloudWatch log group, ALB, target group).
# Use when apply fails with "already exists" for these resources (state/reality mismatch).
#
# USAGE: ./import-existing-ecs.sh [dev|prod] [project_name]
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../../.." && pwd)}"
source "$REPO_ROOT/orchestration/common/logger.sh"
source "$REPO_ROOT/orchestration/common/env/load-env.sh"
load_env_file || true

ENVIRONMENT="${1:-dev}"
PROJECT_NAME="${2:-fru}"
ECS_DIR="$REPO_ROOT/module_infra_kubetypes/nonkube/aws/terra/environments/$ENVIRONMENT/ecs"
AWS_PROFILE="${AWS_PROFILE:-admin}"
AWS_REGION="${AWS_REGION:-us-east-1}"

if [[ ! "$ENVIRONMENT" =~ ^(dev|staging|prod)$ ]]; then
    log_error "Invalid environment: $ENVIRONMENT"
    log_info "Usage: $0 [dev|staging|prod] [project_name]"
    exit 1
fi

if [ ! -d "$ECS_DIR" ]; then
    log_error "ECS directory not found: $ECS_DIR"
    exit 1
fi

log_step "Importing existing ECS-layer resources into Terraform state"
log_info "Environment: $ENVIRONMENT  Project: $PROJECT_NAME"

cd "$ECS_DIR"
terragrunt init -input=false || true

run_import() {
    local addr="$1" id="$2"
    local tmp_log; tmp_log="$(mktemp)"
    if terragrunt import "$addr" "$id" >"$tmp_log" 2>&1; then
        log_success "  OK: $addr"
    elif grep -qi "already managed by Terraform\|Resource already managed" "$tmp_log"; then
        log_success "  OK (already in state): $addr"
    else
        log_warning "  Import failed or skip: $addr"
        tail -3 "$tmp_log" | while IFS= read -r line; do log_info "    $line"; done
    fi
    rm -f "$tmp_log"
}

# 1. CloudWatch log group – ID is the name
LOG_GROUP_NAME="/ecs/${PROJECT_NAME}-${ENVIRONMENT}"
log_info "Importing aws_cloudwatch_log_group.ecs ($LOG_GROUP_NAME)..."
run_import "aws_cloudwatch_log_group.ecs" "$LOG_GROUP_NAME"

# 2. ALB – ID is the ARN
ALB_NAME="${PROJECT_NAME}-${ENVIRONMENT}-alb"
ALB_ARN=$(aws elbv2 describe-load-balancers --names "$ALB_NAME" --region "$AWS_REGION" --profile "$AWS_PROFILE" --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null || echo "")
if [ -n "$ALB_ARN" ] && [ "$ALB_ARN" != "None" ]; then
    log_info "Importing module.alb.aws_lb.main..."
    run_import "module.alb.aws_lb.main" "$ALB_ARN"
else
    log_info "  Skip (ALB not found): module.alb.aws_lb.main"
fi

# 3. Target group – ID is the ARN
TG_NAME="${PROJECT_NAME}-${ENVIRONMENT}-tg"
TG_ARN=$(aws elbv2 describe-target-groups --names "$TG_NAME" --region "$AWS_REGION" --profile "$AWS_PROFILE" --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null || echo "")
if [ -n "$TG_ARN" ] && [ "$TG_ARN" != "None" ]; then
    log_info "Importing module.alb.aws_lb_target_group.ecs..."
    run_import "module.alb.aws_lb_target_group.ecs" "$TG_ARN"
else
    log_info "  Skip (target group not found): module.alb.aws_lb_target_group.ecs"
fi

log_success "ECS import phase completed."
log_info "Run 'terragrunt plan' in $ECS_DIR to verify."
