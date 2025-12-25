#!/usr/bin/env bash
# Result processing and summary generation functions

# Initialize summary file
# Parameters:
#   $1: Run prefix (e.g., "query_1" or "query_10")
#   $2: Test environment
#   $3: API base URL
#   $4: Timeout in seconds
#   $5: Number of tests (for table header)
initialize_summary_file() {
    local run_prefix="$1"
    local test_env="$2"
    local api_base_url="$3"
    local timeout_seconds="$4"
    local num_tests="$5"
    
    cat > "$SUMMARY_FILE" <<EOF
# Test Results Summary

**Test Run:** \`${run_prefix}_$TIMESTAMP\`  
**Date:** $(date)  
**Environment:** \`$test_env\`  
**API Base URL:** \`$api_base_url\`  
**Per-Test Timeout:** ${timeout_seconds}s

## Test Results

| Test # | Name | Status | Duration | Notes |
|--------|------|--------|----------|-------|
EOF
}

# Initialize log file
# Parameters:
#   $1: Run prefix
#   $2: Test environment
#   $3: API base URL
#   $4: Timeout in seconds
initialize_log_file() {
    local run_prefix="$1"
    local test_env="$2"
    local api_base_url="$3"
    local timeout_seconds="$4"
    
    {
        echo "Test Run: ${run_prefix}_$TIMESTAMP"
        echo "Date: $(date)"
        echo "Environment: $test_env"
        echo "API Base URL: $api_base_url"
        echo "Per-Test Timeout: ${timeout_seconds}s"
        echo ""
        echo "═══════════════════════════════════════════════════════════════════════════════"
        echo ""
    } > "$LOG_FILE"
}

# Extract test name from log file
# Parameters:
#   $1: Test code
#   $2: Log file path
# Returns: Test name (via stdout)
extract_test_name() {
    local test_code="$1"
    local log_file="$2"
    grep -m1 "^Test $test_code:" "$log_file" 2>/dev/null | sed "s/^Test $test_code: //" || echo "Test $test_code"
}

# Extract failure details from log
# Parameters:
#   $1: Test code
#   $2: Log file path
# Returns: Expected and Actual (via global variables EXPECTED and ACTUAL)
extract_failure_details() {
    local test_code="$1"
    local log_file="$2"
    
    # Find the section for this specific test (by code)
    local test_section
    test_section=$(awk "/^Test $test_code:/{flag=1} flag && /^Test [A-Z0-9]*:/ && !/^Test $test_code:/{flag=0} flag" "$log_file")
    
    if [ -n "$test_section" ]; then
        # Extract Expected and Actual from the failure section (get first occurrence only)
        EXPECTED=$(echo "$test_section" | grep -m1 "Expected (substring):" | sed 's/Expected (substring): //' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        ACTUAL=$(echo "$test_section" | grep -m1 "Actual (full answer):" | sed 's/Actual (full answer): //' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        
        # If not found in structured format, try to extract from assertion error
        if [ -z "$EXPECTED" ] || [ -z "$ACTUAL" ]; then
            # Look for EXPECTED_SUBSTRING_NOT_FOUND format
            EXPECTED=$(echo "$test_section" | grep -m1 "^EXPECTED: " | sed 's/^EXPECTED: //' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            ACTUAL=$(echo "$test_section" | grep -m1 "^ACTUAL_FULL: " | sed 's/^ACTUAL_FULL: //' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        fi
        
        # If still not found, try to get from the actual answer line
        if [ -z "$ACTUAL" ]; then
            ACTUAL=$(echo "$test_section" | grep -m1 "^Actual Answer:" | sed 's/Actual Answer: //' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        fi
    fi
}

# Process test result and update summary
# Parameters:
#   $1: Test number
#   $2: Test code
#   $3: Exit code
#   $4: Test duration in seconds
#   $5: Failure details file (optional, for multi-test runs)
# Returns: Status string (via stdout)
process_test_result() {
    local test_num="$1"
    local test_code="$2"
    local exit_code="$3"
    local test_duration="$4"
    local failure_details_file="${5:-}"
    
    local test_name
    test_name=$(extract_test_name "$test_code" "$LOG_FILE")
    
    if [ "$exit_code" -eq 0 ]; then
        echo "| $test_num | $test_name | ✅ PASS | ${test_duration}s | - |" >> "$SUMMARY_FILE"
        echo "PASS"
    elif [ "$exit_code" -eq 124 ]; then
        # Timeout
        echo "| $test_num | $test_name | ⏱️ TIMEOUT | >${PER_TEST_TIMEOUT_SECONDS}s | Exceeded timeout |" >> "$SUMMARY_FILE"
        echo "TIMEOUT"
    else
        # Failure
        extract_failure_details "$test_code" "$LOG_FILE"
        
        # Save to failure details file if provided (create file on first failure)
        if [ -n "$failure_details_file" ] && [ -n "$EXPECTED" ] && [ -n "$ACTUAL" ]; then
            {
                echo "### Test $test_num: $test_name"
                echo ""
                echo "**Expected (substring):**"
                echo "\`\`\`"
                echo "$EXPECTED"
                echo "\`\`\`"
                echo ""
                echo "**Actual (full answer):**"
                echo "\`\`\`"
                echo "$ACTUAL"
                echo "\`\`\`"
                echo ""
                echo "---"
                echo ""
            } >> "$failure_details_file"
            # File is created automatically on first write (>>)
        fi
        
        echo "| $test_num | $test_name | ❌ FAIL | ${test_duration}s | See details below |" >> "$SUMMARY_FILE"
        echo "FAIL"
    fi
}

# Finalize summary file
# Parameters:
#   $1: Total number of tests
#   $2: Number of passed tests
#   $3: Number of failed tests
#   $4: Number of timed out tests
#   $5: Failure details file (optional)
finalize_summary_file() {
    local total_tests="$1"
    local passed="$2"
    local failed="$3"
    local timed_out="$4"
    local failure_details_file="${5:-}"
    
    # Add failure details section if there are failures
    if [ "$failed" -gt 0 ] && [ -n "$failure_details_file" ] && [ -s "$failure_details_file" ]; then
        {
            echo ""
            echo "## Test Failure Details"
            echo ""
            cat "$failure_details_file"
        } >> "$SUMMARY_FILE"
    fi
    
    # Finalize summary
    {
        echo ""
        echo "## Summary"
        echo ""
        echo "- **Total Tests:** $total_tests"
        echo "- **✅ Passed:** $passed"
        echo "- **❌ Failed:** $failed"
        echo "- **⏱️ Timed Out:** $timed_out"
        echo ""
        echo "**Overall Status:** $([ $failed -eq 0 ] && [ $timed_out -eq 0 ] && echo '✅ ALL PASSED' || echo '⚠️ SOME FAILURES')"
        echo ""
        echo "---"
        echo ""
        echo "Full log: \`test_results.log\`"
    } >> "$SUMMARY_FILE"
}

# Print final summary to console
# Parameters:
#   $1: Total number of tests
#   $2: Number of passed tests
#   $3: Number of failed tests
#   $4: Number of timed out tests
print_final_summary() {
    local total_tests="$1"
    local passed="$2"
    local failed="$3"
    local timed_out="$4"
    
    echo ""
    echo "═══════════════════════════════════════════════════════════════════════════════"
    echo "Test Suite Complete"
    echo "═══════════════════════════════════════════════════════════════════════════════"
    echo "  Total Tests:  $total_tests"
    echo "  ✅ Passed:     $passed"
    echo "  ❌ Failed:     $failed"
    echo "  ⏱️  Timed Out: $timed_out"
    echo "═══════════════════════════════════════════════════════════════════════════════"
    echo ""
    echo "Results saved to: $RUN_DIR"
    echo "  - Summary: $SUMMARY_FILE"
    echo "  - Full log: $LOG_FILE"
    # Only show failures log if it exists (i.e., there were failures)
    if [ "$failed" -gt 0 ] && [ -f "$RUN_DIR/test_failures.log" ]; then
        echo "  - Failures: $RUN_DIR/test_failures.log"
    fi
    echo ""
}

