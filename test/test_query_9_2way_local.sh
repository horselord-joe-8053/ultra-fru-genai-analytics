#!/usr/bin/env bash
#
# Convenience script to run the 9-query test suite in both sync and stream modes.
# This script runs both test modes sequentially for local environment.
#
# Usage:
#   From the repo root:
#     ./test/test_query_9_2way_local.sh
#
# Notes:
#   - This is a simple convenience script that does not accept additional arguments
#   - It automatically runs both sync and stream modes for local environment
#   - Services are automatically ensured (same as individual test scripts)
#   - Results are saved to separate timestamped directories for each mode
#
set -euo pipefail

# ============================================================================
# SCRIPT CONFIGURATION
# ============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ============================================================================
# MAIN EXECUTION
# ============================================================================

echo "═══════════════════════════════════════════════════════════════════════════════"
echo "Running 9-Query Test Suite - Both Sync and Stream Modes"
echo "═══════════════════════════════════════════════════════════════════════════════"
echo ""

# Run sync mode (direct API calls)
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Phase 1: Running SYNC mode (direct /query endpoint)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
"$SCRIPT_DIR/test_query_9.sh" --test-env local || true
SYNC_EXIT_CODE=${PIPESTATUS[0]}

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Phase 2: Running STREAM mode (Server-Sent Events /query/stream endpoint)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
"$SCRIPT_DIR/test_query_9.sh" --test-env local --stream || true
STREAM_EXIT_CODE=${PIPESTATUS[0]}

# ============================================================================
# SUMMARY
# ============================================================================
echo ""
echo "═══════════════════════════════════════════════════════════════════════════════"
echo "Test Suite Summary - Both Modes"
echo "═══════════════════════════════════════════════════════════════════════════════"
echo ""

if [ $SYNC_EXIT_CODE -eq 0 ]; then
    echo "✅ SYNC mode:   PASSED"
else
    echo "❌ SYNC mode:   FAILED (exit code: $SYNC_EXIT_CODE)"
fi

if [ $STREAM_EXIT_CODE -eq 0 ]; then
    echo "✅ STREAM mode: PASSED"
else
    echo "❌ STREAM mode: FAILED (exit code: $STREAM_EXIT_CODE)"
fi

echo ""

# Determine overall status
if [ $SYNC_EXIT_CODE -eq 0 ] && [ $STREAM_EXIT_CODE -eq 0 ]; then
    echo "🎉 All tests passed in both modes!"
    exit 0
else
    echo "⚠️  Some tests failed. Check the logs above for details."
    exit 1
fi

