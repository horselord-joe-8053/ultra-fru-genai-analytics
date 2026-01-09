#!/bin/bash
set -e

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
echo "[entrypoint] Starting Flask API server..."
exec python -m backend.api.app


