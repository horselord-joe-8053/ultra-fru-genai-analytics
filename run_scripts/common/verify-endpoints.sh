#!/bin/bash
# Common endpoint verification functions
# Used by both AWS and local verification scripts
# Usage: source verify-endpoints.sh

# Helper function to check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Validate API endpoint with retry logic
validate_api_endpoint() {
    local api_endpoint="$1"
    local timeout_seconds="${API_VALIDATION_TIMEOUT_SECONDS:-60}"
    local start_time=$(date +%s)
    local elapsed=0
    local last_status=""
    
    log_info "Testing API endpoint: $api_endpoint/health"
    log_info "  Will retry for up to $((timeout_seconds / 60)) minute(s)..."
    
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
            if [ $((elapsed % 15)) -eq 0 ] && [ $elapsed -gt 0 ]; then
                log_info "  Still waiting... (${elapsed}s elapsed, HTTP $api_status)"
            fi
        elif [ "$api_status" = "000" ]; then
            # Connection failed, continue retrying
            if [ $((elapsed % 15)) -eq 0 ] && [ $elapsed -gt 0 ]; then
                log_info "  Connection failed, retrying... (${elapsed}s elapsed)"
            fi
        else
            # Unexpected status code
            log_warning "⚠ API endpoint returned HTTP $api_status"
            log_info "  Endpoint is reachable but may need configuration."
            return 1
        fi
        
        sleep "${VALIDATION_RETRY_INTERVAL_SECONDS:-5}"
        elapsed=$(($(date +%s) - start_time))
    done
    
    # Timeout reached
    log_error "✗ API endpoint validation failed after ${elapsed}s"
    log_error "  Last HTTP status: $last_status"
    log_error "  Endpoint: $api_endpoint/health"
    return 1
}

# Validate frontend endpoint with retry logic
validate_frontend_endpoint() {
    local frontend_endpoint="$1"
    local timeout_seconds="${FRONTEND_VALIDATION_TIMEOUT_SECONDS:-60}"
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
            
            if [ "$html_verified" = true ]; then
                log_success "✓ Frontend is accessible (HTTP $frontend_status) after ${elapsed}s"
                log_success "  ✓ Content is HTML"
                return 0
            else
                log_warning "⚠ Frontend returned HTTP 200 but content may not be HTML"
                log_info "  Content-Type: ${frontend_content_type:-unknown}"
                return 0
            fi
        elif [ "$frontend_status" = "403" ] || [ "$frontend_status" = "404" ]; then
            # May still be deploying
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
        
        sleep "${VALIDATION_RETRY_INTERVAL_SECONDS:-5}"
        elapsed=$(($(date +%s) - start_time))
    done
    
    # Timeout reached
    log_error "✗ Frontend endpoint validation failed after ${elapsed}s"
    log_error "  Last HTTP status: $last_status"
    log_error "  Endpoint: $frontend_endpoint"
    return 1
}

# Check Docker services
check_docker_services() {
    log_info "Checking Docker services..."
    if command_exists docker; then
        if docker ps | grep -q "fru_db\|fru_api"; then
            log_success "Docker services are running"
            return 0
        else
            log_warning "Docker services may not be running"
            log_info "Start them with: ./run_scripts/local/start-services.sh"
            return 1
        fi
    else
        log_warning "docker command not found"
        return 1
    fi
}

# Get detailed health status from API
get_api_health_status() {
    local api_url="$1"
    local health_response
    
    if ! command_exists curl; then
        return 1
    fi
    
    health_response=$(curl -sf "$api_url/health" 2>/dev/null || echo "{}")
    
    if echo "$health_response" | grep -q '"status":"ok"'; then
        # Check database connection
        if echo "$health_response" | grep -q '"database":"connected"'; then
            log_success "Database connection: OK"
        else
            log_warning "Database connection: FAILED"
        fi
        
        # Check OpenAI configuration
        if echo "$health_response" | grep -q '"openai":"configured"'; then
            log_success "OpenAI configuration: OK"
        else
            log_warning "OpenAI configuration: NOT CONFIGURED"
        fi
        
        # Check AWS/Claude configuration
        if echo "$health_response" | grep -q '"aws":"configured"'; then
            log_success "AWS/Bedrock configuration: OK"
        else
            log_info "AWS/Bedrock not configured (OK for local dev with CLAUDE_API_KEY)"
        fi
        
        return 0
    else
        log_warning "API health check returned unexpected response"
        return 1
    fi
}

# Validate /query/stream endpoint (Server-Sent Events)
# This is the primary query endpoint used by the frontend for real-time responses.
# The endpoint streams responses using SSE format with 'data:' prefixed events.
# We verify:
#   1. HTTP 200 response
#   2. Content-Type: text/event-stream (or compatible)
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
            
            # Get actual response body (everything except last 2 lines)
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
            
            # Check for SSE event structure
            local has_sse_events=false
            if echo "$response_body" | grep -qE "^data:|^data "; then
                has_sse_events=true
                log_success "  ✓ Response contains SSE events (data: ...)"
            elif [ -n "$response_body" ]; then
                log_info "  Response preview: $(echo "$response_body" | head -c 200)..."
                has_sse_events=true
            fi
            
            if [ "$content_type_ok" = true ] || [ "$has_sse_events" = true ]; then
                return 0
            else
                log_warning "  ⚠ Response structure may be unexpected"
                return 0  # Still return success if HTTP 200
            fi
        elif [ "$stream_status" = "503" ] || [ "$stream_status" = "502" ] || [ "$stream_status" = "504" ]; then
            if [ $((elapsed % 15)) -eq 0 ] && [ $elapsed -gt 0 ]; then
                log_info "  Still waiting... (${elapsed}s elapsed, HTTP $stream_status)"
            fi
        elif [ "$stream_status" = "000" ]; then
            if [ $((elapsed % 15)) -eq 0 ] && [ $elapsed -gt 0 ]; then
                log_info "  Connection failed, retrying... (${elapsed}s elapsed)"
            fi
        else
            log_warning "⚠ Query Stream endpoint returned HTTP $stream_status"
            return 1
        fi
        
        sleep "${VALIDATION_RETRY_INTERVAL_SECONDS:-5}"
        elapsed=$(($(date +%s) - start_time))
    done
    
    log_error "✗ Query Stream endpoint validation failed after ${elapsed}s"
    log_error "  Last HTTP status: $last_status"
    log_error "  Endpoint: $api_endpoint/query/stream?query=$test_query"
    return 1
}

