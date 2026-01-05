#!/bin/bash
# Check if Delta table exists (helper function)
# Supports filesystem and S3 path checking
# Usage: check-delta-table-exists.sh <PATH> <METHOD>
#   PATH: Path to Delta table (filesystem or S3)
#   METHOD: "filesystem" or "s3"
# Returns: 0 if exists, 1 if not

set -e

PATH_TO_CHECK="$1"
METHOD="${2:-filesystem}"

if [ -z "$PATH_TO_CHECK" ]; then
    echo "Error: Path required" >&2
    exit 1
fi

case "$METHOD" in
    filesystem)
        # Check for _delta_log directory
        if [ -d "$PATH_TO_CHECK/_delta_log" ]; then
            # Quick validation - check for log entries
            DELTA_LOG_COUNT=$(find "$PATH_TO_CHECK/_delta_log" -name "*.json" 2>/dev/null | wc -l | tr -d ' ')
            if [ "$DELTA_LOG_COUNT" -gt 0 ]; then
                exit 0  # Exists and valid
            fi
        fi
        exit 1  # Doesn't exist or invalid
        ;;
    s3)
        # Check for _delta_log directory in S3
        # Use AWS CLI to check (requires AWS_PROFILE or credentials)
        if aws s3 ls "$PATH_TO_CHECK/_delta_log/" --profile "${AWS_PROFILE:-admin}" >/dev/null 2>&1; then
            # Quick validation - count log entries
            DELTA_LOG_COUNT=$(aws s3 ls "$PATH_TO_CHECK/_delta_log/" --profile "${AWS_PROFILE:-admin}" 2>/dev/null | wc -l | tr -d ' ')
            if [ "$DELTA_LOG_COUNT" -gt 0 ]; then
                exit 0  # Exists and valid
            fi
        fi
        exit 1  # Doesn't exist or invalid
        ;;
    *)
        echo "Error: Unknown method: $METHOD (must be 'filesystem' or 's3')" >&2
        exit 1
        ;;
esac

