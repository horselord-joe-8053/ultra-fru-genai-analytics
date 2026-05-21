#!/bin/bash
# Trigger analytics once in local Docker container
# Simple wrapper that calls Python module directly
#
# Usage: trigger-analytics-local.sh
#   Runs analytics in background (non-blocking)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# From helpers/local/ -> helpers/ -> delta-lake/ -> common/ -> spark_delta-lake_scripts/ -> run_scripts/ -> root (6 levels up)
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../../../../../../.." && pwd)}"
source "$REPO_ROOT/lib/logger.sh"

# Check if Docker container is running
if ! docker ps >/dev/null 2>&1 || ! docker ps --filter "name=fru_api" --format "{{.Names}}" | grep -q "fru_api"; then
    log_error "Docker container 'fru_api' is not running"
    log_info "Start Docker services: ./run_scripts/main_application_scripts/local/start-services.sh"
    exit 1
fi

log_info "Triggering analytics job in Docker container..."

# Call Python module directly via docker exec
# Set PYTHONPATH to ensure spark_jobs module can be imported
# Run in background (non-blocking) to avoid delaying setup script
docker exec -e PYTHONPATH=/app fru_api python /app/spark_jobs/utils/run_analytics_once.py &
ANALYTICS_PID=$!

log_info "Analytics job started in background (PID: $ANALYTICS_PID)"
log_info "Scheduler will also run analytics periodically (safety net)"

# Don't wait - let it run independently
# Exit immediately (setup script continues)
exit 0

