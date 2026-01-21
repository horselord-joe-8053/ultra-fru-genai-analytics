#!/bin/bash
# CloudFront Invalidation Helper Functions
# Provides functions for creating CloudFront invalidations and waiting for completion
# Usage: source this file and call the functions

# Create CloudFront invalidation
# Usage: create_cloudfront_invalidation <distribution_id> <paths>
# Returns: invalidation_id (prints to stdout)
# Exits with error on failure
create_cloudfront_invalidation() {
    local dist_id="$1"
    local paths="${2:-/*}"  # Default to all paths
    
    if [ -z "$dist_id" ]; then
        log_error "CloudFront distribution ID is required"
        return 1
    fi
    
    log_info "Creating CloudFront invalidation..."
    log_info "  Distribution ID: $dist_id"
    log_info "  Paths: $paths"
    
    # Create invalidation
    local invalidation_result
    invalidation_result=$(aws cloudfront create-invalidation \
        --distribution-id "$dist_id" \
        --paths "$paths" \
        --profile "$AWS_PROFILE" \
        --output json 2>&1)
    
    if [ $? -eq 0 ]; then
        # Extract invalidation ID from JSON
        local invalidation_id
        invalidation_id=$(echo "$invalidation_result" | jq -r '.Invalidation.Id')
        
        if [ -n "$invalidation_id" ] && [ "$invalidation_id" != "null" ]; then
            log_success "CloudFront invalidation created: $invalidation_id"
            echo "$invalidation_id"
            return 0
        else
            log_error "Failed to extract invalidation ID from response"
            log_error "Response: $invalidation_result"
            return 1
        fi
    else
        log_error "Failed to create CloudFront invalidation"
        log_error "Error: $invalidation_result"
        return 1
    fi
}

# Wait for invalidation to complete
# Usage: wait_for_invalidation <distribution_id> <invalidation_id> <timeout_minutes>
# Returns: 0 on success, exits with error on timeout/failure
# Fail-fast: Exits with error if timeout is reached
wait_for_invalidation() {
    local dist_id="$1"
    local invalidation_id="$2"
    local timeout_minutes="${3:-15}"  # Default 15 minutes
    local timeout_seconds=$((timeout_minutes * 60))
    local check_interval=30  # Check every 30 seconds
    
    if [ -z "$dist_id" ] || [ -z "$invalidation_id" ]; then
        log_error "Distribution ID and invalidation ID are required"
        exit 1
    fi
    
    log_info "Waiting for CloudFront invalidation to complete..."
    log_info "  Distribution ID: $dist_id"
    log_info "  Invalidation ID: $invalidation_id"
    log_info "  Timeout: ${timeout_minutes} minutes (checking every ${check_interval}s)"
    
    local start_time=$(date +%s)
    local elapsed=0
    
    while [ $elapsed -lt $timeout_seconds ]; do
        # Get invalidation status
        local status_result
        status_result=$(aws cloudfront get-invalidation \
            --distribution-id "$dist_id" \
            --id "$invalidation_id" \
            --profile "$AWS_PROFILE" \
            --output json 2>&1)
        
        if [ $? -eq 0 ]; then
            local status
            status=$(echo "$status_result" | jq -r '.Invalidation.Status')
            
            if [ "$status" = "Completed" ]; then
                local elapsed_minutes=$((elapsed / 60))
                local elapsed_seconds=$((elapsed % 60))
                log_success "CloudFront invalidation completed successfully"
                log_info "  Time taken: ${elapsed_minutes}m ${elapsed_seconds}s"
                return 0
            elif [ "$status" = "InProgress" ]; then
                local elapsed_minutes=$((elapsed / 60))
                local elapsed_seconds=$((elapsed % 60))
                log_info "Invalidation in progress... (${elapsed_minutes}m ${elapsed_seconds}s elapsed)"
            else
                log_error "Invalidation status: $status (unexpected)"
                log_error "Full status response: $status_result"
                log_error "CloudFront invalidation failed with unexpected status"
                exit 1
            fi
        else
            log_error "Failed to check invalidation status: $status_result"
            log_error "Cannot verify CloudFront invalidation completion"
            exit 1
        fi
        
        sleep $check_interval
        elapsed=$(($(date +%s) - start_time))
    done
    
    # Timeout reached - fail-fast with clear error message
    log_error "════════════════════════════════════════════════════════════════"
    log_error "CloudFront invalidation timeout after ${timeout_minutes} minutes"
    log_error "════════════════════════════════════════════════════════════════"
    log_error "Distribution ID: $dist_id"
    log_error "Invalidation ID: $invalidation_id"
    log_error ""
    log_error "The invalidation is still in progress. This may indicate:"
    log_error "  1. CloudFront is experiencing high load or delays"
    log_error "  2. The distribution has a large number of edge locations"
    log_error "  3. Network issues preventing status checks"
    log_error ""
    log_error "You can check the status manually with:"
    log_error "  aws cloudfront get-invalidation --distribution-id $dist_id --id $invalidation_id --profile $AWS_PROFILE"
    log_error ""
    log_error "The invalidation will continue in the background and should complete"
    log_error "within a few minutes. The new frontend version will be available"
    log_error "once the invalidation completes."
    log_error ""
    exit 1  # Fail-fast: exit deployment
}

# Verify frontend version (optional, non-blocking)
# Usage: verify_frontend_version <cloudfront_domain> <expected_pattern>
# Returns: 0 on success, 1 on failure (non-blocking)
verify_frontend_version() {
    local domain="$1"
    local expected_pattern="${2:-}"  # Optional: regex pattern to match
    
    if [ -z "$domain" ]; then
        log_warning "CloudFront domain is required for verification"
        return 1
    fi
    
    log_info "Verifying frontend version on CloudFront..."
    log_info "  Domain: https://$domain/"
    
    # Fetch frontend HTML
    local html_content
    html_content=$(curl -s -f "https://$domain/" --max-time 10 2>&1)
    
    if [ $? -ne 0 ]; then
        log_warning "Could not fetch frontend from CloudFront: $html_content"
        log_info "Frontend may still be propagating - this is normal"
        return 1
    fi
    
    # Basic verification: check if HTML is returned (not an error page)
    if echo "$html_content" | grep -q "<!doctype html\|<html"; then
        log_success "Frontend is accessible on CloudFront: https://$domain/"
        return 0
    else
        log_warning "Frontend response does not appear to be valid HTML"
        log_info "Frontend may still be propagating - this is normal"
        return 1
    fi
}

