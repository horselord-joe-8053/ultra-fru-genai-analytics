#!/bin/bash
# Helpers for long-running commands: run a command with periodic heartbeat, or sleep with heartbeat.
# Source this file, then use run_with_heartbeat and sleep_with_heartbeat.
#
# run_with_heartbeat "description" interval_sec [timeout_sec] -- command [args...]
#   Runs command; every interval_sec prints "  Still running: description ... N s elapsed" to stderr (N = accumulated seconds).
#   If timeout_sec is given and the command runs longer, it is killed and the function returns 1.
#   Returns the command's exit code (or 1 on timeout).
#
# sleep_with_heartbeat total_sec interval_sec "message"
#   Sleeps total_sec, printing "  message - N s remaining" to stderr every interval_sec.

run_with_heartbeat() {
    local desc="$1"
    local interval="$2"
    shift 2
    local timeout_sec=""
    if [ "$1" != "--" ]; then
        timeout_sec="$1"
        shift
    fi
    [ "$1" = "--" ] && shift
    if [ $# -eq 0 ]; then
        echo "run_with_heartbeat: no command given" >&2
        return 1
    fi

    local start_sec
    start_sec=$(date +%s 2>/dev/null || echo 0)
    "$@" &
    local pid=$!

    while kill -0 "$pid" 2>/dev/null; do
        sleep "$interval"
        local elapsed
        elapsed=$(($(date +%s 2>/dev/null || echo 0) - start_sec))
        echo "  Still running: $desc ... ${elapsed} s elapsed" >&2
        if [ -n "$timeout_sec" ] && [ "$elapsed" -ge "$timeout_sec" ]; then
            kill "$pid" 2>/dev/null
            wait "$pid" 2>/dev/null
            echo "  Timeout after ${timeout_sec} s." >&2
            return 1
        fi
    done
    wait "$pid"
    return $?
}

sleep_with_heartbeat() {
    local total_sec="$1"
    local interval_sec="$2"
    local message="${3:-waiting}"
    local remaining="$total_sec"
    while [ "$remaining" -gt 0 ]; do
        local sleep_amt="$interval_sec"
        [ "$remaining" -lt "$sleep_amt" ] && sleep_amt="$remaining"
        sleep "$sleep_amt"
        remaining=$((remaining - sleep_amt))
        echo "  $message - ${remaining} s remaining" >&2
    done
}
