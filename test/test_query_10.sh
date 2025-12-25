#!/usr/bin/env bash
#
# Enhanced wrapper to run the 10-query API test suite with:
# - Service status checks (for AWS)
# - Per-test timeouts
# - Result logging to timestamped directory
#
# Usage:
#   From the repo root:
#     ./test/test_query_10.sh --test-env aws
#     ./test/test_query_10.sh --test-env local
#
set -euo pipefail

# ============================================================================
# CONFIGURATION CONSTANTS
# ============================================================================
# Timeout per test (in seconds). Based on educated guess:
# - Simple queries: ~30-60s (SQL generation + execution)
# - Complex queries: ~60-120s (multiple iterations, synthesis)
# - Network overhead: ~10-20s (AWS latency, retries)
# Setting to 180s (3 minutes) per test to be safe
PER_TEST_TIMEOUT_SECONDS=180

# Detect timeout command (cross-platform)
# On Linux: 'timeout'
# On macOS with GNU coreutils: 'gtimeout'
# Fallback: use Python's timeout mechanism
TIMEOUT_CMD=""
if command -v timeout >/dev/null 2>&1; then
    TIMEOUT_CMD="timeout"
elif command -v gtimeout >/dev/null 2>&1; then
    TIMEOUT_CMD="gtimeout"
fi
# Note: If TIMEOUT_CMD is empty, Python will handle timeout via signal.alarm()

# ============================================================================
# SETUP
# ============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEST_RESULTS_DIR="$REPO_ROOT/test/test_results"

# Create test results directory if it doesn't exist
mkdir -p "$TEST_RESULTS_DIR"

# Generate timestamped directory for this test run
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
RUN_DIR="$TEST_RESULTS_DIR/query_10_$TIMESTAMP"
mkdir -p "$RUN_DIR"

# Result files
LOG_FILE="$RUN_DIR/test_results.log"
SUMMARY_FILE="$RUN_DIR/test_summary.md"

TEST_ENV=""
API_BASE_URL=""

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

cd "$REPO_ROOT"

# ============================================================================
# ENVIRONMENT SETUP
# ============================================================================
if [[ "$TEST_ENV" == "aws" ]]; then
  # Use the same Terraform outputs used by the AWS verification scripts
  # Set required variables that fetch-deployment-info.sh expects
  DEPLOYMENT_TYPE="${DEPLOYMENT_TYPE:-ecs-full}"
  ENVIRONMENT="${ENVIRONMENT:-dev}"
  DRY_RUN="${DRY_RUN:-false}"
  
  # Source the same utilities as auto_verify_and_manual_hint.sh does
  # shellcheck source=/dev/null
  source "$REPO_ROOT/run_scripts/common/logger.sh" 2>/dev/null || {
    echo "ERROR: Could not source logger.sh" >&2
    exit 1
  }
  # shellcheck source=/dev/null
  source "$REPO_ROOT/run_scripts/common/load-env.sh" 2>/dev/null || {
    echo "ERROR: Could not source load-env.sh" >&2
    exit 1
  }
  # shellcheck source=/dev/null
  load_env_file 2>/dev/null || log_warning "Could not load .env"
  
  # Export variables for child scripts (same as auto_verify_and_manual_hint.sh)
  export DEPLOYMENT_TYPE ENVIRONMENT DRY_RUN REPO_ROOT
  
  # Step 1: Fetch deployment information
  log_step "Fetching deployment information from Terraform..."
  # shellcheck source=/dev/null
  source "$REPO_ROOT/run_scripts/aws/verification/fetch-deployment-info.sh" "$DEPLOYMENT_TYPE" "$ENVIRONMENT" "$DRY_RUN" 2>/dev/null || {
    log_error "Failed to source fetch-deployment-info.sh"
    exit 1
  }
  
  # fetch-deployment-info.sh sets API_URL and FRONTEND_URL when possible
  # Call fetch_terraform_outputs to populate ALB_DNS, CLOUDFRONT_DOMAIN, etc.
  fetch_terraform_outputs

  if [[ -n "${API_URL:-}" ]]; then
    API_BASE_URL="$API_URL"
  else
    log_error "Could not determine API URL from Terraform outputs for aws test env."
    log_error "fetch-deployment-info.sh and fetch_terraform_outputs() did not populate API_URL properly"
    exit 1
  fi
  
  # Step 2: Check service status (fail-fast if services are not ready)
  log_step "Checking service status (fail-fast if not ready)..."
  VERIFICATION_DIR="$REPO_ROOT/run_scripts/aws/verification"
  # shellcheck source=/dev/null
  source "$VERIFICATION_DIR/check-service-status.sh" || {
    log_error "Failed to source check-service-status.sh"
    exit 1
  }
  
  # Check service status - fail-fast if it returns non-zero
  if ! check_service_status "$DEPLOYMENT_TYPE" "$ENVIRONMENT"; then
    log_error "Service status check failed. Services are not ready for testing."
    log_error "Please ensure ECS tasks are running and API is healthy before running tests."
    exit 1
  fi
  log_success "Service status check passed"
  
elif [[ "$TEST_ENV" == "local" ]]; then
  # Default local API URL (matches docker-compose port; adjust if needed)
  API_BASE_URL="http://localhost:5001"
  
  # For local, we can do a simple health check
  if command -v curl >/dev/null 2>&1; then
    if ! curl -sf "$API_BASE_URL/health" >/dev/null 2>&1; then
      echo "WARNING: Local API health check failed. Is the API running at $API_BASE_URL?" >&2
      echo "Continuing anyway..." >&2
    fi
  fi
else
  echo "ERROR: --test-env must be 'aws' or 'local'." >&2
  exit 1
fi

# ============================================================================
# RUN TESTS
# ============================================================================
echo ""
echo "═══════════════════════════════════════════════════════════════════════════════"
echo "Running 10-Query Test Suite"
echo "═══════════════════════════════════════════════════════════════════════════════"
echo "  Test Environment: $TEST_ENV"
echo "  API Base URL:     $API_BASE_URL"
echo "  Per-Test Timeout: ${PER_TEST_TIMEOUT_SECONDS}s"
echo "  Results Directory: $RUN_DIR"
echo "═══════════════════════════════════════════════════════════════════════════════"
echo ""

# Initialize summary file
cat > "$SUMMARY_FILE" <<EOF
# Test Results Summary

**Test Run:** \`query_10_$TIMESTAMP\`  
**Date:** $(date)  
**Environment:** \`$TEST_ENV\`  
**API Base URL:** \`$API_BASE_URL\`  
**Per-Test Timeout:** ${PER_TEST_TIMEOUT_SECONDS}s

## Test Results

| Test # | Name | Status | Duration | Notes |
|--------|------|--------|----------|-------|
EOF

# Initialize log file
{
  echo "Test Run: query_10_$TIMESTAMP"
  echo "Date: $(date)"
  echo "Environment: $TEST_ENV"
  echo "API Base URL: $API_BASE_URL"
  echo "Per-Test Timeout: ${PER_TEST_TIMEOUT_SECONDS}s"
  echo ""
  echo "═══════════════════════════════════════════════════════════════════════════════"
  echo ""
} > "$LOG_FILE"

# Run tests with timeout, capturing results
TOTAL_TESTS=10
PASSED=0
FAILED=0
TIMED_OUT=0

# File to collect failure details for summary
FAILURE_DETAILS_FILE="$RUN_DIR/failure_details.txt"
> "$FAILURE_DETAILS_FILE"  # Initialize empty file

for TEST_NUM in $(seq 1 $TOTAL_TESTS); do
  TEST_START=$(date +%s)
  
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Starting Test $TEST_NUM/10..." | tee -a "$LOG_FILE"
  echo "" >> "$LOG_FILE"
  echo "═══════════════════════════════════════════════════════════════════════════════" >> "$LOG_FILE"
  echo "Test $TEST_NUM/10" >> "$LOG_FILE"
  echo "═══════════════════════════════════════════════════════════════════════════════" >> "$LOG_FILE"
  
  # Run test with timeout, capturing both stdout and stderr directly to main log
  # No individual test log files - everything goes to test_results.log
  if [ -n "$TIMEOUT_CMD" ]; then
    # Use system timeout command (Linux or macOS with GNU coreutils)
    if $TIMEOUT_CMD "${PER_TEST_TIMEOUT_SECONDS}s" \
      python3 -m test.python.test_query_10 \
        --test-api-base-url "$API_BASE_URL" \
        --test-number "$TEST_NUM" \
        --log-file "$LOG_FILE" \
        >> "$LOG_FILE" 2>&1; then
      TEST_EXIT_CODE=0
    else
      TEST_EXIT_CODE=$?
    fi
  else
    # No timeout command - Python will handle timeout internally via signal.alarm()
    if python3 -m test.python.test_query_10 \
      --test-api-base-url "$API_BASE_URL" \
      --test-number "$TEST_NUM" \
      --log-file "$LOG_FILE" \
      --timeout "$PER_TEST_TIMEOUT_SECONDS" \
      >> "$LOG_FILE" 2>&1; then
      TEST_EXIT_CODE=0
    else
      TEST_EXIT_CODE=$?
    fi
  fi
  
  echo "" >> "$LOG_FILE"
  
  if [ "${TEST_EXIT_CODE:-1}" -eq 0 ]; then
    TEST_STATUS="✅ PASS"
    TEST_DURATION=$(($(date +%s) - TEST_START))
    PASSED=$((PASSED + 1))
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Test $TEST_NUM/10: PASSED (${TEST_DURATION}s)" | tee -a "$LOG_FILE"
    
    # Extract test name from log if available
    TEST_NAME=$(grep -m1 "^Test $TEST_NUM:" "$LOG_FILE" 2>/dev/null | sed 's/^Test [0-9]*: //' || echo "Test $TEST_NUM")
    
    echo "| $TEST_NUM | $TEST_NAME | ✅ PASS | ${TEST_DURATION}s | - |" >> "$SUMMARY_FILE"
  else
    TEST_DURATION=$(($(date +%s) - TEST_START))
    
    if [ "${TEST_EXIT_CODE:-1}" -eq 124 ]; then
      # Timeout (exit code 124 from timeout command)
      TEST_STATUS="⏱️ TIMEOUT"
      TIMED_OUT=$((TIMED_OUT + 1))
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] Test $TEST_NUM/10: TIMEOUT after ${PER_TEST_TIMEOUT_SECONDS}s" | tee -a "$LOG_FILE"
      
      TEST_NAME=$(grep -m1 "^Test $TEST_NUM:" "$TEST_LOG" 2>/dev/null | sed 's/^Test [0-9]*: //' || echo "Test $TEST_NUM")
      echo "| $TEST_NUM | $TEST_NAME | ⏱️ TIMEOUT | >${PER_TEST_TIMEOUT_SECONDS}s | Exceeded timeout |" >> "$SUMMARY_FILE"
    else
      # Other failure
      TEST_STATUS="❌ FAIL"
      FAILED=$((FAILED + 1))
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] Test $TEST_NUM/10: FAILED (${TEST_DURATION}s)" | tee -a "$LOG_FILE"
      
      TEST_NAME=$(grep -m1 "^Test $TEST_NUM:" "$LOG_FILE" 2>/dev/null | sed 's/^Test [0-9]*: //' || echo "Test $TEST_NUM")
      
      # Extract failure details from log
      # Find the section for this specific test
      TEST_SECTION=$(awk "/^Test $TEST_NUM:/{flag=1} flag && /^Test [0-9]*:/ && !/^Test $TEST_NUM:/{flag=0} flag" "$LOG_FILE")
      
      if [ -n "$TEST_SECTION" ]; then
        # Extract Expected and Actual from the failure section (get first occurrence only)
        EXPECTED=$(echo "$TEST_SECTION" | grep -m1 "Expected (substring):" | sed 's/Expected (substring): //' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        ACTUAL=$(echo "$TEST_SECTION" | grep -m1 "Actual (full answer):" | sed 's/Actual (full answer): //' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        
        # If not found in structured format, try to extract from assertion error
        if [ -z "$EXPECTED" ] || [ -z "$ACTUAL" ]; then
          # Look for EXPECTED_SUBSTRING_NOT_FOUND format
          EXPECTED=$(echo "$TEST_SECTION" | grep -m1 "^EXPECTED: " | sed 's/^EXPECTED: //' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
          ACTUAL=$(echo "$TEST_SECTION" | grep -m1 "^ACTUAL_FULL: " | sed 's/^ACTUAL_FULL: //' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        fi
        
        # If still not found, try to get from the actual answer line
        if [ -z "$ACTUAL" ]; then
          ACTUAL=$(echo "$TEST_SECTION" | grep -m1 "^Actual Answer:" | sed 's/Actual Answer: //' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        fi
        
        # Save to failure details file for summary (only if we found both)
        if [ -n "$EXPECTED" ] && [ -n "$ACTUAL" ]; then
          {
            echo "### Test $TEST_NUM: $TEST_NAME"
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
          } >> "$FAILURE_DETAILS_FILE"
        fi
      fi
      
      echo "| $TEST_NUM | $TEST_NAME | ❌ FAIL | ${TEST_DURATION}s | See details below |" >> "$SUMMARY_FILE"
    fi
  fi
done

# Add failure details section if there are failures
if [ $FAILED -gt 0 ] && [ -s "$FAILURE_DETAILS_FILE" ]; then
  {
    echo ""
    echo "## Test Failure Details"
    echo ""
    cat "$FAILURE_DETAILS_FILE"
  } >> "$SUMMARY_FILE"
fi

# Finalize summary
{
  echo ""
  echo "## Summary"
  echo ""
  echo "- **Total Tests:** $TOTAL_TESTS"
  echo "- **✅ Passed:** $PASSED"
  echo "- **❌ Failed:** $FAILED"
  echo "- **⏱️ Timed Out:** $TIMED_OUT"
  echo ""
  echo "**Overall Status:** $([ $FAILED -eq 0 ] && [ $TIMED_OUT -eq 0 ] && echo '✅ ALL PASSED' || echo '⚠️ SOME FAILURES')"
  echo ""
  echo "---"
  echo ""
  echo "Full log: \`test_results.log\`"
} >> "$SUMMARY_FILE"

# Print final summary
echo ""
echo "═══════════════════════════════════════════════════════════════════════════════"
echo "Test Suite Complete"
echo "═══════════════════════════════════════════════════════════════════════════════"
echo "  Total Tests:  $TOTAL_TESTS"
echo "  ✅ Passed:     $PASSED"
echo "  ❌ Failed:     $FAILED"
echo "  ⏱️  Timed Out: $TIMED_OUT"
echo "═══════════════════════════════════════════════════════════════════════════════"
echo ""
echo "Results saved to: $RUN_DIR"
echo "  - Summary: $SUMMARY_FILE"
echo "  - Full log: $LOG_FILE"
echo ""

# Exit with non-zero if any tests failed or timed out
if [ $FAILED -gt 0 ] || [ $TIMED_OUT -gt 0 ]; then
  exit 1
else
  exit 0
fi

