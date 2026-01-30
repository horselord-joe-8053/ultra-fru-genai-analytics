#!/bin/bash
# Run Spark job on AWS ECS to create Delta table
# Executes spark-submit in ECS task with S3A configuration
#
# Usage: run-spark-job-aws.sh <INPUT_PATH> <OUTPUT_PATH> <SPARK_PACKAGES> <CLUSTER_NAME> <SERVICE_NAME> [TASK_DEF_ARN]
#   INPUT_PATH: S3 CSV path (s3a://)
#   OUTPUT_PATH: S3 Delta table path (s3a://)
#   SPARK_PACKAGES: Maven coordinates
#   CLUSTER_NAME: ECS cluster name
#   SERVICE_NAME: ECS service name
#   TASK_DEF_ARN: Optional task definition ARN (auto-detected if not provided)

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
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../../../../../.." && pwd)}"
source "$REPO_ROOT/run_scripts/shared/load-env.sh"
# Load .env file if available (for AWS credentials)
[ -f "$REPO_ROOT/.env" ] && load_env_file 2>/dev/null || true

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

# Get S3A configuration from Python helper (single source of truth)
# REPO_ROOT already defined above, but ensure it's set if not already
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../../../../../.." && pwd)}"
S3A_CONFIG=$("$PYTHON_CMD" -c "
import sys
sys.path.insert(0, '$REPO_ROOT')
from spark_jobs.utils.spark_config import get_s3a_spark_config
import shlex
print(' '.join(shlex.quote(arg) for arg in get_s3a_spark_config()))
" 2>/dev/null)

if [ -z "$S3A_CONFIG" ]; then
    log_error "Failed to get S3A config from Python helper"
    exit 1
fi

# Build Spark command with S3A configuration
SPARK_CMD="/opt/spark/bin/spark-submit --packages $SPARK_PACKAGES $S3A_CONFIG /app/spark_jobs/ingest_delta.py $INPUT_PATH $OUTPUT_PATH"

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
# ECS Fargate doesn't support overriding entryPoint, so we override command only.
# The command will be executed by the container's default entrypoint.
# We use /bin/sh -c to execute the spark-submit command as a shell command.
COMMAND_OVERRIDE_JSON=$(jq -n \
    --arg cmd "$SPARK_CMD" \
    --arg container "$CONTAINER_NAME" \
    '{
        "containerOverrides": [{
            "name": $container,
            "command": ["/bin/sh", "-c", $cmd]
        }]
    }')

# Run one-time ECS task with overridden command
log_info "Starting one-time ECS task to create Delta table..."
log_info "This may take a few minutes..."

# Capture both stdout and stderr, and exit code
set +e  # Temporarily disable exit on error to capture the full response
TASK_RUN_OUTPUT=$(aws ecs run-task \
    --cluster "$CLUSTER_NAME" \
    --task-definition "$TASK_DEF_ARN" \
    --launch-type FARGATE \
    --network-configuration "$NETWORK_CONFIG_JSON" \
    --overrides "$COMMAND_OVERRIDE_JSON" \
    --profile "$AWS_PROFILE" \
    --region "$AWS_REGION" \
    2>&1)
TASK_RUN_EXIT_CODE=$?
set -e  # Re-enable exit on error

if [ $TASK_RUN_EXIT_CODE -ne 0 ]; then
    log_error "Failed to start ECS task (exit code: $TASK_RUN_EXIT_CODE)"
    log_error "AWS CLI output:"
    echo "$TASK_RUN_OUTPUT" | while IFS= read -r line; do
        log_error "  $line"
    done
    exit 1
fi

# Try to extract task ARN using jq if available, otherwise use grep/sed
if command -v jq >/dev/null 2>&1; then
    TASK_ARN=$(echo "$TASK_RUN_OUTPUT" | jq -r '.tasks[0].taskArn' 2>/dev/null)
    FAILURES=$(echo "$TASK_RUN_OUTPUT" | jq -r '.failures[]?.reason' 2>/dev/null | head -1)
else
    # Fallback: extract task ARN using grep/sed
    TASK_ARN=$(echo "$TASK_RUN_OUTPUT" | grep -o '"taskArn"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*"taskArn"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/' | head -1)
    FAILURES=$(echo "$TASK_RUN_OUTPUT" | grep -o '"reason"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*"reason"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/' | head -1)
fi

if [ -z "$TASK_ARN" ] || [ "$TASK_ARN" = "None" ] || [ "$TASK_ARN" = "null" ]; then
    log_error "Failed to get task ARN from ECS run-task response"
    log_error "AWS CLI output:"
    echo "$TASK_RUN_OUTPUT" | while IFS= read -r line; do
        log_error "  $line"
    done
    # Check for failures in the response
    if [ -n "$FAILURES" ]; then
        log_error "ECS task failures: $FAILURES"
    fi
    exit 1
fi

# Check for failures even if we got a task ARN (partial success)
if [ -n "$FAILURES" ]; then
    log_warning "ECS task started but there were failures: $FAILURES"
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
            # Log group name is /ecs/{project}-{environment}, not /ecs/{cluster-name}
            # Extract environment from cluster name (e.g., "fru-dev-cluster" -> "dev")
            ENV_FROM_CLUSTER=$(echo "$CLUSTER_NAME" | sed 's/.*-\([^-]*\)-cluster$/\1/')
            if [ -z "$ENV_FROM_CLUSTER" ] || [ "$ENV_FROM_CLUSTER" = "$CLUSTER_NAME" ]; then
                # Fallback: try to get from task definition or use default pattern
                LOG_GROUP="/ecs/fru-${ENV_FROM_CLUSTER:-dev}"
            else
                LOG_GROUP="/ecs/fru-${ENV_FROM_CLUSTER}"
            fi
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
            # Log group name is /ecs/{project}-{environment}, not /ecs/{cluster-name}
            # Extract environment from cluster name (e.g., "fru-dev-cluster" -> "dev")
            ENV_FROM_CLUSTER=$(echo "$CLUSTER_NAME" | sed 's/.*-\([^-]*\)-cluster$/\1/')
            if [ -z "$ENV_FROM_CLUSTER" ] || [ "$ENV_FROM_CLUSTER" = "$CLUSTER_NAME" ]; then
                # Fallback: try to get from task definition or use default pattern
                LOG_GROUP="/ecs/fru-${ENV_FROM_CLUSTER:-dev}"
            else
                LOG_GROUP="/ecs/fru-${ENV_FROM_CLUSTER}"
            fi
            LOG_STREAM=$(aws ecs describe-tasks \
                --cluster "$CLUSTER_NAME" \
                --tasks "$TASK_ARN" \
                --profile "$AWS_PROFILE" \
                --region "$AWS_REGION" \
                --query 'tasks[0].containers[0].logStreamName' \
                --output text 2>&1)
            
            if [ -n "$LOG_STREAM" ] && [ "$LOG_STREAM" != "None" ]; then
                log_info "Fetching task logs (full output) from $LOG_GROUP/$LOG_STREAM..."
                aws logs tail "$LOG_GROUP" --log-stream-names "$LOG_STREAM" --since 30m --profile "$AWS_PROFILE" --region "$AWS_REGION" 2>&1
            else
                log_warning "No log stream available for task (task may have failed before writing logs)"
                log_info "Trying to get logs from most recent log stream in $LOG_GROUP..."
                RECENT_STREAM=$(aws logs describe-log-streams --log-group-name "$LOG_GROUP" --profile "$AWS_PROFILE" --region "$AWS_REGION" --order-by LastEventTime --descending --max-items 1 --query 'logStreams[0].logStreamName' --output text 2>&1)
                if [ -n "$RECENT_STREAM" ] && [ "$RECENT_STREAM" != "None" ]; then
                    log_info "Fetching logs from most recent stream: $RECENT_STREAM"
                    aws logs tail "$LOG_GROUP" --log-stream-names "$RECENT_STREAM" --since 30m --profile "$AWS_PROFILE" --region "$AWS_REGION" 2>&1 | head -100
                fi
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

# Get final task status and logs even on timeout
TASK_STATUS=$(aws ecs describe-tasks \
    --cluster "$CLUSTER_NAME" \
    --tasks "$TASK_ARN" \
    --profile "$AWS_PROFILE" \
    --region "$AWS_REGION" \
    --query 'tasks[0].lastStatus' \
    --output text 2>&1)

log_error "Final task status: $TASK_STATUS"

# Get stopped reason if available
if [ "$TASK_STATUS" = "STOPPED" ]; then
    STOPPED_REASON=$(aws ecs describe-tasks \
        --cluster "$CLUSTER_NAME" \
        --tasks "$TASK_ARN" \
        --profile "$AWS_PROFILE" \
        --region "$AWS_REGION" \
        --query 'tasks[0].stoppedReason' \
        --output text 2>&1)
    log_error "Stopped reason: $STOPPED_REASON"
    
    EXIT_CODE=$(aws ecs describe-tasks \
        --cluster "$CLUSTER_NAME" \
        --tasks "$TASK_ARN" \
        --profile "$AWS_PROFILE" \
        --region "$AWS_REGION" \
        --query 'tasks[0].containers[0].exitCode' \
        --output text 2>&1)
    log_error "Exit code: $EXIT_CODE"
fi

# Try to fetch logs
ENV_FROM_CLUSTER=$(echo "$CLUSTER_NAME" | sed 's/.*-\([^-]*\)-cluster$/\1/')
if [ -z "$ENV_FROM_CLUSTER" ] || [ "$ENV_FROM_CLUSTER" = "$CLUSTER_NAME" ]; then
    LOG_GROUP="/ecs/fru-${ENV_FROM_CLUSTER:-dev}"
else
    LOG_GROUP="/ecs/fru-${ENV_FROM_CLUSTER}"
fi

LOG_STREAM=$(aws ecs describe-tasks \
    --cluster "$CLUSTER_NAME" \
    --tasks "$TASK_ARN" \
    --profile "$AWS_PROFILE" \
    --region "$AWS_REGION" \
    --query 'tasks[0].containers[0].logStreamName' \
    --output text 2>&1)

if [ -n "$LOG_STREAM" ] && [ "$LOG_STREAM" != "None" ]; then
    log_info "Fetching task logs from $LOG_GROUP/$LOG_STREAM..."
    aws logs tail "$LOG_GROUP" --log-stream-names "$LOG_STREAM" --since 30m --profile "$AWS_PROFILE" --region "$AWS_REGION" 2>&1 | tail -50
else
    log_warning "No log stream available for task"
fi

exit 1

