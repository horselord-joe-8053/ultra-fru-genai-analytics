#!/usr/bin/env bash
# Main test suite runner function

# Run a test suite with the given test codes
# Parameters:
#   $1: Run prefix (e.g., "query_1" or "query_10")
#   $2+: Arguments (--test-env <aws|local> followed by test codes)
#       Example: run_test_suite "query_1" --test-env aws TOP
#       Example: run_test_suite "query_10" --test-env local AVG BRD CNT
run_test_suite() {
    local run_prefix="$1"
    shift
    
    # Parse --test-env argument from remaining arguments
    local test_env=""
    local test_codes=()
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --test-env)
                test_env="${2:-}"
                if [[ -z "$test_env" ]]; then
                    echo "ERROR: --test-env requires a value (aws or local)" >&2
                    return 1
                fi
                if [[ "$test_env" != "aws" ]] && [[ "$test_env" != "local" ]]; then
                    echo "ERROR: --test-env must be 'aws' or 'local', got: $test_env" >&2
                    return 1
                fi
                shift 2
                ;;
            *)
                # Everything else is a test code
                test_codes+=("$1")
                shift
                ;;
        esac
    done
    
    if [[ -z "$test_env" ]]; then
        echo "ERROR: --test-env is required (must be 'aws' or 'local')" >&2
        return 1
    fi
    
    if [[ ${#test_codes[@]} -eq 0 ]]; then
        echo "ERROR: No test codes provided" >&2
        return 1
    fi
    
    # Export TEST_ENV for use in other functions
    export TEST_ENV="$test_env"
    
    local total_tests=${#test_codes[@]}
    
    # Source configuration
    # shellcheck source=/dev/null
    source "$(dirname "${BASH_SOURCE[0]}")/test_config.sh"
    
    # Setup environment
    # shellcheck source=/dev/null
    source "$(dirname "${BASH_SOURCE[0]}")/test_setup.sh"
    setup_test_environment "$run_prefix" "$test_env"
    
    # Setup test environment (AWS or local)
    # shellcheck source=/dev/null
    source "$(dirname "${BASH_SOURCE[0]}")/test_environment.sh"
    setup_test_environment_by_type
    
    # Source runner and results functions
    # shellcheck source=/dev/null
    source "$(dirname "${BASH_SOURCE[0]}")/test_runner.sh"
    # shellcheck source=/dev/null
    source "$(dirname "${BASH_SOURCE[0]}")/test_results.sh"
    
    # Initialize files
    initialize_summary_file "$run_prefix" "$test_env" "$API_BASE_URL" "$PER_TEST_TIMEOUT_SECONDS" "$total_tests"
    initialize_log_file "$run_prefix" "$test_env" "$API_BASE_URL" "$PER_TEST_TIMEOUT_SECONDS"
    
    # Print header
    echo ""
    echo "═══════════════════════════════════════════════════════════════════════════════"
    if [ $total_tests -eq 1 ]; then
        echo "Running Single Query Test"
    else
        echo "Running ${total_tests}-Query Test Suite"
    fi
    echo "═══════════════════════════════════════════════════════════════════════════════"
    echo "  Test Environment: $test_env"
    echo "  API Base URL:     $API_BASE_URL"
    echo "  Per-Test Timeout: ${PER_TEST_TIMEOUT_SECONDS}s"
    echo "  Results Directory: $RUN_DIR"
    echo "═══════════════════════════════════════════════════════════════════════════════"
    echo ""
    
    # Initialize counters
    local passed=0
    local failed=0
    local timed_out=0
    
    # File to collect failure details for summary (only created when failures occur)
    local failure_details_file=""
    if [ $total_tests -gt 1 ]; then
        failure_details_file="$RUN_DIR/test_failures.log"
        # File will be created on first failure, not in advance
    fi
    
    # Run tests
    for test_num in $(seq 1 $total_tests); do
        local test_code="${test_codes[$((test_num - 1))]}"
        local test_start=$(date +%s)
        
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Starting Test $test_num/$total_tests ($test_code)..." | tee -a "$LOG_FILE"
        
        # Run test with timeout
        run_single_test_with_timeout "$test_code" "$API_BASE_URL" "$LOG_FILE" "$PER_TEST_TIMEOUT_SECONDS" "$TIMEOUT_CMD"
        local test_exit_code=$?
        
        echo "" >> "$LOG_FILE"
        
        # Calculate duration
        local test_duration=$(($(date +%s) - test_start))
        
        # Process result
        local status
        status=$(process_test_result "$test_num" "$test_code" "$test_exit_code" "$test_duration" "$failure_details_file")
        
        # Update counters and log
        case "$status" in
            PASS)
                passed=$((passed + 1))
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] Test $test_num/$total_tests: PASSED (${test_duration}s)" | tee -a "$LOG_FILE"
                ;;
            TIMEOUT)
                timed_out=$((timed_out + 1))
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] Test $test_num/$total_tests: TIMEOUT after ${PER_TEST_TIMEOUT_SECONDS}s" | tee -a "$LOG_FILE"
                ;;
            FAIL)
                failed=$((failed + 1))
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] Test $test_num/$total_tests: FAILED (${test_duration}s)" | tee -a "$LOG_FILE"
                ;;
        esac
    done
    
    # Finalize summary
    finalize_summary_file "$total_tests" "$passed" "$failed" "$timed_out" "$failure_details_file"
    
    # Print final summary
    print_final_summary "$total_tests" "$passed" "$failed" "$timed_out"
    
    # Exit with non-zero if any tests failed or timed out
    if [ $failed -gt 0 ] || [ $timed_out -gt 0 ]; then
        return 1
    else
        return 0
    fi
}

