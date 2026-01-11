#!/bin/bash
# Check and install Docker
# Idempotent: checks if installed before installing

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../../../../.." && pwd)}"
source "$REPO_ROOT/run_scripts/shared/logger.sh"
source "$SCRIPT_DIR/../shared/detect-os.sh"
source "$SCRIPT_DIR/../shared/prompt-helpers.sh"

# Ensure command_exists is available
if ! type command_exists >/dev/null 2>&1; then
    command_exists() {
        command -v "$1" >/dev/null 2>&1
    }
fi

check_docker() {
    log_step "Checking Docker installation"
    
    # Check if docker exists
    if ! command_exists "docker"; then
        log_warning "docker command not found"
        return 1
    fi
    
    # Check if docker daemon is running (optional check, but useful)
    if ! docker info >/dev/null 2>&1; then
        log_warning "Docker is installed but daemon is not running"
        log_info "Please start Docker Desktop (macOS) or Docker service (Linux)"
        # Don't fail - user might start it manually
    fi
    
    local docker_version=$(docker --version 2>&1)
    log_success "Docker is installed: $docker_version"
    return 0
}

install_docker() {
    detect_os
    
    local install_method=""
    local install_cmd=""
    
    case "$OS" in
        macos)
            # Docker Desktop for Mac
            install_method="Docker Desktop for Mac (manual download required)"
            install_cmd="install_docker_macos"
            ;;
        ubuntu)
            install_method="apt repository: apt-get install docker.io"
            install_cmd="install_docker_ubuntu"
            ;;
        *)
            log_error "Unsupported OS: $OS"
            log_info "Please install Docker manually"
            log_info "Download from: https://www.docker.com/products/docker-desktop"
            return 1
            ;;
    esac
    
    # Prompt user (or auto-approve in non-interactive)
    if ! prompt_user "Docker" "$install_method"; then
        log_error "Installation declined by user"
        log_info "Please install Docker manually and try again"
        log_info "Download from: https://www.docker.com/products/docker-desktop"
        return 1
    fi
    
    # Proceed with installation
    log_info "Installing Docker..."
    
    case "$OS" in
        macos)
            install_docker_macos
            ;;
        ubuntu)
            install_docker_ubuntu
            ;;
    esac
    
    # Verify installation
    if ! check_docker; then
        log_error "Docker installation verification failed"
        log_info "Please check the installation manually"
        return 1
    fi
    
    log_success "Docker installed successfully"
    log_info "Note: You may need to start Docker Desktop (macOS) or Docker service (Linux)"
    return 0
}

install_docker_macos() {
    log_info "Docker Desktop for Mac must be installed manually"
    log_info "Opening Docker Desktop download page..."
    
    # Try to open download page
    if command_exists "open"; then
        open "https://www.docker.com/products/docker-desktop/"
    fi
    
    log_info "Please download and install Docker Desktop from the opened page"
    log_info "After installation, restart your terminal and run this script again"
    
    # Check if user installed it
    if is_interactive; then
        read -p "Press Enter after you have installed Docker Desktop: " response
    else
        log_error "Cannot install Docker Desktop automatically in non-interactive mode"
        log_error "Please install Docker Desktop manually"
        return 1
    fi
}

install_docker_ubuntu() {
    log_info "Installing Docker via apt repository..."
    
    # Remove old versions
    sudo apt-get remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true
    
    # Install prerequisites
    sudo apt-get update
    sudo apt-get install -y ca-certificates curl gnupg lsb-release
    
    # Add Docker GPG key
    sudo mkdir -p /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    
    # Add Docker repository
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
      $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    
    # Install Docker
    sudo apt-get update
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
    
    # Add current user to docker group (requires logout/login)
    log_info "Adding current user to docker group..."
    sudo usermod -aG docker "$USER"
    
    log_warning "Note: You may need to log out and log back in for docker group changes to take effect"
    log_info "Or run: newgrp docker"
}

main() {
    # Check if already installed
    if check_docker; then
        return 0
    fi
    
    # Install if missing
    if ! install_docker; then
        log_error "Docker installation failed"
        exit 1
    fi
}

main "$@"

