#!/bin/bash
# Spark setup for AWS (no-op - Spark runs in container)
# Spark is pre-installed in Docker image, so no setup needed

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../../.." && pwd)}"
source "$REPO_ROOT/run_scripts/shared/logger.sh"

setup_spark_aws() {
    log_step "Spark setup for AWS"
    
    log_info "Spark runs inside the ECS container (pre-installed in Docker image)"
    log_info "No local Spark installation needed for AWS deployments"
    log_info ""
    log_info "Spark is configured via:"
    log_info "  - Dockerfile.api: Installs Spark 4.0.1 to /opt/spark"
    log_info "  - Terraform: Sets SPARK_HOME=/opt/spark environment variable"
    log_info "  - Container: Spark available at /opt/spark/bin/spark-submit"
    
    log_success "Spark setup complete (runs in container)"
    return 0
}

# Function is exported for use by wrapper script
# If executed directly, call the function
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    setup_spark_aws
    exit $?
fi

