#!/bin/bash
# Validate infrastructure outputs before deploying application
# Usage: ./validate-infra-outputs.sh <environment>

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../../.." && pwd)}"
source "$REPO_ROOT/run_scripts/shared/logger.sh"

ENVIRONMENT="${1:-dev}"

validate_infrastructure_outputs() {
    local env="${1:-$ENVIRONMENT}"
    local terraform_dir="$REPO_ROOT/infra/terraform/providers/aws/environments"
    local infra_dir="$terraform_dir/$env/infrastructure"
    local required_outputs=(
        "db_password_secret_arn"
        "db_password_plain_secret_arn"
        "db_username_secret_arn"
        "aurora_endpoint"
        "vpc_id"
        "ecs_task_execution_role_arn"
        "ecs_task_runtime_role_arn"
    )
    
    log_info "Validating infrastructure layer outputs..."
    
    local missing_outputs=()
    for output in "${required_outputs[@]}"; do
        if ! (cd "$infra_dir" && terragrunt output -raw "$output" >/dev/null 2>&1); then
            missing_outputs+=("$output")
        fi
    done
    
    if [ ${#missing_outputs[@]} -gt 0 ]; then
        log_error "Required infrastructure outputs are missing!"
        for output in "${missing_outputs[@]}"; do
            log_error "  - $output"
        done
        log_error ""
        log_error "Infrastructure layer deployment may have failed."
        log_error ""
        log_error "Troubleshooting:"
        log_error "  1. Check infrastructure deployment status:"
        log_error "     cd $infra_dir && terragrunt show"
        log_error "  2. Check for errors in infrastructure deployment logs above"
        log_error "  3. Redeploy infrastructure if needed:"
        log_error "     ./run_scripts/aws/run.sh infrastructure $env"
        return 1
    fi
    
    log_success "All required infrastructure outputs validated"
    return 0
}

# If executed directly
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    validate_infrastructure_outputs "$@"
    exit $?
fi

