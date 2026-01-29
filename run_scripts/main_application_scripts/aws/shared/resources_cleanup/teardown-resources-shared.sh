#!/bin/bash
# Destroy shared infrastructure layer (VPC, Aurora, IAM, etc.) and clean up orphaned resources.
# 
# SYNOPSIS:
#   ./teardown-resources-shared.sh <ENVIRONMENT> [OPTIONS]
#
# DESCRIPTION:
#   This script is a thin wrapper around:
#     - terraform/teardown.sh <ENVIRONMENT> infrastructure
#     - helpers/cleanup-orphaned-resources.sh
#   It is intended to be called by higher-level orchestrators (e.g. teardown-resources-all.sh)
#   to perform shared-layer teardown in a consistent way.
#
# ARGUMENTS:
#   ENVIRONMENT          Environment name (dev, staging, prod) - defaults to 'dev'
#
# OPTIONS:
#   --force              Skip confirmation prompts in helpers (maps to --force for orphan cleanup)
#   --skip-confirmation  Alias for --force
#   --dry-run            Show what would be destroyed/cleaned without actually doing it
#
# NOTES:
#   - terraform/teardown.sh already respects PREEMPT=true for non-interactive Terragrunt
#   - This script focuses on orchestration and logging, not on direct AWS API calls
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../../../../.." && pwd)}"
source "$REPO_ROOT/run_scripts/shared/logger.sh"
source "$REPO_ROOT/run_scripts/shared/load-env.sh"

DRY_RUN="false"
FORCE_DELETE="false"
SKIP_CONFIRMATION="false"
AWS_PROFILE="${AWS_PROFILE:-admin}"
AWS_REGION="${AWS_REGION:-us-east-1}"
ENVIRONMENT="${1:-dev}"

# Parse arguments (skip first arg which is environment)
shift || true
while [[ $# -gt 0 ]]; do
    case "$1" in
        --force|--skip-confirmation)
            FORCE_DELETE="true"
            SKIP_CONFIRMATION="true"
            shift
            ;;
        --dry-run)
            DRY_RUN="true"
            shift
            ;;
        --help|-h)
            cat << EOF
Usage: $0 <ENVIRONMENT> [--force] [--dry-run]

Destroy shared Terraform infrastructure (infrastructure layer) and clean up
orphaned AWS resources (S3/ECR/ECS task definitions) using cleanup-orphaned-resources.sh.

Examples:
  $0 dev --dry-run
  $0 dev --force

Notes:
  - Intended to be called by higher-level scripts like teardown-resources-all.sh
  - terraform/teardown.sh will respect PREEMPT=true for non-interactive Terragrunt
EOF
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            log_info "Use --help for usage information"
            exit 1
            ;;
    esac
done

# Basic environment validation (mirror terraform/teardown.sh expectations)
if [[ ! "$ENVIRONMENT" =~ ^(dev|prod|staging)$ ]]; then
    log_error "Invalid environment: $ENVIRONMENT"
    log_info "Usage: $0 <ENVIRONMENT> [--force] [--dry-run]"
    exit 1
fi

log_step "Shared Infrastructure Teardown (wrapper)"
log_info "Environment: $ENVIRONMENT"
log_info "Region: $AWS_REGION"
log_info "Profile: $AWS_PROFILE"
if [ "$DRY_RUN" = "true" ]; then
    log_info "Mode: DRY-RUN (no resources will be destroyed)"
fi
echo ""

terraform_teardown_shared() {
    local terraform_teardown_script="$REPO_ROOT/run_scripts/main_application_scripts/aws/terraform/teardown.sh"

    if [ ! -f "$terraform_teardown_script" ]; then
        log_warning "Terraform teardown script not found at: $terraform_teardown_script"
        log_info "Skipping shared Terraform teardown (infrastructure may need manual cleanup)"
        return 1
    fi

    if [ "$DRY_RUN" = "true" ]; then
        log_info "[DRY-RUN] Would run: $terraform_teardown_script $ENVIRONMENT infrastructure"
        log_info "[DRY-RUN] This would destroy shared infrastructure (VPC, Aurora, IAM, Secrets Manager)"
        return 0
    fi

    log_step "Destroying Shared Terraform Infrastructure (infrastructure layer)"
    log_info "Calling Terraform teardown for shared infrastructure..."
    log_warning "This will destroy VPC, Aurora, IAM, and other shared resources for environment '$ENVIRONMENT'"

    # When --force is used, run non-interactively (no destroy confirmation prompt in terraform/teardown.sh).
    if [ "$FORCE_DELETE" = "true" ] || [ "$SKIP_CONFIRMATION" = "true" ]; then
        export PREEMPT=true
    fi
    # Ensure Terragrunt (and root.hcl get_aws_account_id()) see AWS profile/region in child process.
    export AWS_PROFILE="${AWS_PROFILE:-admin}"
    export AWS_REGION="${AWS_REGION:-us-east-1}"
    # PREEMPT=true is handled inside terraform/teardown.sh (via TG_NON_INTERACTIVE)
    if "$terraform_teardown_script" "$ENVIRONMENT" "infrastructure"; then
        log_success "Shared Terraform infrastructure destroyed (infrastructure layer)"
        return 0
    else
        log_warning "Shared Terraform teardown had issues (may have been partially destroyed)"
        log_info "Cause: Terraform destroy for shared layer (VPC, Aurora, IAM) failed or reported errors. See terraform/teardown.sh output above (e.g. lifecycle.prevent_destroy, dependency errors, or timeouts)."
        return 1
    fi
}

cleanup_orphaned_shared() {
    local helper_script="$SCRIPT_DIR/helpers/cleanup-orphaned-resources.sh"

    if [ ! -f "$helper_script" ]; then
        log_warning "Orphan cleanup helper script not found: $helper_script"
        log_info "Skipping orphan cleanup for shared layer"
        return 1
    fi

    local cleanup_cmd="$helper_script --environment $ENVIRONMENT"

    if [ "$DRY_RUN" = "true" ]; then
        cleanup_cmd="$cleanup_cmd --dry-run"
    else
        # In force/PREEMPT mode, run with --force for non-interactive cleanup
        if [ "$FORCE_DELETE" = "true" ] || [ "${PREEMPT:-false}" = "true" ]; then
            cleanup_cmd="$cleanup_cmd --force"
        fi
    fi

    if [ "$DRY_RUN" = "true" ]; then
        log_info "[DRY-RUN] Would run: $cleanup_cmd"
    else
        log_step "Cleaning Up Orphaned AWS Resources (shared layer pass)"
        log_info "Running orphan cleanup after shared Terraform destroy..."
        if $cleanup_cmd; then
            log_success "Orphaned resources cleaned up (shared layer pass)"
        else
            log_error "Shared-layer orphan cleanup had issues (may have been partially cleaned)"
            return 1
        fi
    fi
    echo ""
}

main() {
    local failed=false

    if ! terraform_teardown_shared; then
        failed=true
    fi

    if ! cleanup_orphaned_shared; then
        # Do not hard-fail entire script if orphan cleanup has minor issues
        log_error "Shared orphan cleanup reported issues; review logs above."
    fi

    if [ "$failed" = "true" ]; then
        log_error "teardown-resources-shared.sh exiting with failure: Terraform destroy (shared infrastructure) reported an error. Review the log lines above for Terraform/terragrunt output and fix or re-run as needed."
        exit 1
    fi
}

main "$@"

