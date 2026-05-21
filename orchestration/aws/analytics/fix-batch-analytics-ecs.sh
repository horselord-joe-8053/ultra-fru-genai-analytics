#!/bin/bash
# Fix or test Batch Analytics on ECS without running full preempt.
#
# Use when: Batch Analytics panel is empty (ENABLE_ANALYTICS_SCHEDULER was not
# in env when Terraform ran) or you want to populate data once.
#
# Usage:
#   ./fix-batch-analytics-ecs.sh [--fix-task-def] [--trigger-once] [dev|prod]
#
# Options:
#   --fix-task-def   Re-apply ECS Terraform with .env loaded so task definition
#                    gets ENABLE_ANALYTICS_SCHEDULER=true, then force ECS deployment.
#   --trigger-once   Run a one-off ECS task to populate batch_analytics (no Terraform).
#   (default)        If no option: runs --fix-task-def.
#
# Examples:
#   ./fix-batch-analytics-ecs.sh --fix-task-def dev
#   ./fix-batch-analytics-ecs.sh --trigger-once dev
#   ./fix-batch-analytics-ecs.sh --fix-task-def --trigger-once dev
#
# Prerequisites:
#   - ECS cluster and service already exist (e.g. from a previous full deploy).
#   - For --fix-task-def: .env has ENABLE_ANALYTICS_SCHEDULER=true; AWS credentials.
#   - For --trigger-once: Delta table and S3 already set up; AWS credentials.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../../.." && pwd)}"
source "$REPO_ROOT/lib/logger.sh"
source "$REPO_ROOT/orchestration/common/env/load-env.sh"

ENVIRONMENT="${ENVIRONMENT:-dev}"
FIX_TASK_DEF=false
TRIGGER_ONCE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --fix-task-def)   FIX_TASK_DEF=true; shift ;;
        --trigger-once)   TRIGGER_ONCE=true; shift ;;
        dev|prod)         ENVIRONMENT="$1"; shift ;;
        *)                log_error "Unknown option: $1"; exit 1 ;;
    esac
done

# Default: fix task def if no option given
if [ "$FIX_TASK_DEF" != "true" ] && [ "$TRIGGER_ONCE" != "true" ]; then
    FIX_TASK_DEF=true
fi

ECS_TERRAFORM_DIR="$REPO_ROOT/module_infra_kubetypes/nonkube/aws/terra/environments/$ENVIRONMENT/ecs"
TRIGGER_SCRIPT="$REPO_ROOT/module_infra_spark/common/delta-lake/helpers/aws/trigger-analytics-aws.sh"

if [ "$FIX_TASK_DEF" = "true" ]; then
    log_step "Re-applying ECS layer so task definition gets ENABLE_ANALYTICS_SCHEDULER from .env"
    load_env_file || true
    export ENABLE_ANALYTICS_SCHEDULER="${ENABLE_ANALYTICS_SCHEDULER:-false}"
    log_info "ENABLE_ANALYTICS_SCHEDULER=$ENABLE_ANALYTICS_SCHEDULER"
    if [ "$ENABLE_ANALYTICS_SCHEDULER" != "true" ]; then
        log_warning ".env has ENABLE_ANALYTICS_SCHEDULER=$ENABLE_ANALYTICS_SCHEDULER; set to true in .env if you want the scheduler to run in the service."
    fi
    CONTAINER_TYPE=ecs "$REPO_ROOT/orchestration/terraform/deploy.sh" "$ENVIRONMENT" ecs || exit 1
    log_success "ECS Terraform apply done. Forcing ECS service deployment so new tasks use new task definition..."
    CLUSTER_NAME=$(cd "$ECS_TERRAFORM_DIR" && terragrunt output -raw cluster_name 2>/dev/null || true)
    SERVICE_NAME=$(cd "$ECS_TERRAFORM_DIR" && terragrunt output -raw service_name 2>/dev/null || true)
    if [ -n "$CLUSTER_NAME" ] && [ -n "$SERVICE_NAME" ]; then
        aws ecs update-service --cluster "$CLUSTER_NAME" --service "$SERVICE_NAME" \
            --force-new-deployment \
            --profile "${AWS_PROFILE:-admin}" \
            --region "${AWS_REGION:-us-east-1}" \
            --output text --query 'service.serviceName' 2>/dev/null || true
        log_success "Forced new deployment. New tasks will start with updated env (may take 1–2 min)."
    else
        log_warning "Could not get cluster/service from Terraform output; force deployment manually: aws ecs update-service --cluster <name> --service <name> --force-new-deployment"
    fi
fi

if [ "$TRIGGER_ONCE" = "true" ]; then
    log_step "Running one-off analytics task to populate batch_analytics"
    if [ ! -x "$TRIGGER_SCRIPT" ]; then
        log_error "Trigger script not found or not executable: $TRIGGER_SCRIPT"
        exit 1
    fi
    CLUSTER_NAME=$(cd "$ECS_TERRAFORM_DIR" && terragrunt output -raw cluster_name 2>/dev/null || true)
    SERVICE_NAME=$(cd "$ECS_TERRAFORM_DIR" && terragrunt output -raw service_name 2>/dev/null || true)
    if [ -z "$CLUSTER_NAME" ] || [ -z "$SERVICE_NAME" ]; then
        log_error "Could not get cluster_name or service_name from: cd $ECS_TERRAFORM_DIR && terragrunt output"
        exit 1
    fi
    REPO_ROOT="$REPO_ROOT" "$TRIGGER_SCRIPT" "$CLUSTER_NAME" "$SERVICE_NAME" || exit 1
    log_success "One-off analytics task started. Check /analytics in a few minutes."
fi
