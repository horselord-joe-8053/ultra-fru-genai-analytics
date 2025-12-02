#!/bin/bash
# Check if required dependencies are installed
# Returns 0 if all required dependencies are available, 1 otherwise

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/logger.sh"

check_dependency() {
    local cmd=$1
    local required=${2:-true}
    local install_hint=${3:-""}
    
    if command_exists "$cmd"; then
        log_success "$cmd is installed"
        return 0
    else
        if [ "$required" = "true" ]; then
            log_error "$cmd is not installed"
            if [ -n "$install_hint" ]; then
                log_info "Install with: $install_hint"
            fi
            return 1
        else
            log_warning "$cmd is not installed (optional)"
            return 0
        fi
    fi
}

check_all_dependencies() {
    local missing_required=0
    
    log_step "Checking dependencies..."
    
    # Required dependencies
    check_dependency "python3" true "brew install python3" || missing_required=$((missing_required + 1))
    check_dependency "node" true "brew install node" || missing_required=$((missing_required + 1))
    check_dependency "docker" true "Install Docker Desktop from https://www.docker.com/products/docker-desktop" || missing_required=$((missing_required + 1))
    
    # Optional dependencies
    check_dependency "psql" false "brew install postgresql@16 or brew install libpq"
    check_dependency "spark-submit" false "Download from https://spark.apache.org/downloads.html"
    check_dependency "aws" false "brew install awscli"
    check_dependency "terraform" false "brew install terraform"
    
    if [ $missing_required -gt 0 ]; then
        log_error "Missing $missing_required required dependency(ies). Please install them and try again."
        return 1
    fi
    
    log_success "All required dependencies are installed"
    return 0
}

check_all_dependencies
