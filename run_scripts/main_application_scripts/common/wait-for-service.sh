#!/bin/bash
# Wait for a service to be ready
# Usage: wait_for_service <url> <max_attempts> <delay_seconds>

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../../../" && pwd)}"
source "$REPO_ROOT/run_scripts/shared/logger.sh"

wait_for_service() {
    local url=$1
    local max_attempts=${2:-30}
    local delay=${3:-2}
    local attempt=1
    
    log_info "Waiting for service at $url to be ready..."
    
    while [ $attempt -le $max_attempts ]; do
        if curl -sf "$url" >/dev/null 2>&1; then
            log_success "Service is ready!"
            return 0
        fi
        
        log_info "Attempt $attempt/$max_attempts: Service not ready yet, waiting ${delay}s..."
        sleep $delay
        attempt=$((attempt + 1))
    done
    
    log_error "Service at $url did not become ready after $max_attempts attempts"
    return 1
}

wait_for_port() {
    local host=$1
    local port=$2
    local max_attempts=${3:-30}
    local delay=${4:-2}
    local attempt=1
    
    log_info "Waiting for port $port on $host to be open..."
    
    while [ $attempt -le $max_attempts ]; do
        if nc -z "$host" "$port" 2>/dev/null; then
            log_success "Port $port is open!"
            return 0
        fi
        
        log_info "Attempt $attempt/$max_attempts: Port not open yet, waiting ${delay}s..."
        sleep $delay
        attempt=$((attempt + 1))
    done
    
    log_error "Port $port on $host did not become open after $max_attempts attempts"
    return 1
}

