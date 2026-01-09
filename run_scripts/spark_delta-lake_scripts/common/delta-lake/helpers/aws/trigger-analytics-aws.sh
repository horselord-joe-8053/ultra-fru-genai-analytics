#!/bin/bash
# Trigger analytics once in AWS ECS task
# Simple wrapper that creates ECS task with Python module execution
#
# Usage: trigger-analytics-aws.sh <CLUSTER_NAME> <SERVICE_NAME>
#   CLUSTER_NAME: ECS cluster name
#   SERVICE_NAME: ECS service name
#
# Environment Variables:
#   AWS_PROFILE: AWS profile (default: admin)
#   AWS_REGION: AWS region (default: us-east-1)

set -e

CLUSTER_NAME="$1"
SERVICE_NAME="$2"
AWS_PROFILE="${AWS_PROFILE:-admin}"
AWS_REGION="${AWS_REGION:-us-east-1}"

if [ -z "$CLUSTER_NAME" ] || [ -z "$SERVICE_NAME" ]; then
    echo "Error: CLUSTER_NAME and SERVICE_NAME are required" >&2
    echo "Usage: trigger-analytics-aws.sh <CLUSTER_NAME> <SERVICE_NAME>" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# From helpers/aws/ -> helpers/ -> delta-lake/ -> common/ -> spark_delta-lake_scripts/ -> run_scripts/ -> root (6 levels up)
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../../../../../../.." && pwd)}"
source "$REPO_ROOT/run_scripts/shared/logger.sh"

# Get task definition from service
TASK_DEF_ARN=$(aws ecs describe-services \
    --cluster "$CLUSTER_NAME" \
    --services "$SERVICE_NAME" \
    --profile "$AWS_PROFILE" \
    --region "$AWS_REGION" \
    --query 'services[0].taskDefinition' \
    --output text 2>&1)

if [ -z "$TASK_DEF_ARN" ] || [ "$TASK_DEF_ARN" = "None" ]; then
    log_error "Could not get task definition from service $SERVICE_NAME"
    exit 1
fi

log_info "Using task definition: $TASK_DEF_ARN"

# Get container name from task definition
CONTAINER_NAME=$(aws ecs describe-task-definition \
    --task-definition "$TASK_DEF_ARN" \
    --profile "$AWS_PROFILE" \
    --region "$AWS_REGION" \
    --query 'taskDefinition.containerDefinitions[0].name' \
    --output text 2>&1)

if [ -z "$CONTAINER_NAME" ] || [ "$CONTAINER_NAME" = "None" ]; then
    log_error "Could not get container name from task definition"
    exit 1
fi

log_info "Using container name: $CONTAINER_NAME"

# Get subnet IDs and security group from the service
SERVICE_DETAILS=$(aws ecs describe-services \
    --cluster "$CLUSTER_NAME" \
    --services "$SERVICE_NAME" \
    --profile "$AWS_PROFILE" \
    --region "$AWS_REGION" \
    --query 'services[0]' \
    --output json)

NETWORK_CONFIG=$(echo "$SERVICE_DETAILS" | jq -r '.networkConfiguration.awsvpcConfiguration')
SUBNET_IDS=$(echo "$NETWORK_CONFIG" | jq -r '.subnets[]' | tr '\n' ' ' | sed 's/ $//')
SECURITY_GROUP_IDS=$(echo "$NETWORK_CONFIG" | jq -r '.securityGroups[]? // empty' | tr '\n' ' ' | sed 's/ $//')

if [ -z "$SUBNET_IDS" ]; then
    log_error "Could not determine subnet IDs from service"
    exit 1
fi

log_info "Using subnets: $SUBNET_IDS"
if [ -n "$SECURITY_GROUP_IDS" ]; then
    log_info "Using security groups: $SECURITY_GROUP_IDS"
fi

# Prepare network configuration for run-task
NETWORK_CONFIG_JSON=$(jq -n \
    --arg subnets "$SUBNET_IDS" \
    --arg sgs "$SECURITY_GROUP_IDS" \
    '{
        "awsvpcConfiguration": {
            "subnets": ($subnets | split(" ") | map(select(length > 0))),
            "assignPublicIp": "DISABLED"
        } + (if $sgs != "" then {"securityGroups": ($sgs | split(" ") | map(select(length > 0)))} else {} end)
    }')

# Override entrypoint to Python and command to run our module
# Similar to run-spark-job-aws.sh but simpler (just Python, no spark-submit wrapper needed)
# The default entrypoint (docker-entrypoint.sh) would start Flask API and scheduler,
# so we override it to run Python directly.
COMMAND_OVERRIDE_JSON=$(jq -n \
    --arg container "$CONTAINER_NAME" \
    '{
        "containerOverrides": [{
            "name": $container,
            "entryPoint": ["python"],
            "command": ["/app/spark_jobs/utils/run_analytics_once.py"]
        }]
    }')

log_info "Starting analytics ECS task (runs independently)..."

# Run ECS task (non-blocking - task runs independently)
TASK_ARN=$(aws ecs run-task \
    --cluster "$CLUSTER_NAME" \
    --task-definition "$TASK_DEF_ARN" \
    --launch-type FARGATE \
    --network-configuration "$NETWORK_CONFIG_JSON" \
    --overrides "$COMMAND_OVERRIDE_JSON" \
    --profile "$AWS_PROFILE" \
    --region "$AWS_REGION" \
    --query 'tasks[0].taskArn' \
    --output text 2>&1)

if [ -z "$TASK_ARN" ] || [ "$TASK_ARN" = "None" ]; then
    log_error "Failed to start analytics ECS task"
    exit 1
fi

log_info "Analytics ECS task started: $TASK_ARN"
log_info "Task runs independently (non-blocking)"
log_info "Scheduler will also run analytics periodically (safety net)"

# Don't wait for completion - return immediately
exit 0

