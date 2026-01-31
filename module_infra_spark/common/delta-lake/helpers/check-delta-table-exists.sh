#!/bin/bash
# Check if Delta table exists (uses Python helper for consistency)
#
# Usage: check-delta-table-exists.sh <PATH> <METHOD> [IS_ECS] [IS_EKS]
#   PATH: Path to Delta table (filesystem or S3)
#   METHOD: "filesystem" or "s3"
#   IS_ECS: "true" or "false" (optional, auto-detected from METHOD)
#   IS_EKS: "true" or "false" (optional, defaults to false)
#
# Returns: 0 if exists, 1 if not

# Don't use set -e here because we need to handle exit codes explicitly

PATH_TO_CHECK="$1"
METHOD="${2:-filesystem}"
IS_ECS="${3:-false}"
IS_EKS="${4:-false}"

if [ -z "$PATH_TO_CHECK" ]; then
    echo "Error: Path required" >&2
    exit 1
fi

# Auto-detect AWS deployment from method
if [ "$METHOD" = "s3" ] && [ "$IS_ECS" = "false" ]; then
    IS_ECS="true"
fi

# Use Python helper (single source of truth for verification logic)
# Fall back to AWS CLI if Python/boto3 is not available
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../../../.." && pwd)}"
source "$REPO_ROOT/orchestration/common/env/load-python-env.sh"

# Try Python verification first using CLI function with enhanced error handling
# Exit codes: 0 = exists, 1 = not exists, 2 = error (fallback needed)
PYTHON_OUTPUT=$("$PYTHON_CMD" -m spark_jobs.utils.verify_delta_table \
    "$PATH_TO_CHECK" \
    "$REPO_ROOT" \
    "$IS_ECS" \
    "$IS_EKS" \
    "INFO" 2>&1)
PYTHON_EXIT_CODE=$?

if [ $PYTHON_EXIT_CODE -eq 0 ]; then
    # Python verification succeeded
    exit 0
elif [ $PYTHON_EXIT_CODE -eq 1 ]; then
    # Python verification failed (table doesn't exist)
    exit 1
else
    # Python verification failed due to missing dependencies, fall back to AWS CLI
    if [ "$METHOD" = "s3" ]; then
        # For S3 paths, check for _delta_log directory using AWS CLI
        # Convert s3a:// to s3:// for AWS CLI compatibility
        S3_PATH="${PATH_TO_CHECK}"
        S3_PATH="${S3_PATH#s3a://}"  # Remove s3a:// prefix if present
        S3_PATH="${S3_PATH#s3://}"   # Remove s3:// prefix if present (in case already converted)
        DELTA_LOG_PATH="s3://${S3_PATH%/}/_delta_log/"
        
        # Check using AWS CLI with error visibility
        aws_check_output=$(aws s3 ls "$DELTA_LOG_PATH" --profile "${AWS_PROFILE:-admin}" --region "${AWS_REGION:-us-east-1}" 2>&1)
        aws_check_exit=$?
        if [ $aws_check_exit -eq 0 ]; then
            exit 0
        else
            # Log error for debugging (only if it's not a "not found" error)
            if ! echo "$aws_check_output" | grep -q "does not exist\|NoSuchBucket\|404"; then
                echo "Warning: AWS CLI check failed (exit code: $aws_check_exit)" >&2
                echo "Error: ${aws_check_output:0:200}" >&2
            fi
            exit 1
        fi
    else
        # For local filesystem, check directly
        DELTA_LOG_PATH="${PATH_TO_CHECK%/}/_delta_log"
        if [ -d "$DELTA_LOG_PATH" ]; then
            exit 0
        else
            exit 1
        fi
    fi
fi

