#!/usr/bin/env bash
#
# Test script for query: Average feedback rating
#
# Usage:
#   From the repo root:
#
#   AWS Environment (synchronous API):
#     ./test/test_query_1_AVG.sh --test-env aws
#     ./test/test_query_1_AVG.sh --test-env aws --use-cached-aws-val
#
#   AWS Environment (streaming API):
#     ./test/test_query_1_AVG.sh --test-env aws --stream
#     ./test/test_query_1_AVG.sh --test-env aws --use-cached-aws-val --stream
#
#   Local Environment (synchronous API, automatically ensures services are running):
#     ./test/test_query_1_AVG.sh --test-env local
#     # Behavior:
#     #   - If services are up: runs tests immediately (fast)
#     #   - If services are down but images exist: starts services (no build)
#     #   - If services are down and images missing: builds missing images, then starts
#
#   Local Environment (streaming API):
#     ./test/test_query_1_AVG.sh --test-env local --stream
#
#   Local Environment (force rebuild all images):
#     ./test/test_query_1_AVG.sh --test-env local --force-rebuild-local-img
#     ./test/test_query_1_AVG.sh --test-env local --force-rebuild-local-img --stream
#
# Notes:
#   - For local testing, services are automatically ensured (implicit requirement)
#   - --force-rebuild-local-img rebuilds all Docker images before starting services
#   - Image existence is checked to avoid unnecessary builds
#   - --stream flag uses the /query/stream endpoint (Server-Sent Events) instead of /query
#   - Streaming mode provides real-time progress updates during query processing
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
