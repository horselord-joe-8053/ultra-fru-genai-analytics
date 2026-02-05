#!/bin/bash
# Note: Removed 'set -e' to allow better error handling and logging
# Exit codes are checked explicitly instead

# Docker entrypoint for the FRU API container.
# 
# Responsibilities:
# - Optionally start the Spark analytics scheduler in the background
#   (controlled purely by environment variables).
# - Then start the Flask API in the foreground as PID 1.
# 
# Why this script exists:
# - We want API and scheduler to be decoupled at the application level:
#     - Flask app focuses only on HTTP routes and DB access.
#     - Scheduler is a separate Python module: spark_jobs.run_scheduler.
# - But they still run inside the same container image (for now).
# - Docker can only exec a single foreground process via CMD/ENTRYPOINT.
#   This script acts as a tiny process supervisor for that container.

# Start scheduler in background (if enabled via env var).
#   ENABLE_ANALYTICS_SCHEDULER=true   → scheduler runs
#   anything else / unset            → scheduler is skipped
if [ "${ENABLE_ANALYTICS_SCHEDULER}" = "true" ]; then
    echo "[entrypoint] ENABLE_ANALYTICS_SCHEDULER=true → starting analytics scheduler..."
    python -m spark_jobs.run_scheduler &
    SCHEDULER_PID=$!
    echo "[entrypoint] Analytics scheduler started (PID: ${SCHEDULER_PID})"

    # Trap termination signals to gracefully stop the scheduler process.
    # Flask will be PID 1 after exec below; this trap still ensures we
    # clean up the background scheduler if the container is stopped.
    trap 'echo "[entrypoint] Stopping analytics scheduler..."; kill "${SCHEDULER_PID}" 2>/dev/null || true; exit' SIGTERM SIGINT
else
    echo "[entrypoint] ENABLE_ANALYTICS_SCHEDULER is not \"true\" → scheduler will NOT run."
fi

# Check if command arguments were provided (e.g., from ECS task override)
# If so, execute them instead of starting Flask
if [ $# -gt 0 ]; then
    echo "[entrypoint] Command arguments provided, executing: $@"
    exec "$@"
fi

# Finally, start the Flask API (foreground).
# This replaces the shell with the Python process (PID 1 in the container).
echo "[entrypoint] ============================================================"
echo "[entrypoint] Starting Flask API server..."
echo "[entrypoint] ============================================================"

# Pre-flight checks and environment logging
echo "[entrypoint] Pre-flight checks..."
echo "[entrypoint]   Python executable: $(which python)"
echo "[entrypoint]   Python version: $(python --version 2>&1)"
echo "[entrypoint]   Working directory: $(pwd)"
echo "[entrypoint]   PYTHONPATH: ${PYTHONPATH:-not set}"
echo "[entrypoint]   PYTHONUNBUFFERED: ${PYTHONUNBUFFERED:-not set}"

# Test Python import capability
echo "[entrypoint] Testing Python import capability..."
python -u -c "
import sys
sys.path.insert(0, '/app')
try:
    print('[entrypoint] Testing: import backend.api.app')
    import backend.api.app
    print('[entrypoint] SUCCESS: Module import test passed')
except Exception as e:
    print(f'[entrypoint] ERROR: Module import test failed: {e}')
    import traceback
    traceback.print_exc()
    sys.exit(1)
" || {
    exit_code=$?
    echo "[entrypoint] CRITICAL: Module import test failed with exit code $exit_code" >&2
    exit $exit_code
}

# Set environment variables for Python
export PYTHONUNBUFFERED=1
export PYTHONPATH=/app
cd /app

# Start Flask application with error capture
echo "[entrypoint] Starting Flask application..."
echo "[entrypoint] Command: python -u -m backend.api.app"
echo "[entrypoint] ============================================================"

# Run Python and capture exit code (don't use exec so we can capture exit code)
python -u -m backend.api.app 2>&1
python_exit_code=$?

if [ $python_exit_code -ne 0 ]; then
    echo "[entrypoint] ============================================================" >&2
    echo "[entrypoint] CRITICAL: Python process exited with code $python_exit_code" >&2
    echo "[entrypoint] Check logs above for error details" >&2
    echo "[entrypoint] ============================================================" >&2
    exit $python_exit_code
fi
