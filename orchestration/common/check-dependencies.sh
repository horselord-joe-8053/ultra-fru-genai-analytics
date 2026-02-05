#!/bin/bash
# Check if required dependencies are installed
# Returns 0 if all required dependencies are available, 1 otherwise

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
source "$REPO_ROOT/lib/logger.sh"

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
    
    # Ensure Homebrew-installed PostgreSQL client is on PATH for non-interactive shells
    if [ -x "/opt/homebrew/opt/postgresql@16/bin/psql" ] && ! command_exists psql; then
        export PATH="/opt/homebrew/opt/postgresql@16/bin:$PATH"
        log_info "Added /opt/homebrew/opt/postgresql@16/bin to PATH for psql"
    fi
    
    # Required dependencies (project-wide)
    check_dependency "python3" true "brew install python3" || missing_required=$((missing_required + 1))
    check_dependency "node" true "brew install node" || missing_required=$((missing_required + 1))
    check_dependency "docker" true "Install Docker Desktop from https://www.docker.com/products/docker-desktop" || missing_required=$((missing_required + 1))
    check_dependency "psql" true "brew install postgresql@16 or brew install libpq" || missing_required=$((missing_required + 1))
    check_dependency "aws" true "brew install awscli" || missing_required=$((missing_required + 1))
    check_dependency "terraform" true "brew install terraform" || missing_required=$((missing_required + 1))
    
    # Optional dependencies
    check_dependency "spark-submit" false "Download from https://spark.apache.org/downloads.html"
    
    if [ $missing_required -gt 0 ]; then
        log_error "Missing $missing_required required dependency(ies). Please install them and try again."
        return 1
    fi
    
    log_success "All required dependencies are installed"
    return 0
}

check_all_dependencies
