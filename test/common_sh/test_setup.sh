#!/usr/bin/env bash
# Setup and initialization functions for test scripts

# Initialize test environment
# Sets up: SCRIPT_DIR, REPO_ROOT, TEST_RESULTS_DIR, TIMESTAMP, RUN_DIR, LOG_FILE, SUMMARY_FILE
# Parameters:
#   $1: Run prefix (e.g., "query_1" or "query_10")
#   $2: Test environment (aws or local)
setup_test_environment() {
    local run_prefix="$1"
    local test_env="$2"
    
    # Determine script directory and repo root
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
    TEST_RESULTS_DIR="$REPO_ROOT/test/test_results"
    
    # Create test results directory and environment subdirectory if they don't exist
    mkdir -p "$TEST_RESULTS_DIR/${test_env}"
    
    # Add stream_ prefix if streaming mode
    if [[ "${USE_STREAM:-false}" == "true" ]]; then
        run_prefix="stream_${run_prefix}"
    fi
    
    # Generate timestamped directory for this test run
    TIMESTAMP=$(date +%Y%m%d-%H%M%S)
    RUN_DIR="$TEST_RESULTS_DIR/${test_env}/${run_prefix}_$TIMESTAMP"
    mkdir -p "$RUN_DIR"
    
    # Result files (standard names)
    LOG_FILE="$RUN_DIR/test_results.log"
    SUMMARY_FILE="$RUN_DIR/test_summary.md"
    
    # Export for use in other functions
    export SCRIPT_DIR REPO_ROOT TEST_RESULTS_DIR TIMESTAMP RUN_DIR LOG_FILE SUMMARY_FILE
}

# Parse test arguments
# Sets: TEST_ENV
# Parameters:
#   $@: Command line arguments
parse_test_args() {
    # Determine script directory and repo root first
    local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    local repo_root="$(cd "$script_dir/.." && pwd)"
    
    TEST_ENV=""
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --test-env)
                TEST_ENV="${2:-}"
                shift 2
                ;;
            *)
                echo "Unknown argument: $1" >&2
                exit 1
                ;;
        esac
    done
    
    if [[ -z "$TEST_ENV" ]]; then
        echo "ERROR: --test-env is required (must be 'aws' or 'local')." >&2
        exit 1
    fi
    
    if [[ "$TEST_ENV" != "aws" ]] && [[ "$TEST_ENV" != "local" ]]; then
        echo "ERROR: --test-env must be 'aws' or 'local'." >&2
        exit 1
    fi
    
    export TEST_ENV
    # Note: cd to repo_root will happen in setup_test_environment or run_test_suite
}

