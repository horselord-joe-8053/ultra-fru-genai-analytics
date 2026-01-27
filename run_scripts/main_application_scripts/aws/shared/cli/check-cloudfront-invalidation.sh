#!/bin/bash
# CloudFront Invalidation Status Checker (Standalone CLI Tool)
# =============================================================
# This is a **standalone CLI tool** for manually checking the status of a
# single CloudFront invalidation from your terminal. It is useful for
# debugging invalidation issues or verifying invalidation completion.
#
# **Container Type**: Container-agnostic (CloudFront works with both ECS and EKS)
# **Location**: run_scripts/main_application_scripts/aws/shared/cli/
# **Type**: Standalone CLI (run directly, not sourced)
#
# It is intentionally separate from the library-style helper functions in:
#   run_scripts/main_application_scripts/aws/shared/helpers/cloudfront-invalidation.sh
# which are meant to be sourced and used by automation (deploy scripts).
#
# Usage (standalone):
#   ./check-cloudfront-invalidation.sh <distribution_id> <invalidation_id> [--profile <profile>]
#
# Example:
#   ./run_scripts/main_application_scripts/aws/shared/cli/check-cloudfront-invalidation.sh \\
#     E33TA1D0OAYUNR IA2F109WZGDDJ9JH61N5TZVZS3 --profile admin
#
# What it shows:
#   - Invalidation status (Completed, InProgress, etc.)
#   - Creation time
#   - Invalidated paths
#
# Prerequisites:
#   - AWS CLI configured with CloudFront permissions
#   - jq installed (for JSON parsing)
#
# Note: The deploy scripts should *not* call this CLI; they should instead
# source and use the library helpers (wait_for_invalidation) for retries,
# timeouts, etc. This tool is for humans debugging a specific invalidation.

# Resolve REPO_ROOT for standalone execution
SCRIPT_DIR_CLI_CF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT_CLI_CF="${REPO_ROOT:-$(cd "$SCRIPT_DIR_CLI_CF/../../../../.." && pwd)}"

# Source logger if available
if [ -f "$REPO_ROOT_CLI_CF/run_scripts/shared/logger.sh" ]; then
    source "$REPO_ROOT_CLI_CF/run_scripts/shared/logger.sh"
else
    # Fallback logging functions
    log_info() { echo "[INFO] $*"; }
    log_success() { echo "[SUCCESS] $*"; }
    log_warning() { echo "[WARNING] $*"; }
    log_error() { echo "[ERROR] $*"; }
fi

check_invalidation_status() {
    local distribution_id=$1
    local invalidation_id=$2
    local aws_profile="${3:-${AWS_PROFILE:-admin}}"
    
    if [ -z "$distribution_id" ] || [ -z "$invalidation_id" ]; then
        log_error "Distribution ID and invalidation ID are required"
        echo "Usage: $0 <distribution_id> <invalidation_id> [--profile <profile>]"
        return 1
    fi
    
    log_info "Checking CloudFront invalidation status..."
    log_info "  Distribution ID: $distribution_id"
    log_info "  Invalidation ID: $invalidation_id"
    log_info "  AWS Profile: $aws_profile"
    
    local status_result
    status_result=$(aws cloudfront get-invalidation \
        --distribution-id "$distribution_id" \
        --id "$invalidation_id" \
        --profile "$aws_profile" \
        --output json 2>&1)
    
    local aws_rc=$?
    if [ $aws_rc -eq 0 ]; then
        local status
        status=$(echo "$status_result" | jq -r '.Invalidation.Status' 2>/dev/null || echo "Unknown")
        local create_time
        create_time=$(echo "$status_result" | jq -r '.Invalidation.CreateTime' 2>/dev/null || echo "Unknown")
        local paths
        paths=$(echo "$status_result" | jq -r '.Invalidation.InvalidationBatch.Paths.Items[]' 2>/dev/null | tr '\n' ' ' || echo "Unknown")
        
        log_info "Status: $status"
        log_info "Created: $create_time"
        log_info "Paths: $paths"
        
        case "$status" in
            Completed)
                log_success "✓ Invalidation completed successfully"
                ;;
            InProgress)
                log_info "⏳ Invalidation is still in progress"
                ;;
            *)
                log_warning "⚠ Invalidation status: $status"
                ;;
        esac
        
        echo "$status"
        return 0
    else
        # Handle NoSuchInvalidation consistently with the helper function
        if echo "$status_result" | grep -q "NoSuchInvalidation"; then
            log_error "CloudFront returned NoSuchInvalidation for ID '$invalidation_id'"
            log_error "This usually means the invalidation never existed or has been removed/pruned"
            log_info "You can create a new invalidation with:"
            log_info "  aws cloudfront create-invalidation --distribution-id $distribution_id --paths '/*' --profile $aws_profile"
        else
            log_error "Failed to check invalidation status"
            log_error "Error: $status_result"
        fi
        return 1
    fi
}

# If script is run directly, parse arguments
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    local distribution_id=""
    local invalidation_id=""
    local aws_profile="${AWS_PROFILE:-admin}"
    
    while [ $# -gt 0 ]; do
        case "$1" in
            --profile)
                aws_profile="$2"
                shift 2
                ;;
            *)
                if [ -z "$distribution_id" ]; then
                    distribution_id="$1"
                elif [ -z "$invalidation_id" ]; then
                    invalidation_id="$1"
                fi
                shift
                ;;
        esac
    done
    
    check_invalidation_status "$distribution_id" "$invalidation_id" "$aws_profile"
fi
