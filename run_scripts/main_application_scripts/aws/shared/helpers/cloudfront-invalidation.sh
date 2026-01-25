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
# Usage: wait_for_invalidation <distribution_id> <invalidation_id> <timeout_minutes> [non_blocking]
# Returns: 0 on success, 1 on failure (non-blocking mode) or exits with error (blocking mode)
# non_blocking: if "true", returns 1 on failure instead of exiting (allows deployment to continue)
wait_for_invalidation() {
    local dist_id="$1"
    local invalidation_id="$2"
    local timeout_minutes="${3:-15}"  # Default 15 minutes
    local non_blocking="${4:-false}"  # Default to blocking (exit on failure)
    local timeout_seconds=$((timeout_minutes * 60))
    local check_interval=30  # Check every 30 seconds
    local max_retries=3  # Retry failed status checks up to 3 times
    local base_retry_delay=1  # Base delay: 1 second (AWS recommended for throttling)
    local max_retry_delay=20  # Maximum delay: 20 seconds (AWS SDK standard)
    
    if [ -z "$dist_id" ] || [ -z "$invalidation_id" ]; then
        log_error "Distribution ID and invalidation ID are required"
        if [ "$non_blocking" = "true" ]; then
            return 1
        else
            exit 1
        fi
    fi
    
    log_info "Waiting for CloudFront invalidation to complete..."
    log_info "  Distribution ID: $dist_id"
    log_info "  Invalidation ID: $invalidation_id"
    log_info "  Timeout: ${timeout_minutes} minutes (checking every ${check_interval}s)"
    if [ "$non_blocking" = "true" ]; then
        log_info "  Mode: Non-blocking (deployment will continue if invalidation fails)"
    fi
    
    local start_time=$(date +%s)
    local elapsed=0
    local consecutive_failures=0
    
    while [ $elapsed -lt $timeout_seconds ]; do
        # Get invalidation status with retry logic
        local status_result=""
        local status_check_success=false
        local retry_count=0
        
        while [ $retry_count -lt $max_retries ] && [ "$status_check_success" = false ]; do
            status_result=$(aws cloudfront get-invalidation \
                --distribution-id "$dist_id" \
                --id "$invalidation_id" \
                --profile "$AWS_PROFILE" \
                --output json 2>&1)
            
            if [ $? -eq 0 ]; then
                status_check_success=true
                consecutive_failures=0
                break
            else
                retry_count=$((retry_count + 1))
                consecutive_failures=$((consecutive_failures + 1))
                
                if [ $retry_count -lt $max_retries ]; then
                    # Exponential backoff: 1s, 2s, 4s (AWS recommended pattern)
                    # Formula: base_delay * (2 ^ (retry_count - 1))
                    # Retry 1: 1s, Retry 2: 2s, Retry 3: 4s
                    local exponential_delay=$base_retry_delay
                    local i=1
                    while [ $i -lt $retry_count ]; do
                        exponential_delay=$((exponential_delay * 2))
                        i=$((i + 1))
                    done
                    # Cap at max_retry_delay (AWS SDK standard: 20 seconds)
                    if [ $exponential_delay -gt $max_retry_delay ]; then
                        exponential_delay=$max_retry_delay
                    fi
                    # Add jitter: random 0-1 second to prevent synchronized retries from multiple clients
                    # This prevents "thundering herd" problem when multiple deployments retry simultaneously
                    local jitter=$((RANDOM % 2))  # 0 or 1 second
                    local total_delay=$((exponential_delay + jitter))
                    
                    log_warning "Status check failed (attempt $retry_count/$max_retries), retrying in ${total_delay}s (exponential backoff: ${exponential_delay}s + ${jitter}s jitter)..."
                    log_warning "Error: ${status_result:0:200}"  # Show first 200 chars of error
                    sleep $total_delay
                else
                    log_error "Failed to check invalidation status after $max_retries attempts"
                    log_error "Last error: $status_result"
                    
                    if [ "$non_blocking" = "true" ]; then
                        log_warning "Cannot verify CloudFront invalidation completion (non-blocking mode)"
                        log_warning "Deployment will continue - invalidation may still complete in the background"
                        log_info "You can check the status manually with:"
                        log_info "  aws cloudfront get-invalidation --distribution-id $dist_id --id $invalidation_id --profile $AWS_PROFILE"
                        return 1
                    else
                        log_error "Cannot verify CloudFront invalidation completion"
                        exit 1
                    fi
                fi
            fi
        done
        
        # If status check succeeded, parse the status
        if [ "$status_check_success" = true ]; then
            local status
            status=$(echo "$status_result" | jq -r '.Invalidation.Status' 2>/dev/null)
            
            if [ -z "$status" ] || [ "$status" = "null" ]; then
                log_warning "Could not parse invalidation status from response"
                log_warning "Response: ${status_result:0:200}"
                # Continue to next check iteration
            elif [ "$status" = "Completed" ]; then
                local elapsed_minutes=$((elapsed / 60))
                local elapsed_seconds=$((elapsed % 60))
                log_success "CloudFront invalidation completed successfully"
                log_info "  Time taken: ${elapsed_minutes}m ${elapsed_seconds}s"
                
                # Phase 4: Log completion time for tracking
                local repo_root="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../../.." && pwd)}"
                local invalidation_log="$repo_root/.cloudfront-invalidations.log"
                if [ -f "$invalidation_log" ]; then
                    # Update the last entry with completion status
                    local completion_timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
                    # Append completion info to log (simple append for now)
                    echo "$completion_timestamp|$dist_id|$invalidation_id|COMPLETED|${elapsed_minutes}m${elapsed_seconds}s" >> "$invalidation_log"
                fi
                
                return 0
            elif [ "$status" = "InProgress" ]; then
                local elapsed_minutes=$((elapsed / 60))
                local elapsed_seconds=$((elapsed % 60))
                log_info "Invalidation in progress... (${elapsed_minutes}m ${elapsed_seconds}s elapsed)"
            else
                log_error "Invalidation status: $status (unexpected)"
                log_error "Full status response: ${status_result:0:500}"
                log_error "CloudFront invalidation failed with unexpected status"
                if [ "$non_blocking" = "true" ]; then
                    log_warning "Deployment will continue despite invalidation failure"
                    return 1
                else
                    exit 1
                fi
            fi
        fi
        
        # If we've had too many consecutive failures, give up
        if [ $consecutive_failures -ge $max_retries ]; then
            log_error "Too many consecutive failures checking invalidation status"
            if [ "$non_blocking" = "true" ]; then
                log_warning "Deployment will continue - invalidation may still complete in the background"
                return 1
            else
                exit 1
            fi
        fi
        
        sleep $check_interval
        elapsed=$(($(date +%s) - start_time))
    done
    
    # Timeout reached
    log_warning "════════════════════════════════════════════════════════════════"
    log_warning "CloudFront invalidation timeout after ${timeout_minutes} minutes"
    log_warning "════════════════════════════════════════════════════════════════"
    log_warning "Distribution ID: $dist_id"
    log_warning "Invalidation ID: $invalidation_id"
    log_warning ""
    log_warning "The invalidation is still in progress. This may indicate:"
    log_warning "  1. CloudFront is experiencing high load or delays"
    log_warning "  2. The distribution has a large number of edge locations"
    log_warning "  3. Network issues preventing status checks"
    log_warning ""
    log_info "You can check the status manually with:"
    log_info "  aws cloudfront get-invalidation --distribution-id $dist_id --id $invalidation_id --profile $AWS_PROFILE"
    log_info ""
    
    if [ "$non_blocking" = "true" ]; then
        log_warning "Deployment will continue - invalidation will complete in the background"
        log_warning "The new frontend version will be available once the invalidation completes"
        return 1
    else
        log_error "The invalidation will continue in the background and should complete"
        log_error "within a few minutes. The new frontend version will be available"
        log_error "once the invalidation completes."
        exit 1
    fi
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

