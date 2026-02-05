#!/bin/bash
# ECS-specific diagnostics for API failures.
# Called indirectly via the common verification dispatcher in:
#   run_scripts/main_application_scripts/aws/verification/diagnose-failures.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../../../.." && pwd)}"

# Source shared logger if not already available
if ! command -v log_info >/dev/null 2>&1; then
  # shellcheck source=/dev/null
  source "$REPO_ROOT/lib/logger.sh" 2>/dev/null || true
fi

# Default ECS log group (can be overridden via env)
ECS_LOG_GROUP="${ECS_LOG_GROUP:-/ecs/fru-dev}"

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

ecs_diagnose_api_failure() {
  if ! command_exists aws; then
    log_warning "aws CLI not available; cannot auto-diagnose ECS API failure"
    return 1
  fi

  local cluster_name="${ECS_CLUSTER_NAME:-fru-dev-cluster}"
  local service_name="${ECS_SERVICE_NAME:-fru-dev-api-service}"
  local region="${AWS_REGION:-us-east-1}"
  local profile="${AWS_PROFILE:-admin}"

  echo ""
  log_step "Diagnosing ECS API service failure (cluster: $cluster_name, service: $service_name)"

  # Recent ECS service events
  log_info "Fetching recent ECS service events..."
  aws ecs describe-services \
    --cluster "$cluster_name" \
    --services "$service_name" \
    --profile "$profile" \
    --region "$region" \
    --query 'services[0].events[0:5]' \
    --output table 2>/dev/null || log_warning "Could not fetch ECS service events"

  # Task statuses
  log_info "Fetching ECS task statuses..."
  aws ecs list-tasks \
    --cluster "$cluster_name" \
    --service-name "$service_name" \
    --profile "$profile" \
    --region "$region" \
    --desired-status RUNNING \
    --query 'taskArns' \
    --output text 2>/dev/null | \
    awk '{for(i=1;i<=NF;i++)print $i}' | \
    xargs -r aws ecs describe-tasks \
      --cluster "$cluster_name" \
      --profile "$profile" \
      --region "$region" \
      --tasks \
      --query 'tasks[].{lastStatus:lastStatus,healthStatus:healthStatus,stoppedReason:stoppedReason,containers:containers[].{name:name,lastStatus:lastStatus,reason:reason}}' \
      --output table 2>/dev/null || log_warning "Could not fetch ECS task details"

  # Recent logs from CloudWatch
  if [ -n "$ECS_LOG_GROUP" ]; then
    log_info "Fetching recent CloudWatch logs from $ECS_LOG_GROUP (last 10 minutes, tail)..."
    local logs_output
    logs_output=$(aws logs tail "$ECS_LOG_GROUP" --since 10m --profile "$profile" --region "$region" 2>/dev/null || echo "")
    if [ -n "$logs_output" ]; then
      echo "$logs_output" | tail -40

      # Highlight common database auth errors
      if echo "$logs_output" | grep -qi "password authentication failed for user"; then
        log_error "Detected database authentication failures in logs (e.g., 'password authentication failed for user')."
        log_error "This usually means the Aurora DB password/username used by the API does not match the actual database credentials."
      fi
    else
      log_warning "No recent logs found or unable to read CloudWatch logs"
    fi
  fi

  return 0
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  ecs_diagnose_api_failure
fi


