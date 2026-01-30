#!/bin/bash
# Stop ECS Services (ECS Helper Function)
# =======================================
# This file contains a **helper function** for gracefully stopping all ECS
# services and tasks before Terraform destroy. It is meant to be **sourced**
# by teardown scripts, not run directly.
#
# **Container Type**: ECS-specific (uses AWS ECS APIs)
# **Location**: run_scripts/main_application_scripts/aws/ecs/helpers/
#
# Function:
#   stop_ecs_services <cluster_name> [aws_profile] [aws_region] [dry_run]
#
# Usage (from another script):
#   source "$REPO_ROOT/run_scripts/main_application_scripts/aws/ecs/helpers/stop-ecs-services.sh"
#   stop_ecs_services "$cluster_name" "$AWS_PROFILE" "$AWS_REGION" "$DRY_RUN"
#
# Example:
#   source "$REPO_ROOT/run_scripts/main_application_scripts/aws/ecs/helpers/stop-ecs-services.sh"
#   stop_ecs_services "fru-dev-cluster" "admin" "us-east-1" "false"
#
# Prerequisites:
#   - Parent script must source logger.sh before sourcing this file
#   - AWS CLI must be configured with ECS permissions
#   - REPO_ROOT environment variable should be set by parent script (optional)
#
# What it does:
#   1. Scales down all ECS services to desired count 0
#   2. Stops all running tasks (including one-off tasks)
#   3. Waits for all tasks to fully stop
#
# Why this is needed:
#   - Running tasks prevent cluster deletion
#   - Service tasks must be stopped (desired count set to 0)
#   - One-off tasks (e.g., Spark jobs via run-task) must be explicitly stopped
#   - Security groups cannot be deleted while still referenced by running tasks

stop_ecs_services() {
    local cluster_name="$1"
    local aws_profile="${2:-${AWS_PROFILE:-admin}}"
    local aws_region="${3:-${AWS_REGION:-us-east-1}}"
    local dry_run="${4:-${DRY_RUN:-false}}"
    
    log_step "Stopping ECS Services and Tasks"
    log_info "Cluster: $cluster_name"
    log_info "Profile: $aws_profile"
    log_info "Region: $aws_region"
    
    if [ "$dry_run" = "true" ]; then
        log_info "[DRY-RUN] Would stop ECS services and tasks in cluster: $cluster_name"
        return 0
    fi
    
    # Step 1: Scale down all services to 0
    log_info "  Step 1.1: Scaling down ECS services to 0..."
    local services_json
    services_json=$(aws ecs list-services --cluster "$cluster_name" --profile "$aws_profile" --region "$aws_region" --output json 2>/dev/null || echo '{"serviceArns":[]}')
    local service_arns
    service_arns=$(echo "$services_json" | "${PYTHON_CMD:-python3}" -c "import sys, json; data=json.load(sys.stdin); print(' '.join(data.get('serviceArns', [])))" 2>/dev/null || echo "")
    
    for service_arn in $service_arns; do
        if [ -z "$service_arn" ]; then
            continue
        fi
        local service_name
        service_name=$(echo "$service_arn" | sed 's|.*/||')
        log_info "    Scaling down service: $service_name"
        aws ecs update-service \
            --cluster "$cluster_name" \
            --service "$service_name" \
            --desired-count 0 \
            --profile "$aws_profile" \
            --region "$aws_region" >/dev/null 2>&1 || {
            log_warning "      Failed to scale down service: $service_name (may already be stopped)"
        }
    done
    
    # Step 2: Stop all running tasks (including one-off tasks not part of services)
    log_info "  Step 1.2: Stopping all running tasks..."
    local max_attempts=30
    local attempt=0
    local running_tasks=""
    
    while [ $attempt -lt $max_attempts ]; do
        # List all running tasks in the cluster
        running_tasks=$(aws ecs list-tasks \
            --cluster "$cluster_name" \
            --desired-status RUNNING \
            --profile "$aws_profile" \
            --region "$aws_region" \
            --query 'taskArns[]' \
            --output text 2>/dev/null || echo "")
        
        if [ -z "$running_tasks" ] || [ "$running_tasks" = "None" ]; then
            log_info "    No running tasks found"
            break
        fi
        
        # Stop each running task
        for task_arn in $running_tasks; do
            if [ -z "$task_arn" ] || [ "$task_arn" = "None" ]; then
                continue
            fi
            log_info "    Stopping task: $(echo "$task_arn" | sed 's|.*/||')"
            aws ecs stop-task \
                --cluster "$cluster_name" \
                --task "$task_arn" \
                --reason "Teardown: Stopping task before cluster destruction" \
                --profile "$aws_profile" \
                --region "$aws_region" >/dev/null 2>&1 || {
                log_warning "      Failed to stop task (may already be stopping)"
            }
        done
        
        # Wait a bit and check again
        attempt=$((attempt + 1))
        if [ $attempt -lt $max_attempts ]; then
            log_info "    Waiting for tasks to stop... (attempt $attempt/$max_attempts)"
            sleep 5
        fi
    done
    
    # Step 3: Wait for all tasks to fully stop (including services scaling down)
    log_info "  Step 1.3: Waiting for all tasks to fully stop..."
    local wait_attempts=60  # Wait up to 5 minutes (60 * 5 seconds)
    local wait_attempt=0
    
    while [ $wait_attempt -lt $wait_attempts ]; do
        # Check for any running or stopping tasks
        local active_tasks
        active_tasks=$(aws ecs list-tasks \
            --cluster "$cluster_name" \
            --desired-status RUNNING \
            --profile "$aws_profile" \
            --region "$aws_region" \
            --query 'length(taskArns[])' \
            --output text 2>/dev/null || echo "0")
        
        local stopping_tasks
        stopping_tasks=$(aws ecs list-tasks \
            --cluster "$cluster_name" \
            --desired-status STOPPING \
            --profile "$aws_profile" \
            --region "$aws_region" \
            --query 'length(taskArns[])' \
            --output text 2>/dev/null || echo "0")
        
        local total_active=$((active_tasks + stopping_tasks))
        
        if [ "${total_active:-0}" -eq 0 ]; then
            log_success "    All tasks have stopped"
            break
        fi
        
        wait_attempt=$((wait_attempt + 1))
        if [ $((wait_attempt % 6)) -eq 0 ]; then
            log_info "    Still waiting... ($total_active tasks: $active_tasks running, $stopping_tasks stopping)"
        fi
        sleep 5
    done
    
    if [ $wait_attempt -ge $wait_attempts ]; then
        log_warning "    Timeout waiting for all tasks to stop (some tasks may still be stopping)"
        log_warning "    Terraform destroy may still proceed, but may timeout if tasks are blocking"
    fi
    
    log_success "ECS services stopped"
    return 0
}

