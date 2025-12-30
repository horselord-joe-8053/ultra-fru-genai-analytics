#!/usr/bin/env bash
#
# Test script for a single query: Top 3 problems for low-rating feedbacks
#
# Usage:
#   From the repo root:
#     ./test/test_query_1.sh --test-env aws
#     ./test/test_query_1.sh --test-env local
#     ./test/test_query_1.sh --test-env aws --use-cached-aws-val
#
set -euo pipefail

# ============================================================================
# TEST CONFIGURATION
# ============================================================================
TEST_QUERY_PREFIX="query_1_avg"
# TEST_CODES=("TOP")
TEST_CODES=("AVG")

# ============================================================================
# SETUP
# ============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source common test suite runner (which sources all needed functions)
# shellcheck source=/dev/null
source "$SCRIPT_DIR/common_sh/run_test_suite.sh"

# Run test suite (passes all arguments and test codes)
run_test_suite "$TEST_QUERY_PREFIX" "$@" "${TEST_CODES[@]}"
