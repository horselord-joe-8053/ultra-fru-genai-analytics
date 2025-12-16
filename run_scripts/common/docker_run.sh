#!/bin/bash
# Idempotent Docker daemon startup script
# Works on both macOS and Linux
# Returns 0 if Docker is running (or successfully started), 1 on error

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/logger.sh"

# Check if Docker is already running
check_docker_running() {
    if docker info >/dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

# Start Docker on macOS (Docker Desktop)
start_docker_mac() {
    log_info "Starting Docker Desktop on macOS..."
    
    # Check if Docker Desktop app exists
    if [ ! -d "/Applications/Docker.app" ]; then
        log_error "Docker Desktop not found at /Applications/Docker.app"
        log_error "Please install Docker Desktop from https://www.docker.com/products/docker-desktop"
        return 1
    fi
    
    # Try to start Docker Desktop
    if open -a Docker >/dev/null 2>&1; then
        log_info "Docker Desktop launch command sent, waiting for daemon to start..."
    else
        log_error "Failed to start Docker Desktop"
        return 1
    fi
    
    # Wait for Docker daemon to be ready (max 60 seconds)
    local max_wait=60
    local elapsed=0
    while [ $elapsed -lt $max_wait ]; do
        if check_docker_running; then
            log_success "Docker daemon is running"
            return 0
        fi
        sleep 2
        elapsed=$((elapsed + 2))
        if [ $((elapsed % 10)) -eq 0 ]; then
            log_info "Still waiting for Docker daemon... (${elapsed}s elapsed)"
        fi
    done
    
    log_error "Docker daemon did not start within ${max_wait} seconds"
    log_error "Please start Docker Desktop manually and try again"
    return 1
}

# Start Docker on Linux
start_docker_linux() {
    log_info "Starting Docker daemon on Linux..."
    
    # Detect init system and start Docker service
    if command -v systemctl >/dev/null 2>&1; then
        # systemd
        if systemctl is-active --quiet docker; then
            log_success "Docker daemon is already running"
            return 0
        fi
        
        log_info "Starting Docker service via systemd..."
        if sudo systemctl start docker 2>/dev/null; then
            # Wait a moment for service to start
            sleep 2
            if check_docker_running; then
                log_success "Docker daemon is running"
                return 0
            else
                log_error "Docker service started but daemon is not responding"
                return 1
            fi
        else
            log_error "Failed to start Docker service (may need sudo privileges)"
            log_error "Try running: sudo systemctl start docker"
            return 1
        fi
    elif command -v service >/dev/null 2>&1; then
        # sysvinit/upstart
        log_info "Starting Docker service via service command..."
        if sudo service docker start 2>/dev/null; then
            sleep 2
            if check_docker_running; then
                log_success "Docker daemon is running"
                return 0
            else
                log_error "Docker service started but daemon is not responding"
                return 1
            fi
        else
            log_error "Failed to start Docker service (may need sudo privileges)"
            log_error "Try running: sudo service docker start"
            return 1
        fi
    else
        log_error "Cannot detect init system (systemctl or service not found)"
        log_error "Please start Docker manually and try again"
        return 1
    fi
}

# Main function
ensure_docker_running() {
    # Check if Docker is already running
    if check_docker_running; then
        log_info "Docker daemon is already running"
        return 0
    fi
    
    # Detect OS and start Docker accordingly
    local os_type
    case "$(uname -s)" in
        Darwin)
            os_type="mac"
            start_docker_mac
            ;;
        Linux)
            os_type="linux"
            start_docker_linux
            ;;
        *)
            log_error "Unsupported OS: $(uname -s)"
            log_error "Please start Docker manually and try again"
            return 1
            ;;
    esac
}

# Run if executed directly
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    ensure_docker_running
    exit $?
fi

