#!/bin/bash
# Run Spark job to create Delta table from CSV using Docker container
#
# Usage: run-spark-job-docker.sh <INPUT_PATH> <OUTPUT_PATH> <SPARK_PACKAGES>
#   INPUT_PATH: CSV file path
#   OUTPUT_PATH: Delta table path
#   SPARK_PACKAGES: Maven coordinates (e.g., "io.delta:delta-spark_2.13:4.0.0")

set -e

INPUT_PATH="$1"
OUTPUT_PATH="$2"
SPARK_PACKAGES="$3"
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../../../.." && pwd)}"

if [ -z "$INPUT_PATH" ] || [ -z "$OUTPUT_PATH" ] || [ -z "$SPARK_PACKAGES" ]; then
    echo "Error: INPUT_PATH, OUTPUT_PATH, and SPARK_PACKAGES are required" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$REPO_ROOT/run_scripts/shared/logger.sh"

log_info "Using Spark in Docker container to create Delta table"

# Check if Docker is running and fru_api container exists
if ! docker ps >/dev/null 2>&1 || ! docker ps --filter "name=fru_api" --format "{{.Names}}" | grep -q "fru_api"; then
    log_error "Docker container 'fru_api' is not running"
    log_info "Start Docker services: ./run_scripts/main_application_scripts/local/start-services.sh"
    exit 1
fi

# Check if container has Spark installed
SPARK_SUBMIT_PATH="/opt/spark/bin/spark-submit"
if ! docker exec fru_api test -f "$SPARK_SUBMIT_PATH" 2>/dev/null; then
    log_error "Spark not found in Docker container at: $SPARK_SUBMIT_PATH"
    log_info "Spark should be installed in the Docker image via Dockerfile.api"
    exit 1
fi

# Convert host paths to container paths
# The data directory is mounted at /app/data in the container
CONTAINER_DATA_DIR="/app/data"
HOST_DATA_DIR="$REPO_ROOT/data"

# Convert INPUT_PATH to container path
if [[ "$INPUT_PATH" == "$HOST_DATA_DIR"/* ]]; then
    # Path is within the data directory, convert to container path
    CONTAINER_INPUT_PATH="${INPUT_PATH#$HOST_DATA_DIR}"
    CONTAINER_INPUT_PATH="$CONTAINER_DATA_DIR$CONTAINER_INPUT_PATH"
elif [[ "$INPUT_PATH" == "$REPO_ROOT"/* ]]; then
    # Path is within repo but not in data, try to find relative path
    RELATIVE_PATH="${INPUT_PATH#$REPO_ROOT/}"
    if [[ "$RELATIVE_PATH" == data/* ]]; then
        CONTAINER_INPUT_PATH="/app/$RELATIVE_PATH"
    else
        log_error "Input path must be within the data directory: $INPUT_PATH"
        exit 1
    fi
else
    # Assume it's already a container path or relative path
    if [[ "$INPUT_PATH" == /app/data/* ]]; then
        CONTAINER_INPUT_PATH="$INPUT_PATH"
    elif [[ "$INPUT_PATH" == data/* ]]; then
        CONTAINER_INPUT_PATH="/app/$INPUT_PATH"
    else
        log_error "Cannot determine container path for: $INPUT_PATH"
        exit 1
    fi
fi

# Convert OUTPUT_PATH to container path
if [[ "$OUTPUT_PATH" == "$HOST_DATA_DIR"/* ]]; then
    # Path is within the data directory, convert to container path
    CONTAINER_OUTPUT_PATH="${OUTPUT_PATH#$HOST_DATA_DIR}"
    CONTAINER_OUTPUT_PATH="$CONTAINER_DATA_DIR$CONTAINER_OUTPUT_PATH"
elif [[ "$OUTPUT_PATH" == "$REPO_ROOT"/* ]]; then
    # Path is within repo but not in data, try to find relative path
    RELATIVE_PATH="${OUTPUT_PATH#$REPO_ROOT/}"
    if [[ "$RELATIVE_PATH" == data/* ]]; then
        CONTAINER_OUTPUT_PATH="/app/$RELATIVE_PATH"
    else
        log_error "Output path must be within the data directory: $OUTPUT_PATH"
        exit 1
    fi
else
    # Assume it's already a container path or relative path
    if [[ "$OUTPUT_PATH" == /app/data/* ]]; then
        CONTAINER_OUTPUT_PATH="$OUTPUT_PATH"
    elif [[ "$OUTPUT_PATH" == data/* ]]; then
        CONTAINER_OUTPUT_PATH="/app/$OUTPUT_PATH"
    else
        log_error "Cannot determine container path for: $OUTPUT_PATH"
        exit 1
    fi
fi

log_info "Host input path: $INPUT_PATH -> Container path: $CONTAINER_INPUT_PATH"
log_info "Host output path: $OUTPUT_PATH -> Container path: $CONTAINER_OUTPUT_PATH"

# Execute Spark job inside Docker container
docker exec -w /app -e DELTA_LAKE_PACKAGE="$SPARK_PACKAGES" fru_api \
    "$SPARK_SUBMIT_PATH" \
    --packages "$SPARK_PACKAGES" \
    /app/spark_jobs/ingest_delta.py \
    "$CONTAINER_INPUT_PATH" \
    "$CONTAINER_OUTPUT_PATH" || {
    log_error "Failed to create Delta table using Docker Spark"
    exit 1
}

log_success "Delta table created successfully at: $OUTPUT_PATH"

