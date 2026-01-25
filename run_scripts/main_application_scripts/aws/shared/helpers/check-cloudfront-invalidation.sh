#!/bin/bash
# CloudFront Invalidation Status Checker
# Phase 4: Helper script to check invalidation status
# Usage: check-cloudfront-invalidation.sh <distribution_id> <invalidation_id> [--profile <profile>]

# Source logger if available
if [ -f "$(dirname "${BASH_SOURCE[0]}")/../../../../shared/logger.sh" ]; then
    source "$(dirname "${BASH_SOURCE[0]}")/../../../../shared/logger.sh"
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
    
    if [ $? -eq 0 ]; then
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
        log_error "Failed to check invalidation status"
        log_error "Error: $status_result"
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
