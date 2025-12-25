#!/usr/bin/env bash
# Configuration constants for test scripts

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

