#!/bin/bash
# Run Spark job to create Delta table (helper function)
# Supports local and Docker execution methods
# Usage: run-spark-job.sh <INPUT_PATH> <OUTPUT_PATH> <SPARK_PACKAGES> <EXECUTION_METHOD> <SPARK_SUBMIT_PATH>
#   INPUT_PATH: CSV file path
#   OUTPUT_PATH: Delta table path
#   SPARK_PACKAGES: Spark packages (e.g., "io.delta:delta-spark_2.13:4.0.0")
#   EXECUTION_METHOD: "local" or "docker"
#   SPARK_SUBMIT_PATH: Path to spark-submit executable

set -e

INPUT_PATH="$1"
OUTPUT_PATH="$2"
SPARK_PACKAGES="$3"
EXECUTION_METHOD="${4:-local}"
SPARK_SUBMIT_PATH="${5:-spark-submit}"
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../../../.." && pwd)}"

if [ -z "$INPUT_PATH" ] || [ -z "$OUTPUT_PATH" ] || [ -z "$SPARK_PACKAGES" ]; then
    echo "Error: INPUT_PATH, OUTPUT_PATH, and SPARK_PACKAGES are required" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../../logger.sh"

case "$EXECUTION_METHOD" in
    local)
        log_info "Using local Spark to create Delta table"
        
        if ! command -v "$SPARK_SUBMIT_PATH" >/dev/null 2>&1; then
            log_error "spark-submit not found at: $SPARK_SUBMIT_PATH"
            log_info "Install Spark locally or use Docker execution method"
            exit 1
        fi
        
        "$SPARK_SUBMIT_PATH" \
            --packages "$SPARK_PACKAGES" \
            "$REPO_ROOT/spark_jobs/ingest_delta.py" \
            "$INPUT_PATH" \
            "$OUTPUT_PATH" || {
            log_error "Failed to create Delta table using local Spark"
            exit 1
        }
        
        log_success "Delta table created successfully using local Spark"
        ;;
    docker)
        log_info "Using Spark in Docker container to create Delta table"
        
        if ! docker ps >/dev/null 2>&1 || ! docker ps --filter "name=fru_api" --format "{{.Names}}" | grep -q "fru_api"; then
            log_error "Docker container 'fru_api' is not running"
            log_info "Start Docker services: ./run_scripts/local/start-services.sh"
            exit 1
        fi
        
        # Check if container has Spark installed
        if ! docker exec fru_api test -f "$SPARK_SUBMIT_PATH" 2>/dev/null; then
            log_error "Spark not found in Docker container at: $SPARK_SUBMIT_PATH"
            exit 1
        fi
        
        docker exec -w /app -e DELTA_LAKE_PACKAGE="$SPARK_PACKAGES" fru_api \
            "$SPARK_SUBMIT_PATH" \
            --packages "$SPARK_PACKAGES" \
            /app/spark_jobs/ingest_delta.py \
            "$INPUT_PATH" \
            "$OUTPUT_PATH" || {
            log_error "Failed to create Delta table using Docker Spark"
            exit 1
        }
        
        log_success "Delta table created successfully using Docker Spark"
        ;;
    *)
        log_error "Unknown execution method: $EXECUTION_METHOD (must be 'local' or 'docker')"
        exit 1
        ;;
esac

