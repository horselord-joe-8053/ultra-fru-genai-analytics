#!/usr/bin/env bash
# ============================================================
# docker-unstick.sh
#
# Purpose
#   Unstick Docker Desktop on macOS when it gets wedged after cleanup commands,
#   typically when com.docker.backend is stuck and/or respawning.
#
# What it does
#   1) Tries to quit Docker Desktop
#   2) Force-kills com.docker.backend (handles respawn by repeating until stable)
#   3) Force-kills the privileged network helper (com.docker.vmnetd) via sudo
#   4) Verifies processes are gone
#   5) Re-launches Docker Desktop
#
# Usage
#   chmod +x docker-unstick.sh
#   ./docker-unstick.sh
#
# Optional environment variables
#   MAX_ATTEMPTS=10        # Max loops to handle backend respawn
#   SLEEP_BETWEEN=1        # Seconds between attempts
#   START_DOCKER=1         # Set to 0 to NOT auto-start Docker Desktop at the end
#
# Notes
#   - Requires sudo to kill com.docker.vmnetd.
#   - This does NOT factory reset Docker Desktop; it aims to recover without data loss.
# ============================================================

set -euo pipefail

MAX_ATTEMPTS="${MAX_ATTEMPTS:-10}"
SLEEP_BETWEEN="${SLEEP_BETWEEN:-1}"
START_DOCKER="${START_DOCKER:-1}"

echo "==> Asking Docker Desktop to quit (best effort)..."
osascript -e 'quit app "Docker"' >/dev/null 2>&1 || true

# Function: list matching PIDs (empty output if none)
backend_pids() {
  # pgrep returns non-zero if no match, so we swallow errors
  pgrep -f "com.docker.backend" 2>/dev/null || true
}

echo "==> Attempting to stop com.docker.backend (handling respawn)..."
attempt=1
while true; do
  pids="$(backend_pids)"

  if [[ -z "${pids}" ]]; then
    echo "==> com.docker.backend is not running."
    break
  fi

  echo "    Attempt ${attempt}/${MAX_ATTEMPTS}: killing backend PID(s): ${pids}"
  # Try a normal kill first (TERM), then hard kill (KILL).
  # Some stuck processes ignore TERM; KILL will stop them.
  kill ${pids} >/dev/null 2>&1 || true
  sleep "${SLEEP_BETWEEN}"
  pids_after="$(backend_pids)"
  if [[ -n "${pids_after}" ]]; then
    echo "    Backend still present; forcing kill -9 on PID(s): ${pids_after}"
    kill -9 ${pids_after} >/dev/null 2>&1 || true
  fi

  sleep "${SLEEP_BETWEEN}"

  # Check again — if it respawned, loop
  pids_check="$(backend_pids)"
  if [[ -z "${pids_check}" ]]; then
    echo "==> Backend stopped successfully."
    break
  fi

  attempt=$(( attempt + 1 ))
  if (( attempt > MAX_ATTEMPTS )); then
    echo "!! Failed to stop com.docker.backend after ${MAX_ATTEMPTS} attempts."
    echo "   It is likely being respawned by a supervisor that is still alive."
    echo "   Try: pkill -9 -f \"/Applications/Docker.app\""
    echo "   Then re-run this script."
    exit 1
  fi

  echo "    Detected respawn; retrying..."
done

echo "==> Stopping privileged helper com.docker.vmnetd (requires sudo)..."
# If vmnetd isn't running, pkill exits non-zero; that's fine.
sudo pkill -9 -f "com.docker.vmnetd" >/dev/null 2>&1 || true

echo "==> Verifying Docker-related processes are gone..."
ps aux | egrep -i "docker desktop|com\.docker" | grep -v egrep || true

if [[ "${START_DOCKER}" == "1" ]]; then
  echo "==> Launching Docker Desktop..."
  open -a Docker

  echo "==> Docker Desktop launched. If it still spins on 'Starting', check logs:"
  echo "    log show --style syslog --last 5m | egrep -i \"docker|com.docker|vpnkit|hyperkit|qemu|lima\" | tail -200"
else
  echo "==> START_DOCKER=0, not launching Docker Desktop."
fi