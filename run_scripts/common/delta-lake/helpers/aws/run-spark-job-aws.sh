#!/bin/bash
# Run Spark job on AWS ECS to create Delta table
# Usage: run-spark-job-aws.sh <INPUT_PATH> <OUTPUT_PATH> <SPARK_PACKAGES> <CLUSTER_NAME> <SERVICE_NAME> <TASK_DEF_ARN>

set -e

INPUT_PATH="$1"
OUTPUT_PATH="$2"
SPARK_PACKAGES="$3"
CLUSTER_NAME="$4"
SERVICE_NAME="$5"
TASK_DEF_ARN="${6:-}"
AWS_PROFILE="${AWS_PROFILE:-admin}"
AWS_REGION="${AWS_REGION:-us-east-1}"

if [ -z "$INPUT_PATH" ] || [ -z "$OUTPUT_PATH" ] || [ -z "$SPARK_PACKAGES" ] || [ -z "$CLUSTER_NAME" ] || [ -z "$SERVICE_NAME" ]; then
    echo "Error: INPUT_PATH, OUTPUT_PATH, SPARK_PACKAGES, CLUSTER_NAME, and SERVICE_NAME are required" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../../logger.sh"

# Get task definition from service if not provided
if [ -z "$TASK_DEF_ARN" ]; then
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
fi

log_info "Using task definition: $TASK_DEF_ARN"

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

# Build the command to run
SPARK_CMD="/opt/spark/bin/spark-submit --packages $SPARK_PACKAGES /app/spark_jobs/ingest_delta.py $INPUT_PATH $OUTPUT_PATH"

log_info "Spark command: $SPARK_CMD"

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

# Prepare command override JSON
COMMAND_OVERRIDE_JSON=$(jq -n \
    --arg cmd "$SPARK_CMD" \
    '{
        "containerOverrides": [{
            "name": "api",
            "command": ["sh", "-c", $cmd]
        }]
    }')

# Run one-time ECS task with overridden command
log_info "Starting one-time ECS task to create Delta table..."
log_info "This may take a few minutes..."

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
    log_error "Failed to start ECS task"
    exit 1
fi

log_info "Task started: $TASK_ARN"
log_info "Waiting for task to complete..."

# Wait for task to complete (with timeout)
TIMEOUT=600  # 10 minutes
ELAPSED=0
while [ $ELAPSED -lt $TIMEOUT ]; do
    TASK_STATUS=$(aws ecs describe-tasks \
        --cluster "$CLUSTER_NAME" \
        --tasks "$TASK_ARN" \
        --profile "$AWS_PROFILE" \
        --region "$AWS_REGION" \
        --query 'tasks[0].lastStatus' \
        --output text 2>&1)
    
    if [ "$TASK_STATUS" = "STOPPED" ]; then
        # Get exit code
        EXIT_CODE=$(aws ecs describe-tasks \
            --cluster "$CLUSTER_NAME" \
            --tasks "$TASK_ARN" \
            --profile "$AWS_PROFILE" \
            --region "$AWS_REGION" \
            --query 'tasks[0].containers[0].exitCode' \
            --output text 2>&1)
        
        if [ "$EXIT_CODE" = "0" ] || [ "$EXIT_CODE" = "0.0" ]; then
            log_success "Delta table created successfully in S3"
            log_info "Delta table path: $OUTPUT_PATH"
            
            # Get logs for verification
            LOG_GROUP="/ecs/${CLUSTER_NAME}"
            LOG_STREAM=$(aws ecs describe-tasks \
                --cluster "$CLUSTER_NAME" \
                --tasks "$TASK_ARN" \
                --profile "$AWS_PROFILE" \
                --region "$AWS_REGION" \
                --query 'tasks[0].containers[0].logStreamName' \
                --output text 2>&1)
            
            if [ -n "$LOG_STREAM" ] && [ "$LOG_STREAM" != "None" ]; then
                log_info "Task logs available at: $LOG_GROUP/$LOG_STREAM"
            fi
            
            exit 0
        else
            log_error "Task failed with exit code: $EXIT_CODE"
            
            # Get stopped reason
            STOPPED_REASON=$(aws ecs describe-tasks \
                --cluster "$CLUSTER_NAME" \
                --tasks "$TASK_ARN" \
                --profile "$AWS_PROFILE" \
                --region "$AWS_REGION" \
                --query 'tasks[0].stoppedReason' \
                --output text 2>&1)
            
            log_error "Stopped reason: $STOPPED_REASON"
            
            # Get logs
            LOG_GROUP="/ecs/${CLUSTER_NAME}"
            LOG_STREAM=$(aws ecs describe-tasks \
                --cluster "$CLUSTER_NAME" \
                --tasks "$TASK_ARN" \
                --profile "$AWS_PROFILE" \
                --region "$AWS_REGION" \
                --query 'tasks[0].containers[0].logStreamName' \
                --output text 2>&1)
            
            if [ -n "$LOG_STREAM" ] && [ "$LOG_STREAM" != "None" ]; then
                log_info "Fetching task logs..."
                aws logs tail "$LOG_GROUP" --log-stream-names "$LOG_STREAM" --since 30m --profile "$AWS_PROFILE" --region "$AWS_REGION" 2>&1 | tail -50
            fi
            
            exit 1
        fi
    fi
    
    sleep 5
    ELAPSED=$((ELAPSED + 5))
    if [ $((ELAPSED % 30)) -eq 0 ]; then
        log_info "Still waiting... ($ELAPSED seconds elapsed)"
    fi
done

log_error "Task did not complete within timeout ($TIMEOUT seconds)"
exit 1

