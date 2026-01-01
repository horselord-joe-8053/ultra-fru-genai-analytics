#!/usr/bin/env bash
#
# Enhanced wrapper to run the 10-query API test suite with:
# - Service status checks (for AWS)
# - Per-test timeouts
# - Result logging to timestamped directory
#
# Usage:
#   From the repo root:
#
#   AWS Environment:
#     ./test/test_query_10.sh --test-env aws
#     ./test/test_query_10.sh --test-env aws --use-cached-aws-val
#
#   Local Environment (automatically ensures services are running):
#     ./test/test_query_10.sh --test-env local
#     # Behavior:
#     #   - If services are up: runs tests immediately (fast)
#     #   - If services are down but images exist: starts services (no build)
#     #   - If services are down and images missing: builds missing images, then starts
#
#   Local Environment (force rebuild all images):
#     ./test/test_query_10.sh --test-env local --force-rebuild-local-img
#
# Notes:
#   - For local testing, services are automatically ensured (implicit requirement)
#   - --force-rebuild-local-img rebuilds all Docker images before starting services
#   - Image existence is checked to avoid unnecessary builds
#   - This test suite runs 10 queries: AVG, BRD, CNT, PCT, NOI, R07, AVP, TMP, RDS, TOP
#
set -euo pipefail

# ============================================================================
# TEST CONFIGURATION
# ============================================================================
TEST_QUERY_PREFIX="query_10"
TEST_CODES=("AVG" "BRD" "CNT" "PCT" "NOI" "R07" "AVP" "TMP" "RDS" "TOP")

# ============================================================================
# SETUP
# ============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source common test suite runner (which sources all needed functions)
# shellcheck source=/dev/null
source "$SCRIPT_DIR/common_sh/run_test_suite.sh"

# Run test suite (passes all arguments and test codes)
run_test_suite "$TEST_QUERY_PREFIX" "$@" "${TEST_CODES[@]}"
