#!/usr/bin/env bash
# Test execution functions with timeout handling

# Run a single test with timeout
# Parameters:
#   $1: Test code (e.g., "TOP", "AVG")
#   $2: API base URL
#   $3: Log file path
#   $4: Timeout in seconds
#   $5: Timeout command (empty if using Python timeout)
# Returns: Exit code (0 = success, 124 = timeout, other = failure)
run_single_test_with_timeout() {
    local test_code="$1"
    local api_base_url="$2"
    local log_file="$3"
    local timeout_seconds="$4"
    local timeout_cmd="$5"
    
    # Construct full command for logging
    local full_cmd="python3 -m test.python.common_test_queries"
    full_cmd="$full_cmd --test-api-base-url \"$api_base_url\""
    full_cmd="$full_cmd --query-list \"$test_code\""
    full_cmd="$full_cmd --log-file \"$log_file\""
    
    if [ -n "$timeout_cmd" ]; then
        # Use system timeout command (Linux or macOS with GNU coreutils)
        # Log full command before execution
        echo "Full Cmd: $timeout_cmd ${timeout_seconds}s $full_cmd" >> "$log_file"
        
        if $timeout_cmd "${timeout_seconds}s" \
            python3 -m test.python.common_test_queries \
                --test-api-base-url "$api_base_url" \
                --query-list "$test_code" \
                --log-file "$log_file" \
                >> "$log_file" 2>&1; then
            return 0
        else
            return $?
        fi
    else
        # No timeout command - Python will handle timeout internally via signal.alarm()
        # Add timeout to full command
        full_cmd="$full_cmd --timeout \"$timeout_seconds\""
        # Log full command before execution
        echo "Full Cmd: $full_cmd" >> "$log_file"
        
        if python3 -m test.python.common_test_queries \
            --test-api-base-url "$api_base_url" \
            --query-list "$test_code" \
            --log-file "$log_file" \
            --timeout "$timeout_seconds" \
            >> "$log_file" 2>&1; then
            return 0
        else
            return $?
        fi
    fi
}

