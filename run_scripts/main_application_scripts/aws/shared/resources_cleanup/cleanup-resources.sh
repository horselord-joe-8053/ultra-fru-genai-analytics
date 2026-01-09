#!/bin/bash
# Safe cleanup of unused/orphaned AWS resources
# Wrapper around cleanup-orphaned-resources.sh with user-friendly interface
# Usage: ./cleanup-resources.sh [--cont-sys ecs|eks] [--environment dev|prod] [--force] [--dry-run]
#
# This script provides a safer, more user-friendly interface to cleanup-orphaned-resources.sh:
# - By default: Shows dry-run preview, then asks for confirmation before actual cleanup
# - With --force: Skips confirmation and performs actual cleanup
# - With --dry-run: Only shows what would be cleaned up (no actual deletion)
#
# This is the recommended way to run cleanup for most users, as it provides
# a preview and confirmation step before destructive operations.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../../../../.." && pwd)}"
source "$REPO_ROOT/run_scripts/shared/logger.sh"
source "$REPO_ROOT/run_scripts/shared/load-env.sh"

DRY_RUN="false"
FORCE_DELETE="false"
AWS_PROFILE="${AWS_PROFILE:-admin}"
AWS_REGION="${AWS_REGION:-us-east-1}"
ENVIRONMENT="${ENVIRONMENT:-dev}"
CONTAINER_SYSTEM=""

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --cont-sys)
            CONTAINER_SYSTEM="$2"
            if [ "$CONTAINER_SYSTEM" != "ecs" ] && [ "$CONTAINER_SYSTEM" != "eks" ]; then
                log_error "Invalid container system: $CONTAINER_SYSTEM"
                log_info "Must be 'ecs' or 'eks'"
                exit 1
            fi
            shift 2
            ;;
        --environment)
            ENVIRONMENT="$2"
            shift 2
            ;;
        --force)
            FORCE_DELETE="true"
            shift
            ;;
        --dry-run)
            DRY_RUN="true"
            shift
            ;;
        --help|-h)
            cat << EOF
Usage: $0 [--cont-sys ecs|eks] [--environment dev|prod] [--force] [--dry-run]

Safe cleanup of unused/orphaned AWS resources for the FRU project.
This script is a wrapper around helpers/cleanup-orphaned-resources.sh with user-friendly prompts.

Options:
  --cont-sys <system>   Container system to clean up (ecs or eks)
  --environment <env>   Environment name (dev, prod) - defaults to 'dev'
  --dry-run             Show what would be cleaned up without actually cleaning (default: false)
  --force                Actually delete resources (default: false, shows dry-run)
  --help                 Show this help message

Examples:
  $0 --cont-sys ecs --environment dev              # Dry-run: Show what would be cleaned up
  $0 --cont-sys ecs --environment dev --dry-run    # Same as above (explicit)
  $0 --cont-sys ecs --environment dev --force      # Actually clean up resources

Note: By default, this script performs actual cleanup (dry-run: false).
      Use --dry-run to preview changes without executing.

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

log_step "Cleanup Unused Resources"
log_info "Environment: $ENVIRONMENT"
log_info "Profile: $AWS_PROFILE"
log_info "Region: $AWS_REGION"
if [ -n "$CONTAINER_SYSTEM" ]; then
    log_info "Container System: $CONTAINER_SYSTEM"
fi
if [ "$DRY_RUN" = "true" ]; then
    log_info "Mode: DRY-RUN (no resources will be deleted)"
else
    log_warning "Mode: ACTUAL CLEANUP (resources will be permanently deleted!)"
fi
echo ""

# Build command for cleanup-orphaned-resources.sh (in helpers subdirectory)
cleanup_cmd="$SCRIPT_DIR/helpers/cleanup-orphaned-resources.sh --environment $ENVIRONMENT"

if [ -n "$CONTAINER_SYSTEM" ]; then
    cleanup_cmd="$cleanup_cmd --cont-sys $CONTAINER_SYSTEM"
fi

if [ "$DRY_RUN" = "true" ]; then
    cleanup_cmd="$cleanup_cmd --dry-run"
elif [ "$FORCE_DELETE" = "true" ]; then
    cleanup_cmd="$cleanup_cmd --force"
else
    # Default: show dry-run first, then ask for confirmation before actual cleanup
    log_info "Previewing what would be cleaned up (dry-run)..."
    echo ""
    if ! $cleanup_cmd --dry-run; then
        log_error "Cleanup check failed"
        exit 1
    fi
    echo ""
    log_warning "════════════════════════════════════════════════════════════════"
    log_warning "CONFIRMATION REQUIRED"
    log_warning "════════════════════════════════════════════════════════════════"
    log_warning "The above resources will be PERMANENTLY DELETED."
    log_warning "This action cannot be undone!"
    echo ""
    read -p "Do you want to proceed with cleanup? (yes/no): " confirm
    if [ "$confirm" != "yes" ]; then
        log_info "Cleanup cancelled by user"
        exit 0
    fi
    echo ""
    log_info "Proceeding with actual cleanup..."
    cleanup_cmd="$cleanup_cmd --force"
fi

# Execute cleanup
log_info "Executing cleanup..."
echo ""
if $cleanup_cmd; then
    log_success "Cleanup completed successfully"
    exit 0
else
    log_error "Cleanup failed"
    exit 1
fi

