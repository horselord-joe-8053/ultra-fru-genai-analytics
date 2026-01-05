#!/bin/bash
# Setup Spark 4.0.1 environment (idempotent)
# Checks if Spark is already configured before setting up
# Usage: ./setup-spark-4.0.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
source "$SCRIPT_DIR/../logger.sh"

# Default Spark installation path
DEFAULT_SPARK_HOME="$HOME/spark/spark-4.0.1-bin-hadoop3"

check_spark_installed() {
    # Check if spark-submit is available and is version 4.0
    if command -v spark-submit >/dev/null 2>&1; then
        if spark-submit --version 2>&1 | grep -qE "version 4\.0"; then
            return 0  # Spark 4.0 is installed
        fi
    fi
    return 1
}

check_java_21() {
    # Check if Java 21 is available
    if [[ "$OSTYPE" == "darwin"* ]]; then
        JAVA_HOME_CANDIDATE=$(/usr/libexec/java_home -v 21 2>/dev/null)
        if [ -n "$JAVA_HOME_CANDIDATE" ]; then
            export JAVA_HOME="$JAVA_HOME_CANDIDATE"
            return 0
        fi
    else
        # Linux: Check for Java 21 in common locations
        for java_dir in /usr/lib/jvm/java-21-openjdk-* /usr/lib/jvm/java-21-*; do
            if [ -d "$java_dir" ] && [ -f "$java_dir/bin/java" ]; then
                export JAVA_HOME="$java_dir"
                return 0
            fi
        done
    fi
    return 1
}

setup_spark_local() {
    log_step "Setting up Spark 4.0.1 environment"
    
    # Idempotency check: If Spark is already configured, skip setup
    if check_spark_installed; then
        log_info "Spark 4.0.1 is already configured"
        SPARK_VERSION=$(spark-submit --version 2>&1 | grep -i "version" | head -1 || echo "Spark 4.0.1")
        log_success "Spark version: $SPARK_VERSION"
        
        # Verify SPARK_HOME is set
        if [ -n "$SPARK_HOME" ]; then
            log_info "SPARK_HOME: $SPARK_HOME"
        else
            log_warning "SPARK_HOME is not set, but spark-submit is in PATH"
        fi
        
        # Verify Java
        if check_java_21; then
            log_info "JAVA_HOME: $JAVA_HOME"
        else
            log_warning "Java 21 not found, but Spark may still work if Java is in PATH"
        fi
        
        return 0
    fi
    
    # Check if Spark is installed at default location
    if [ -d "$DEFAULT_SPARK_HOME" ] && [ -f "$DEFAULT_SPARK_HOME/bin/spark-submit" ]; then
        log_info "Found Spark installation at $DEFAULT_SPARK_HOME"
        export SPARK_HOME="$DEFAULT_SPARK_HOME"
        export PATH="$SPARK_HOME/bin:$PATH"
        
        # Verify it's version 4.0
        if spark-submit --version 2>&1 | grep -qE "version 4\.0"; then
            log_success "Spark 4.0.1 environment configured"
            log_info "SPARK_HOME: $SPARK_HOME"
            
            # Setup Java
            if check_java_21; then
                log_info "JAVA_HOME: $JAVA_HOME"
            else
                log_warning "Java 21 not found. Spark 4.0.x requires Java 21."
                log_info "Install with:"
                if [[ "$OSTYPE" == "darwin"* ]]; then
                    log_info "  brew install openjdk@21"
                else
                    log_info "  sudo apt-get install openjdk-21-jdk  # Ubuntu/Debian"
                    log_info "  sudo yum install java-21-openjdk-devel  # RHEL/CentOS"
                fi
                log_warning "Spark may not work correctly without Java 21"
            fi
            
            return 0
        else
            log_warning "Spark found at $DEFAULT_SPARK_HOME but is not version 4.0"
        fi
    fi
    
    # Spark is not installed
    log_warning "Spark 4.0.1 is not installed or not in PATH"
    log_info ""
    log_info "Spark setup is OPTIONAL because Spark is already installed in Docker:"
    log_info "  - Spark 4.0.1 is built into the fru_api Docker container (Dockerfile.api)"
    log_info "  - The analytics scheduler runs Spark jobs inside the container automatically"
    log_info "  - No local Spark installation needed for normal operation"
    log_info ""
    log_info "You only need local Spark if you want to:"
    log_info "  - Run Spark jobs manually from your host machine (outside Docker)"
    log_info "  - Test Spark scripts directly without Docker"
    log_info "  - Develop/debug Spark jobs locally before containerizing"
    log_info ""
    log_info "To install Spark 4.0.1:"
    log_info "  1. Download from: https://spark.apache.org/downloads.html"
    log_info "  2. Extract to: $DEFAULT_SPARK_HOME"
    log_info "  3. Install Java 21:"
    if [[ "$OSTYPE" == "darwin"* ]]; then
        log_info "     brew install openjdk@21"
    else
        log_info "     sudo apt-get install openjdk-21-jdk"
    fi
    log_info "  4. Re-run this script"
    log_info ""
    log_info "Alternatively, you can set SPARK_HOME environment variable:"
    log_info "  export SPARK_HOME=/path/to/spark-4.0.1-bin-hadoop3"
    log_info "  export PATH=\$SPARK_HOME/bin:\$PATH"
    
    # Don't fail - Spark is optional
    return 0
}

main() {
    setup_spark
}

main "$@"
