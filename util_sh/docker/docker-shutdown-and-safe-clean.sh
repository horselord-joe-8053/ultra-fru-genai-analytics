#!/usr/bin/env bash
# ============================================================
# docker-shutdown-and-safe-clean.sh
#
# Purpose
#   Clean up Docker resources SAFELY on macOS when using Docker Desktop,
#   without nuking Docker Desktop internal state.
#
# What it does
#   1) Runs safe prune commands while Docker is running (reclaim space first)
#   2) Gracefully quits Docker Desktop (if running)
#   3) Waits for the backend to stop
#
# What it does NOT do
#   - Does NOT delete ~/Library/Containers/com.docker.docker
#   - Does NOT factory reset Docker Desktop
#   - Does NOT force-kill root helpers
#
# Usage
#   chmod +x docker-shutdown-and-safe-clean.sh
#   ./docker-shutdown-and-safe-clean.sh
#
# Optional environment variables
#   PRUNE_ALL=1        # Also prune unused images (-a)
#   PRUNE_VOLUMES=1    # Also prune unused volumes
#   TIMEOUT_SECS=60    # How long to wait for Docker Desktop to shut down
#
# Notes
#   - If Docker Desktop is already wedged (won't quit), use docker-unstick-desktop-start.sh first.
# ============================================================

set -euo pipefail

TIMEOUT_SECS="${TIMEOUT_SECS:-60}"
PRUNE_ALL="${PRUNE_ALL:-0}"
PRUNE_VOLUMES="${PRUNE_VOLUMES:-0}"

# --- Phase 1: Prune while Docker is running (must run before quit) ---
DOCKER_REACHABLE=false
if ! command -v docker >/dev/null 2>&1; then
  echo "!! docker CLI not found in PATH. Skipping prune."
else
  # Retry docker info a few times (engine may still be starting, or IDE env may not see socket)
  for i in 1 2 3 4 5; do
    if docker info >/dev/null 2>&1; then
      DOCKER_REACHABLE=true
      break
    fi
    [[ $i -lt 5 ]] && sleep 2
  done
  if [[ "$DOCKER_REACHABLE" == "true" ]]; then
    echo "==> Running safe prune commands (while Docker is running)..."
    if [[ "${PRUNE_ALL}" == "1" ]]; then
      echo "    - docker system prune -f -a"
      docker system prune -f -a || true
    else
      echo "    - docker system prune -f"
      docker system prune -f || true
    fi
    echo "    - docker builder prune -f"
    docker builder prune -f || true
    if [[ "${PRUNE_VOLUMES}" == "1" ]]; then
      echo "    - docker volume prune -f (WARNING: deletes unused volumes)"
      docker volume prune -f || true
    else
      echo "    - Skipping volume prune (set PRUNE_VOLUMES=1 to enable)"
    fi
    echo "==> Prune completed."
  else
    echo "==> Docker engine not reachable after retries. Skipping prune (will quit Desktop only)."
    echo "    Tip: Run this script from your own terminal (not from an IDE) so it can reach Docker."
  fi
fi

# --- Phase 2: Quit Docker Desktop ---
echo "==> Requesting Docker Desktop to quit (graceful)..."
osascript -e 'quit app "Docker"' >/dev/null 2>&1 || true

# Wait for com.docker.backend to disappear
echo "==> Waiting for Docker backend to stop (timeout: ${TIMEOUT_SECS}s)..."
start_ts="$(date +%s)"
while true; do
  if ! pgrep -f "com.docker.backend" >/dev/null 2>&1; then
    break
  fi

  now_ts="$(date +%s)"
  elapsed="$(( now_ts - start_ts ))"
  if (( elapsed >= TIMEOUT_SECS )); then
    echo "!! Timeout waiting for Docker Desktop to quit."
    echo "   If Docker Desktop is stuck, run: ./util_sh/docker/docker-unstick-desktop-start.sh"
    exit 1
  fi

  sleep 1
done

echo "==> Docker Desktop backend is stopped."
echo "==> Done. Safe cleanup and shutdown completed."
