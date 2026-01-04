#!/usr/bin/env bash
# Configuration constants for test scripts

# Timeout per test (in seconds). Based on educated guess:
# - Simple queries: ~30-60s (SQL generation + execution)
# - Complex queries: ~60-120s (multiple iterations, synthesis)
# - Network overhead: ~10-20s (AWS latency, retries)
# - Streaming queries may take longer due to event collection
# Setting to 600s (10 minutes) per test to be safe
PER_TEST_TIMEOUT_SECONDS=600

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

# Maximum allowed relative deviation (as decimal) for numeric test validation.
# 0.01 = 1% tolerance. Used when comparing expected vs actual numeric values (e.g., 8.99 vs 9.0).
# This is exported so Python subprocesses can access it via os.environ.get()
export MAX_ALLOWED_NUMERIC_DEVIATION_FOR_TEST=0.01

