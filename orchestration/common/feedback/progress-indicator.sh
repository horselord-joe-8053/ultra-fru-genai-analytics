#!/bin/bash
# Progress indicator and heartbeat system for long-running operations
# Provides periodic progress updates and heartbeat messages to show activity
#
# Usage:
#   source "$REPO_ROOT/orchestration/common/feedback/progress-indicator.sh"
#   
#   # Option 1: Wrap a command with progress indicator
#   progress_wrap "Building Docker image..." docker build -t myimage .
#   
#   # Option 2: Start a progress indicator for a long-running operation
#   progress_start "Deploying infrastructure..."
#   # ... do work ...
#   progress_end
#   
#   # Option 3: Show periodic heartbeat during operation
#   progress_heartbeat_start "Waiting for EKS cluster..." 10
#   # ... do work ...
#   progress_heartbeat_stop

# Global variables
PROGRESS_PID=""
PROGRESS_MESSAGE=""
PROGRESS_INTERVAL=10  # Default heartbeat interval in seconds
PROGRESS_COUNTER=0

# Source logger if available
if [ -z "${RED:-}" ]; then
    # Try to source logger.sh
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../../.." && pwd)}"
    if [ -f "$REPO_ROOT/orchestration/common/logger.sh" ]; then
        source "$REPO_ROOT/orchestration/common/logger.sh"
    else
        # Fallback to basic logging
        RED='\033[0;31m'
        GREEN='\033[0;32m'
        YELLOW='\033[1;33m'
        BLUE='\033[0;34m'
        NC='\033[0m'
        log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
        log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
        log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
        log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }
    fi
fi

# Format elapsed time
format_elapsed_time() {
    local seconds=$1
    if [ "$seconds" -lt 60 ]; then
        echo "${seconds}s"
    elif [ "$seconds" -lt 3600 ]; then
        local mins=$((seconds / 60))
        local secs=$((seconds % 60))
        echo "${mins}m ${secs}s"
    else
        local hours=$((seconds / 3600))
        local mins=$(((seconds % 3600) / 60))
        local secs=$((seconds % 60))
        echo "${hours}h ${mins}m ${secs}s"
    fi
}

# Start a progress indicator for a long-running operation
# Usage: progress_start "Message" [interval_seconds]
progress_start() {
    local message="${1:-Processing...}"
    local interval="${2:-${PROGRESS_INTERVAL}}"
    
    PROGRESS_MESSAGE="$message"
    PROGRESS_INTERVAL="$interval"
    PROGRESS_COUNTER=0
    
    log_info "[PROGRESS] $message (heartbeat every ${interval}s)"
    
    # Start background heartbeat process
    (
        while true; do
            sleep "$interval"
            PROGRESS_COUNTER=$((PROGRESS_COUNTER + 1))
            local elapsed=$((PROGRESS_COUNTER * interval))
            log_info "[PROGRESS] $message ... still running (${elapsed}s elapsed, heartbeat #${PROGRESS_COUNTER})"
        done
    ) &
    
    PROGRESS_PID=$!
    export PROGRESS_PID PROGRESS_MESSAGE PROGRESS_INTERVAL PROGRESS_COUNTER
}

# Stop the progress indicator
progress_stop() {
    if [ -n "$PROGRESS_PID" ] && kill -0 "$PROGRESS_PID" 2>/dev/null; then
        kill "$PROGRESS_PID" 2>/dev/null || true
        wait "$PROGRESS_PID" 2>/dev/null || true
        PROGRESS_PID=""
        
        if [ "$PROGRESS_COUNTER" -gt 0 ]; then
            local total_elapsed=$((PROGRESS_COUNTER * PROGRESS_INTERVAL))
            log_success "[PROGRESS] $PROGRESS_MESSAGE ... completed (total time: $(format_elapsed_time $total_elapsed))"
        fi
    fi
    PROGRESS_COUNTER=0
}

# Wrap a command with progress indicator
# Usage: progress_wrap "Message" [interval] command [args...]
progress_wrap() {
    local message="$1"
    shift
    
    # Check if second argument is a number (interval) or a command
    local interval="${PROGRESS_INTERVAL}"
    if [[ "$1" =~ ^[0-9]+$ ]]; then
        interval="$1"
        shift
    fi
    
    progress_start "$message" "$interval"
    
    # Execute the command
    local exit_code=0
    "$@" || exit_code=$?
    
    progress_stop
    
    return $exit_code
}

# Start a heartbeat indicator (simpler version, just shows periodic messages)
# Usage: progress_heartbeat_start "Message" [interval]
progress_heartbeat_start() {
    local message="${1:-Processing...}"
    local interval="${2:-${PROGRESS_INTERVAL}}"
    
    PROGRESS_MESSAGE="$message"
    PROGRESS_INTERVAL="$interval"
    PROGRESS_COUNTER=0
    
    # Start background heartbeat process
    (
        local counter=0
        while true; do
            sleep "$interval"
            counter=$((counter + 1))
            local elapsed=$((counter * interval))
            log_info "[HEARTBEAT] $message ... (${elapsed}s elapsed)"
        done
    ) &
    
    PROGRESS_PID=$!
    export PROGRESS_PID PROGRESS_MESSAGE PROGRESS_INTERVAL PROGRESS_COUNTER
}

# Stop heartbeat indicator
progress_heartbeat_stop() {
    progress_stop
}

# Cleanup function to ensure progress indicators are stopped on exit
progress_cleanup() {
    progress_stop
}

# Register cleanup trap
trap progress_cleanup EXIT INT TERM

# Show progress for a specific operation with custom message
# Usage: progress_show "Operation description" command [args...]
progress_show() {
    local operation="$1"
    shift
    
    log_info "[PROGRESS] Starting: $operation"
    local start_time=$(date +%s)
    
    # Start heartbeat
    progress_heartbeat_start "$operation" "${PROGRESS_INTERVAL}"
    
    # Execute command
    local exit_code=0
    "$@" || exit_code=$?
    
    # Stop heartbeat
    progress_heartbeat_stop
    
    local end_time=$(date +%s)
    local elapsed=$((end_time - start_time))
    
    if [ $exit_code -eq 0 ]; then
        log_success "[PROGRESS] Completed: $operation (took $(format_elapsed_time $elapsed))"
    else
        log_error "[PROGRESS] Failed: $operation (took $(format_elapsed_time $elapsed))"
    fi
    
    return $exit_code
}

# Monitor a long-running command with progress updates
# Usage: progress_monitor "Description" command [args...]
progress_monitor() {
    local description="$1"
    shift
    
    local start_time=$(date +%s)
    log_info "[PROGRESS] $description"
    
    # Start heartbeat in background
    progress_heartbeat_start "$description" "${PROGRESS_INTERVAL}"
    
    # Run command and capture output
    local exit_code=0
    local output_file=$(mktemp)
    
    # Run command in background and capture PID
    "$@" > "$output_file" 2>&1 &
    local cmd_pid=$!
    
    # Monitor command and show progress
    local last_update=0
    while kill -0 "$cmd_pid" 2>/dev/null; do
        sleep 2
        local current_time=$(date +%s)
        local elapsed=$((current_time - start_time))
        
        # Show update every interval
        if [ $((elapsed - last_update)) -ge "$PROGRESS_INTERVAL" ]; then
            log_info "[PROGRESS] $description ... still running ($(format_elapsed_time $elapsed) elapsed)"
            last_update=$elapsed
        fi
    done
    
    # Wait for command to finish
    wait "$cmd_pid"
    exit_code=$?
    
    # Stop heartbeat
    progress_heartbeat_stop
    
    # Show final output
    if [ -s "$output_file" ]; then
        cat "$output_file"
    fi
    rm -f "$output_file"
    
    local end_time=$(date +%s)
    local total_elapsed=$((end_time - start_time))
    
    if [ $exit_code -eq 0 ]; then
        log_success "[PROGRESS] $description completed (took $(format_elapsed_time $total_elapsed))"
    else
        log_error "[PROGRESS] $description failed (took $(format_elapsed_time $total_elapsed))"
    fi
    
    return $exit_code
}

