#!/bin/bash
# Teardown Delta tables - deletes all Delta tables for clean rebuild
# Usage: ./teardown-delta.sh [--force] [--skip-confirmation] [--dry-run] [--environment <env>]
#
# This script:
# 1. Detects environment (AWS or local)
# 2. Finds all Delta tables in the environment
# 3. Deletes all Delta tables completely
#
# WARNING: This will DELETE ALL Delta tables for the specified environment!

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../../../../.." && pwd)}"
source "$REPO_ROOT/orchestration/shared/logger.sh"
source "$REPO_ROOT/orchestration/shared/load-env.sh"
source "$REPO_ROOT/orchestration/shared/load-image-identifiers.sh"

DRY_RUN="false"
FORCE_DELETE="false"
SKIP_CONFIRMATION="false"
AWS_PROFILE="${AWS_PROFILE:-admin}"
AWS_REGION="${AWS_REGION:-us-east-1}"
ENVIRONMENT="${ENVIRONMENT:-dev}"
DEPLOYMENT_TYPE="${DEPLOYMENT_TYPE:-aws}"  # "aws" or "local"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --force)
            FORCE_DELETE="true"
            SKIP_CONFIRMATION="true"
            shift
            ;;
        --skip-confirmation)
            SKIP_CONFIRMATION="true"
            shift
            ;;
        --dry-run)
            DRY_RUN="true"
            shift
            ;;
        --environment|-e)
            ENVIRONMENT="$2"
            shift 2
            ;;
        --local)
            DEPLOYMENT_TYPE="local"
            shift
            ;;
        --help|-h)
            cat << EOF
Usage: $0 [--force] [--skip-confirmation] [--dry-run] [--environment <env>] [--local]

Teardown Delta tables - deletes all Delta tables for clean rebuild.

WARNING: This will DELETE ALL Delta tables for the specified environment!

Options:
  --dry-run             Show what would be deleted without actually deleting (default: false)
  --force               Skip confirmation prompts and actually delete (default: requires confirmation)
  --skip-confirmation   Alias for --force
  --environment <env>   Environment name (dev, staging, prod) - defaults to 'dev' or ENVIRONMENT env var
  --local               Use local filesystem instead of AWS S3
  --help                Show this help message

Examples:
  $0 --dry-run                          # Preview what would be deleted (AWS)
  $0 --local --dry-run                  # Preview what would be deleted (local)
  $0                                    # Delete with confirmation prompt
  $0 --force                            # Delete without confirmation
  $0 --environment prod --force         # Delete prod Delta tables without confirmation

Note: By default, this script requires confirmation before deleting.
      Use --force to skip confirmation prompts.

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

# Validate environment
if [[ ! "$ENVIRONMENT" =~ ^(dev|staging|prod)$ ]]; then
    log_error "Invalid environment: $ENVIRONMENT"
    log_info "Must be: dev, staging, or prod"
    exit 1
fi

log_step "Delta Table Teardown"
log_warning "════════════════════════════════════════════════════════════════"
log_warning "WARNING: This will DELETE ALL Delta tables for $ENVIRONMENT"
log_warning "════════════════════════════════════════════════════════════════"
log_info "Environment: $ENVIRONMENT"
log_info "Deployment Type: $DEPLOYMENT_TYPE"
if [ "$DEPLOYMENT_TYPE" = "aws" ]; then
    log_info "Region: $AWS_REGION"
    log_info "Profile: $AWS_PROFILE"
fi
if [ "$DRY_RUN" = "true" ]; then
    log_info "Mode: DRY-RUN (no Delta tables will be deleted)"
else
    log_warning "Mode: DELETION (Delta tables will be permanently deleted!)"
fi
echo ""

# Confirmation (unless --force or --dry-run)
if [ "$DRY_RUN" = "false" ] && [ "$SKIP_CONFIRMATION" = "false" ]; then
    log_warning "This action cannot be undone!"
    log_warning "All Delta tables for environment '$ENVIRONMENT' will be deleted."
    echo ""
    read -p "Type 'yes' to confirm deletion: " confirm
    if [ "$confirm" != "yes" ]; then
        log_info "Deletion cancelled by user"
        exit 0
    fi
    echo ""
fi

# ============================================================================
# Find Delta Tables (AWS)
# ============================================================================
find_delta_tables_aws() {
    # Get S3 bucket from Terraform outputs
    local infra_dir="$REPO_ROOT/module_infra_basic/aws/environments/$ENVIRONMENT/infrastructure"
    local s3_bucket_id=""
    
    if [ -d "$infra_dir" ]; then
        cd "$infra_dir"
        s3_bucket_id=$(AWS_PROFILE="$AWS_PROFILE" terragrunt output -raw s3_data_bucket_id 2>/dev/null || echo "")
        cd - >/dev/null
    fi
    
    # Fallback: Try to detect bucket from AWS account
    if [ -z "$s3_bucket_id" ]; then
        # Use centralized AWS Account ID resolution
        if [ -z "${AWS_ACCOUNT_ID:-}" ]; then
            load_image_identifiers "aws" || true
        fi
        if [ -n "${AWS_ACCOUNT_ID:-}" ]; then
            local bucket_name="fru-${ENVIRONMENT}-analytics-data-${AWS_ACCOUNT_ID}"
            if aws s3 ls "s3://${bucket_name}" --profile "$AWS_PROFILE" >/dev/null 2>&1; then
                s3_bucket_id="$bucket_name"
            fi
        fi
    fi
    
    if [ -z "$s3_bucket_id" ]; then
        log_warning "Could not find S3 bucket for Delta tables"
        log_info "Skipping Delta table teardown (bucket may not exist)"
        echo ""
        return 1
    fi
    
    log_info "S3 Bucket: $s3_bucket_id"
    
    # Find all Delta tables (directories with _delta_log)
    local delta_prefix="s3://${s3_bucket_id}/delta/"
    log_info "Scanning for Delta tables in: $delta_prefix"
    
    # List all directories under delta/ prefix
    local delta_tables
    delta_tables=$(aws s3 ls "$delta_prefix" --profile "$AWS_PROFILE" --region "$AWS_REGION" 2>/dev/null | grep "PRE" | awk '{print $2}' | sed 's|/$||' || echo "")
    
    if [ -z "$delta_tables" ]; then
        log_info "No Delta tables found in $delta_prefix"
        echo ""
        return 1
    fi
    
    # Output table paths (one per line) with prefix
    for table in $delta_tables; do
        echo "${delta_prefix}${table}"
    done
    return 0
}

# ============================================================================
# Find Delta Tables (Local)
# ============================================================================
find_delta_tables_local() {
    # Load env file but redirect log output to stderr to avoid capturing it
    load_env_file >&2 || true
    local delta_base_path="${DELTA_TABLE_PATH:-data/delta}"
    
    # Resolve absolute path
    if [[ "$delta_base_path" = /* ]]; then
        local delta_dir="$delta_base_path"
    else
        local delta_dir="$REPO_ROOT/$delta_base_path"
    fi
    
    if [ ! -d "$delta_dir" ]; then
        log_info "Delta directory does not exist: $delta_dir" >&2
        log_info "No Delta tables to delete" >&2
        echo "" >&2
        return 1
    fi
    
    log_info "Delta directory: $delta_dir" >&2
    
    # Find all Delta tables (directories with _delta_log)
    local delta_tables
    delta_tables=$(find "$delta_dir" -type d -name "_delta_log" -exec dirname {} \; 2>/dev/null | sort -u || echo "")
    
    if [ -z "$delta_tables" ]; then
        log_info "No Delta tables found in $delta_dir" >&2
        echo "" >&2
        return 1
    fi
    
    # Output table paths (one per line) - only actual paths, no log messages
    echo "$delta_tables"
    return 0
}

# ============================================================================
# Delete a Single Delta Table
# ============================================================================
delete_delta_table() {
    local table_path="$1"
    local deployment_type="$2"
    local table_name
    
    # Extract table name for logging (last component of path)
    if [ "$deployment_type" = "aws" ]; then
        table_name=$(echo "$table_path" | sed 's|.*/||')
    else
        # Use basename but handle edge cases (paths with special chars, empty strings)
        if [ -z "$table_path" ] || [[ "$table_path" =~ ^[[:space:]]*$ ]]; then
            table_name="(empty)"
        else
            # Use -- to prevent basename from interpreting leading dashes as options
            table_name=$(basename -- "$table_path" 2>/dev/null || echo "$table_path")
        fi
    fi
    
    if [ "$DRY_RUN" = "true" ]; then
        log_info "  [DRY-RUN] Would delete: $table_path"
    else
        log_info "  Deleting Delta table: $table_name"
        local delete_success=false
        
        if [ "$deployment_type" = "aws" ]; then
            if aws s3 rm "$table_path" --recursive --profile "$AWS_PROFILE" --region "$AWS_REGION" 2>&1; then
                delete_success=true
            fi
        else
            if rm -rf "$table_path" 2>/dev/null; then
                delete_success=true
            fi
        fi
        
        if [ "$delete_success" = "true" ]; then
            log_success "    ✓ Deleted: $table_name"
        else
            log_warning "    ⚠ Failed to delete: $table_name (may not exist or already deleted)"
        fi
    fi
}

# ============================================================================
# Teardown Delta Tables (Unified)
# ============================================================================
teardown_delta_tables() {
    local deployment_type="$1"
    local location_label
    local delta_tables
    
    if [ "$deployment_type" = "aws" ]; then
        location_label="AWS S3"
        log_step "Finding Delta Tables in $location_label"
        delta_tables=$(find_delta_tables_aws)
    else
        location_label="Local Filesystem"
        log_step "Finding Delta Tables in $location_label"
        delta_tables=$(find_delta_tables_local)
    fi
    
    local find_exit_code=$?
    if [ $find_exit_code -ne 0 ] || [ -z "$delta_tables" ]; then
        return 0  # No tables found, not an error
    fi
    
    # Count tables
    local count=0
    for table in $delta_tables; do
        count=$((count + 1))
    done
    
    if [ "$count" -eq 0 ]; then
        log_info "No Delta tables to delete"
        return 0
    fi
    
    # List found tables
    log_info "Found $count Delta table(s):"
    for table in $delta_tables; do
        if [ "$deployment_type" = "aws" ]; then
            log_info "  - $(echo "$table" | sed 's|.*/||') (path: $table)"
        else
            log_info "  - $table"
        fi
    done
    echo ""
    
    # Delete each Delta table
    log_step "Deleting Delta Tables"
    for table in $delta_tables; do
        delete_delta_table "$table" "$deployment_type"
    done
    echo ""
}

# ============================================================================
# Main Execution
# ============================================================================
main() {
    local failed=false
    
    if ! teardown_delta_tables "$DEPLOYMENT_TYPE"; then
        failed=true
    fi
    
    echo ""
    log_step "Teardown Summary"
    log_info "════════════════════════════════════════════════════════════════"
    
    if [ "$DRY_RUN" = "true" ]; then
        log_warning "DRY-RUN MODE - No Delta tables were actually deleted"
        log_info ""
        log_info "Review the output above to see what would be deleted"
        log_info ""
        log_info "To actually delete Delta tables, run:"
        log_info "  $0 --force"
    else
        if [ "$failed" = "true" ]; then
            log_warning "Teardown completed with some issues"
            log_info "Review the output above for details"
        else
            log_success "Delta table teardown completed!"
            log_info ""
            log_info "All Delta tables for environment '$ENVIRONMENT' have been deleted"
            log_info "You can now run setup-and-verify.sh to recreate Delta tables"
        fi
    fi
    log_info "════════════════════════════════════════════════════════════════"
    
    if [ "$failed" = "true" ]; then
        exit 1
    fi
}

main "$@"

