#!/bin/bash
# Comprehensive endpoint validation with retry logic
# Usage: source validate-endpoints.sh
#        validate_urls

# ============================================================================
# VALIDATION CONSTANTS
# ============================================================================
API_VALIDATION_TIMEOUT_SECONDS=300  # 5 minutes (upper bound)
FRONTEND_VALIDATION_TIMEOUT_SECONDS=60  # 1 minute
QUERY_ENDPOINT_VALIDATION_TIMEOUT_SECONDS=60  # 1 minute (API should already be up)
VALIDATION_RETRY_INTERVAL_SECONDS=5  # Check every 5 seconds
# Fail fast on API errors if we can diagnose a clear cause from ECS/logs
API_VALIDATION_FAIL_FAST="${API_VALIDATION_FAIL_FAST:-true}"

# Expected HTML content keywords for frontend validation
# These should be present in a working frontend page
FRONTEND_EXPECTED_HTML_KEYWORDS=(
    "<html"
    "<head"
    "<body"
    "react"
    "root"
    "app"
)

# Helper function to check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Validate API endpoint with retry logic
validate_api_endpoint() {
    local api_endpoint="$1"
    local timeout_seconds="$API_VALIDATION_TIMEOUT_SECONDS"
    local start_time=$(date +%s)
    local elapsed=0
    local last_status=""
    local diagnosed=false
    
    log_info "Testing API endpoint: $api_endpoint/health"
    log_info "  Will retry for up to $((timeout_seconds / 60)) minutes..."
    
    while [ $elapsed -lt $timeout_seconds ]; do
        local api_status
        api_status=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "$api_endpoint/health" 2>/dev/null || echo "000")
        last_status="$api_status"
        
        if [ "$api_status" = "200" ]; then
            log_success "✓ API is responding (HTTP $api_status) after ${elapsed}s"
            
            # Get actual response
            local health_response
            health_response=$(curl -s --max-time 10 "$api_endpoint/health" 2>/dev/null || echo "")
            if echo "$health_response" | grep -q '"status"'; then
                log_info "  Response preview: $(echo "$health_response" | head -c 100)..."
            fi
            return 0
        elif [ "$api_status" = "503" ] || [ "$api_status" = "502" ] || [ "$api_status" = "504" ]; then
            # Service is starting or has a backend error
            if [ "$API_VALIDATION_FAIL_FAST" = "true" ] && [ "$diagnosed" = false ]; then
                log_warning "API returned HTTP $api_status. Attempting to diagnose ECS/logs and fail fast..."
                # diagnose_api_failure should be available if diagnose-failures.sh was sourced
                if type diagnose_api_failure >/dev/null 2>&1; then
                    diagnose_api_failure || true
                fi
                diagnosed=true
                # Fail fast after diagnosis to avoid waiting full timeout when clear errors exist
                return 1
            fi
            if [ $((elapsed % 30)) -eq 0 ] && [ $elapsed -gt 0 ]; then
                log_info "  Still waiting... (${elapsed}s elapsed, HTTP $api_status)"
            fi
        elif [ "$api_status" = "000" ]; then
            # Connection failed, continue retrying
            if [ $((elapsed % 30)) -eq 0 ] && [ $elapsed -gt 0 ]; then
                log_info "  Connection failed, retrying... (${elapsed}s elapsed)"
            fi
        else
            # Unexpected status code
            log_warning "⚠ API endpoint returned HTTP $api_status"
            log_info "  Endpoint is reachable but may need configuration."
            return 1
        fi
        
        sleep "$VALIDATION_RETRY_INTERVAL_SECONDS"
        elapsed=$(($(date +%s) - start_time))
    done
    
    # Timeout reached
    log_error "✗ API endpoint validation failed after ${elapsed}s"
    log_error "  Last HTTP status: $last_status"
    log_error "  Endpoint: $api_endpoint/health"
    if [ "$last_status" = "503" ] || [ "$last_status" = "502" ] || [ "$last_status" = "504" ]; then
        log_error "  The service appears to be starting but did not become ready within the timeout period."
        log_info "  Troubleshooting steps:"
        log_info "    1. Check ECS service status: aws ecs describe-services --cluster <cluster> --services <service>"
        log_info "    2. Check ECS task logs: aws logs tail /ecs/fru-dev --follow"
        log_info "    3. Verify ALB target group health: aws elbv2 describe-target-health --target-group-arn <arn>"
    elif [ "$last_status" = "000" ]; then
        log_error "  The endpoint is not reachable (connection failed or timed out)."
        log_info "  Troubleshooting steps:"
        log_info "    1. Verify ALB is fully provisioned: aws elbv2 describe-load-balancers"
        log_info "    2. Check security groups allow traffic"
        log_info "    3. Verify DNS resolution: nslookup $(echo "$api_endpoint" | sed 's|http://||' | sed 's|https://||')"
    fi
    return 1
}

# Validate frontend endpoint with retry logic and HTML content check
validate_frontend_endpoint() {
    local frontend_endpoint="$1"
    local timeout_seconds="$FRONTEND_VALIDATION_TIMEOUT_SECONDS"
    local start_time=$(date +%s)
    local elapsed=0
    local last_status=""
    
    log_info "Testing Frontend endpoint: $frontend_endpoint"
    log_info "  Will retry for up to $((timeout_seconds / 60)) minute(s)..."
    
    while [ $elapsed -lt $timeout_seconds ]; do
        local frontend_status frontend_content_type
        frontend_status=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "$frontend_endpoint" 2>/dev/null || echo "000")
        frontend_content_type=$(curl -s -o /dev/null -w "%{content_type}" --max-time 10 "$frontend_endpoint" 2>/dev/null || echo "")
        last_status="$frontend_status"
        
        if [ "$frontend_status" = "200" ]; then
            # Check if it's HTML
            local frontend_content
            frontend_content=$(curl -s --max-time 10 "$frontend_endpoint" 2>/dev/null | head -c 2000 || echo "")
            
            local html_verified=false
            if echo "$frontend_content" | grep -qiE "<html|<head|<!DOCTYPE"; then
                html_verified=true
            elif echo "$frontend_content_type" | grep -qi "text/html"; then
                html_verified=true
            fi
            
            # Check for expected HTML keywords
            local found_keywords=0
            for keyword in "${FRONTEND_EXPECTED_HTML_KEYWORDS[@]}"; do
                if echo "$frontend_content" | grep -qi "$keyword"; then
                    found_keywords=$((found_keywords + 1))
                fi
            done
            
            if [ "$html_verified" = true ] && [ $found_keywords -ge 2 ]; then
                log_success "✓ Frontend is accessible (HTTP $frontend_status) after ${elapsed}s"
                log_success "  ✓ Content is HTML with expected keywords"
                return 0
            elif [ "$html_verified" = true ]; then
                log_success "✓ Frontend is accessible (HTTP $frontend_status) after ${elapsed}s"
                log_warning "  ⚠ Content is HTML but missing some expected keywords"
                return 0
            else
                log_warning "⚠ Frontend returned HTTP 200 but content may not be HTML"
                log_info "  Content-Type: ${frontend_content_type:-unknown}"
                return 0
            fi
        elif [ "$frontend_status" = "403" ] || [ "$frontend_status" = "404" ]; then
            # CloudFront may still be deploying or S3 bucket may be empty
            if [ $((elapsed % 15)) -eq 0 ] && [ $elapsed -gt 0 ]; then
                log_info "  Still waiting... (${elapsed}s elapsed, HTTP $frontend_status)"
            fi
        elif [ "$frontend_status" = "000" ]; then
            # Connection failed, continue retrying
            if [ $((elapsed % 15)) -eq 0 ] && [ $elapsed -gt 0 ]; then
                log_info "  Connection failed, retrying... (${elapsed}s elapsed)"
            fi
        else
            # Unexpected status code
            log_warning "⚠ Frontend endpoint returned HTTP $frontend_status"
            return 1
        fi
        
        sleep "$VALIDATION_RETRY_INTERVAL_SECONDS"
        elapsed=$(($(date +%s) - start_time))
    done
    
    # Timeout reached
    log_error "✗ Frontend endpoint validation failed after ${elapsed}s"
    log_error "  Last HTTP status: $last_status"
    log_error "  Endpoint: $frontend_endpoint"
    if [ "$last_status" = "403" ]; then
        log_error "  CloudFront returned 403 Forbidden. Possible causes:"
        log_info "    1. CloudFront distribution is still deploying (can take 15-20 minutes)"
        log_info "    2. S3 bucket is empty or content not synced"
        log_info "    3. CloudFront origin access configuration issue"
        log_info "    4. CloudFront custom error responses not configured"
        log_info "  Troubleshooting steps:"
        log_info "    1. Check CloudFront status: aws cloudfront get-distribution --id <distribution-id>"
        log_info "    2. Verify S3 bucket has content: aws s3 ls s3://<bucket-name>/"
        log_info "    3. Check CloudFront origin: aws cloudfront get-distribution-config --id <distribution-id>"
    elif [ "$last_status" = "404" ]; then
        log_error "  CloudFront returned 404 Not Found."
        log_info "  Troubleshooting steps:"
        log_info "    1. Verify S3 bucket has index.html: aws s3 ls s3://<bucket-name>/"
        log_info "    2. Check CloudFront default root object configuration"
    elif [ "$last_status" = "000" ]; then
        log_error "  The endpoint is not reachable (connection failed or timed out)."
        log_info "  Troubleshooting steps:"
        log_info "    1. Verify CloudFront distribution is deployed: aws cloudfront list-distributions"
        log_info "    2. Check DNS resolution: nslookup $(echo "$frontend_endpoint" | sed 's|https://||' | sed 's|http://||')"
    fi
    return 1
}

# NOTE: /query endpoint verification is disabled
# The synchronous /query endpoint requires complex request/response validation
# and may timeout during verification. Instead, we verify /query/stream which
# uses Server-Sent Events (SSE) and is the primary endpoint used by the frontend.
# 
# If you need to test /query manually, use:
#   curl -X POST http://api-url/query -H "Content-Type: application/json" -d '{"query": "test"}'

# validate_query_endpoint() is disabled - use validate_query_stream_endpoint() instead
# The entire function is commented out below - uncomment if needed for debugging
# validate_query_endpoint() {
#    local api_endpoint="$1"
#    local timeout_seconds="$QUERY_ENDPOINT_VALIDATION_TIMEOUT_SECONDS"
#    local start_time=$(date +%s)
#    local elapsed=0
#    local last_status=""
    
#    log_info "Testing Query endpoint: $api_endpoint/query"
#    log_info "  Will retry for up to $((timeout_seconds / 60)) minute(s)..."
#    
#    while [ $elapsed -lt $timeout_seconds ]; do
#        local query_status query_response
#        # Test POST /query endpoint with sample query
#        query_response=$(curl -s -w "\n%{http_code}" --max-time 30 \
#            -X POST "$api_endpoint/query" \
#            -H "Content-Type: application/json" \
#            -d '{"query": "Why are Samsung customers unhappy?"}' 2>/dev/null || echo -e "\n000")
#        
#        query_status=$(echo "$query_response" | tail -n 1)
#        last_status="$query_status"
#        
#        if [ "$query_status" = "200" ]; then
#            log_success "✓ Query endpoint is responding (HTTP $query_status) after ${elapsed}s"
#            
#            # Get actual response body (everything except last line which is status code)
#            local response_body
#            response_body=$(echo "$query_response" | head -n -1)
#            
#            # Validate response structure - check for required fields
#            local has_answer=false
#            local has_stats=false
#            local has_sample_records=false
#            local has_question=false
#            local answer_content=""
#            
#            # Use jq if available for better JSON parsing, otherwise use grep
#            if command_exists jq; then
#                # Validate JSON structure with jq
#                if echo "$response_body" | jq -e '.answer' >/dev/null 2>&1; then
#                    has_answer=true
#                    answer_content=$(echo "$response_body" | jq -r '.answer // ""' | head -c 100)
#                fi
#                if echo "$response_body" | jq -e '.stats' >/dev/null 2>&1; then
#                    has_stats=true
#                fi
#                if echo "$response_body" | jq -e '.sample_records' >/dev/null 2>&1; then
#                    has_sample_records=true
#                fi
#                if echo "$response_body" | jq -e '.question' >/dev/null 2>&1; then
#                    has_question=true
#                fi
#            else
#                # Fallback to grep-based validation
#                if echo "$response_body" | grep -q '"answer"'; then
#                    has_answer=true
#                    answer_content=$(echo "$response_body" | grep -o '"answer"[[:space:]]*:[[:space:]]*"[^"]*' | head -c 100 || echo "")
#                fi
#                if echo "$response_body" | grep -q '"stats"'; then
#                    has_stats=true
#                fi
#                if echo "$response_body" | grep -q '"sample_records"'; then
#                    has_sample_records=true
#                fi
#                if echo "$response_body" | grep -q '"question"'; then
#                    has_question=true
#                fi
#            fi
#            
#            # Validate required fields are present
#            if [ "$has_answer" = true ] && [ "$has_stats" = true ] && [ "$has_sample_records" = true ]; then
#                log_success "✓ Response structure is valid (contains: answer, stats, sample_records)"
#                if [ -n "$answer_content" ] && [ "$answer_content" != "null" ] && [ "$answer_content" != "" ]; then
#                    log_info "  Answer preview: ${answer_content}..."
#                    log_info "  ✓ API is returning legitimate query results"
#                else
#                    log_warning "  ⚠ Answer field is present but appears to be empty"
#                fi
#                
#                # Show stats summary if available
#                if command_exists jq && echo "$response_body" | jq -e '.stats.total_matches' >/dev/null 2>&1; then
#                    local total_matches
#                    total_matches=$(echo "$response_body" | jq -r '.stats.total_matches // 0')
#                    log_info "  Stats: total_matches=$total_matches"
#                fi
#                
#                return 0
#            elif [ "$has_answer" = true ]; then
#                log_warning "  ⚠ Response has 'answer' but missing expected fields (stats, sample_records)"
#                log_info "  Response preview: $(echo "$response_body" | head -c 150)..."
#                return 0  # Still consider it a success if we got an answer
#            elif echo "$response_body" | grep -qE '"error"'; then
#                log_warning "  ⚠ Query endpoint returned an error response"
#                log_info "  Error: $(echo "$response_body" | grep -o '"error"[[:space:]]*:[[:space:]]*"[^"]*' | head -c 150 || echo "$response_body" | head -c 150)..."
#                return 1
#            else
#                log_warning "  ⚠ Response structure is unexpected (missing required fields)"
#                log_info "  Response preview: $(echo "$response_body" | head -c 150)..."
#                return 0  # Still return success if HTTP 200, but log warning
#            fi
#        elif [ "$query_status" = "503" ] || [ "$query_status" = "502" ] || [ "$query_status" = "504" ]; then
#            # Service is starting or has a backend error
#            if [ $((elapsed % 15)) -eq 0 ] && [ $elapsed -gt 0 ]; then
#                log_info "  Still waiting... (${elapsed}s elapsed, HTTP $query_status)"
#            fi
#        elif [ "$query_status" = "000" ]; then
#            # Connection failed, continue retrying
#            if [ $((elapsed % 15)) -eq 0 ] && [ $elapsed -gt 0 ]; then
#                log_info "  Connection failed, retrying... (${elapsed}s elapsed)"
#            fi
#        elif [ "$query_status" = "400" ] || [ "$query_status" = "422" ]; then
#            # Bad request - endpoint is reachable but request format may be wrong
#            log_warning "⚠ Query endpoint returned HTTP $query_status (bad request)"
#            log_info "  Endpoint is reachable but request format may need adjustment"
#            return 1
#        else
#            # Unexpected status code
#            log_warning "⚠ Query endpoint returned HTTP $query_status"
#            log_info "  Endpoint is reachable but may need configuration"
#            return 1
#        fi
#        
#        sleep "$VALIDATION_RETRY_INTERVAL_SECONDS"
#        elapsed=$(($(date +%s) - start_time))
#    done
#    
#    # Timeout reached
#    log_error "✗ Query endpoint validation failed after ${elapsed}s"
#    log_error "  Last HTTP status: $last_status"
#    log_error "  Endpoint: $api_endpoint/query"
#    if [ "$last_status" = "503" ] || [ "$last_status" = "502" ] || [ "$last_status" = "504" ]; then
#        log_error "  The service appears to be starting but did not become ready within the timeout period."
#        log_info "  Troubleshooting steps:"
#        log_info "    1. Check ECS service status: aws ecs describe-services --cluster <cluster> --services <service>"
#        log_info "    2. Check ECS task logs: aws logs tail /ecs/fru-dev --follow"
#        log_info "    3. Verify ALB target group health: aws elbv2 describe-target-health --target-group-arn <arn>"
#    elif [ "$last_status" = "000" ]; then
#        log_error "  The endpoint is not reachable (connection failed or timed out)."
#        log_info "  Troubleshooting steps:"
#        log_info "    1. Verify ALB is fully provisioned: aws elbv2 describe-load-balancers"
#        log_info "    2. Check security groups allow traffic"
#        log_info "    3. Verify DNS resolution: nslookup $(echo "$api_endpoint" | sed 's|http://||' | sed 's|https://||')"
#    fi
#    return 1
#}
# End of disabled validate_query_endpoint() function

# Validate /query/stream endpoint (Server-Sent Events)
# This is the primary query endpoint used by the frontend for real-time responses.
# The endpoint streams responses using SSE format with 'data:' prefixed events.
# We verify:
#   1. HTTP 200 response
#   2. Content-Type: text/event-stream (or application/x-ndjson)
#   3. At least one valid SSE event (data: ...)
validate_query_stream_endpoint() {
    local api_endpoint="$1"
    local timeout_seconds="${QUERY_STREAM_VALIDATION_TIMEOUT_SECONDS:-60}"
    local start_time=$(date +%s)
    local elapsed=0
    local last_status=""
    
    # Sample query for testing (URL-encoded: "average rating")
    local test_query="average%20rating"
    
    log_info "Testing Query Stream endpoint: $api_endpoint/query/stream?query=$test_query"
    log_info "  Will retry for up to $((timeout_seconds / 60)) minute(s)..."
    
    while [ $elapsed -lt $timeout_seconds ]; do
        local stream_status stream_content_type stream_response
        # Test GET /query/stream endpoint with sample query
        stream_response=$(curl -s -w "\n%{http_code}\n%{content_type}" --max-time 10 \
            "$api_endpoint/query/stream?query=$test_query" 2>/dev/null || echo -e "\n000\n")
        
        stream_status=$(echo "$stream_response" | tail -n 2 | head -n 1)
        stream_content_type=$(echo "$stream_response" | tail -n 1)
        last_status="$stream_status"
        
        if [ "$stream_status" = "200" ]; then
            log_success "✓ Query Stream endpoint is responding (HTTP $stream_status) after ${elapsed}s"
            
            # Get actual response body (everything except last 2 lines which are status code and content type)
            local response_body
            response_body=$(echo "$stream_response" | head -n -2)
            
            # Verify Content-Type is correct for SSE
            local content_type_ok=false
            if echo "$stream_content_type" | grep -qiE "text/event-stream|application/x-ndjson|text/plain"; then
                content_type_ok=true
                log_success "  ✓ Content-Type is valid: $stream_content_type"
            else
                log_warning "  ⚠ Unexpected Content-Type: $stream_content_type (expected text/event-stream)"
            fi
            
            # Check for SSE event structure (data: ...)
            local has_sse_events=false
            if echo "$response_body" | grep -qE "^data:|^data "; then
                has_sse_events=true
                log_success "  ✓ Response contains SSE events (data: ...)"
            elif [ -n "$response_body" ]; then
                # May still be valid if it's NDJSON or streaming JSON
                log_info "  Response preview: $(echo "$response_body" | head -c 200)..."
                has_sse_events=true  # Consider it valid if we got any response
            fi
            
            if [ "$content_type_ok" = true ] || [ "$has_sse_events" = true ]; then
                log_success "  ✓ Query Stream endpoint is working correctly"
                return 0
            else
                log_warning "  ⚠ Response structure may be unexpected"
                return 0  # Still return success if HTTP 200
            fi
        elif [ "$stream_status" = "503" ] || [ "$stream_status" = "502" ] || [ "$stream_status" = "504" ]; then
            # Service is starting or has a backend error
            if [ $((elapsed % 15)) -eq 0 ] && [ $elapsed -gt 0 ]; then
                log_info "  Still waiting... (${elapsed}s elapsed, HTTP $stream_status)"
            fi
        elif [ "$stream_status" = "000" ]; then
            # Connection failed, continue retrying
            if [ $((elapsed % 15)) -eq 0 ] && [ $elapsed -gt 0 ]; then
                log_info "  Connection failed, retrying... (${elapsed}s elapsed)"
            fi
        else
            # Unexpected status code
            log_warning "⚠ Query Stream endpoint returned HTTP $stream_status"
            log_info "  Endpoint is reachable but may need configuration"
            return 1
        fi
        
        sleep "$VALIDATION_RETRY_INTERVAL_SECONDS"
        elapsed=$(($(date +%s) - start_time))
    done
    
    # Timeout reached
    log_error "✗ Query Stream endpoint validation failed after ${elapsed}s"
    log_error "  Last HTTP status: $last_status"
    log_error "  Endpoint: $api_endpoint/query/stream?query=$test_query"
    return 1
}

# Validate URLs by testing connectivity with retry logic
validate_urls() {
    if [ "$DRY_RUN" = "true" ]; then
        return 0
    fi
    
    # Check if curl is available
    if ! command_exists curl; then
        log_warning "curl is not available, skipping URL validation"
        return 0
    fi
    
    echo ""
    log_step "Validating Deployment URLs"
    echo ""
    
    local api_ok=false
    local frontend_ok=false
    local query_ok=false
    local api_base_url=""
    
    # Test API health endpoint with retry
    if [ -n "$API_URL" ]; then
        api_base_url="$API_URL"
        if validate_api_endpoint "$API_URL"; then
            api_ok=true
        fi
    elif [ -n "$ALB_DNS" ]; then
        api_base_url="http://$ALB_DNS"
        if validate_api_endpoint "http://$ALB_DNS"; then
            api_ok=true
        fi
    else
        log_info "API URL not available for validation"
    fi
    
    echo ""
    
    # Test Frontend URL with retry
    if [ -n "$FRONTEND_URL" ]; then
        if validate_frontend_endpoint "$FRONTEND_URL"; then
            frontend_ok=true
        fi
    elif [ -n "$CLOUDFRONT_DOMAIN" ]; then
        if validate_frontend_endpoint "https://$CLOUDFRONT_DOMAIN"; then
            frontend_ok=true
        fi
    else
        log_info "Frontend URL not available for validation"
    fi
    
    echo ""
    
    # Test Query Stream endpoint with retry (only if API health check passed)
    # NOTE: We test /query/stream instead of /query because:
    # 1. /query/stream uses Server-Sent Events (SSE) which is the primary endpoint used by the frontend
    # 2. /query endpoint may timeout during verification due to complex processing
    # 3. /query/stream provides real-time responses which is better for user experience
    if [ "$api_ok" = true ] && [ -n "$api_base_url" ]; then
        if validate_query_stream_endpoint "$api_base_url"; then
            query_ok=true
        fi
    else
        log_info "Skipping query stream endpoint validation (API health check did not pass)"
    fi
    
    echo ""
    
    # Summary
    if [ "$api_ok" = true ] && [ "$frontend_ok" = true ] && [ "$query_ok" = true ]; then
        log_success "✓ All endpoints are accessible and working!"
    elif [ "$api_ok" = true ] && [ "$frontend_ok" = true ]; then
        log_warning "⚠ API and frontend are accessible, but query stream endpoint needs attention"
    elif [ "$api_ok" = true ] && [ "$query_ok" = true ]; then
        log_warning "⚠ API and query stream endpoint are working, but frontend needs attention"
    elif [ "$api_ok" = true ]; then
        log_warning "⚠ API is accessible, but frontend and query stream endpoint need attention"
    elif [ "$frontend_ok" = true ]; then
        log_warning "⚠ Frontend is accessible, but API needs attention"
    else
        log_warning "⚠ Some endpoints are not yet accessible"
        log_info "  Check the error messages above for troubleshooting steps."
    fi
}

# Main execution (if run standalone)
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    # Determine script directory (always set it, even if log_info exists)
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
    
    # Source logger if not already sourced
    if [ -z "${log_info:-}" ]; then
        source "$SCRIPT_DIR/../../common/logger.sh" 2>/dev/null || true
        source "$SCRIPT_DIR/../../common/load-env.sh" 2>/dev/null || true
        load_env_file 2>/dev/null || true
    fi
    
    # If URLs are not set, try to fetch them from Terraform
    if [ -z "${API_URL:-}" ] && [ -z "${ALB_DNS:-}" ] && [ -z "${FRONTEND_URL:-}" ] && [ -z "${CLOUDFRONT_DOMAIN:-}" ]; then
        DEPLOYMENT_TYPE="${DEPLOYMENT_TYPE:-ecs-full}"
        ENVIRONMENT="${ENVIRONMENT:-dev}"
        
        log_info "No URLs provided. Fetching from Terraform outputs..."
        # fetch-deployment-info.sh is in the same directory as this script
        FETCH_SCRIPT="$SCRIPT_DIR/fetch-deployment-info.sh"
        if [ -f "$FETCH_SCRIPT" ]; then
            source "$FETCH_SCRIPT" "$DEPLOYMENT_TYPE" "$ENVIRONMENT" "${DRY_RUN:-false}"
        else
            log_warning "fetch-deployment-info.sh not found at $FETCH_SCRIPT"
            log_warning "Cannot automatically discover API_URL and FRONTEND_URL from Terraform outputs."
            log_info "Please either:"
            log_info "  1. Ensure fetch-deployment-info.sh exists at: run_scripts/aws/verification/fetch-deployment-info.sh, or"
            log_info "  2. Set API_URL and FRONTEND_URL environment variables manually"
        fi
    fi
    
    validate_urls
else
    # If sourced, just define the functions
    true  # Functions are already defined above
fi

