#!/bin/bash
# Check and install Node.js 18+
# Idempotent: checks if installed with correct version before installing

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../../../../.." && pwd)}"
source "$REPO_ROOT/orchestration/shared/logger.sh"
source "$SCRIPT_DIR/../shared/detect-os.sh"
source "$SCRIPT_DIR/../shared/prompt-helpers.sh"

MIN_NODE_VERSION="18.0"
NODE_VERSION="18"  # LTS version

# Ensure command_exists is available (from detect-os.sh)
if ! type command_exists >/dev/null 2>&1; then
    command_exists() {
        command -v "$1" >/dev/null 2>&1
    }
fi

check_nodejs() {
    log_step "Checking Node.js installation"
    
    # Check if node exists
    if ! command_exists "node"; then
        log_warning "node command not found"
        return 1
    fi
    
    # Get Node.js version
    local node_version=$(node --version 2>&1 | sed 's/v//' | grep -oE '[0-9]+\.[0-9]+')
    
    if [ -z "$node_version" ]; then
        log_warning "Could not determine Node.js version"
        return 1
    fi
    
    # Check if version meets requirement
    if version_gte "$node_version" "$MIN_NODE_VERSION"; then
        log_success "Node.js v$node_version is installed (meets requirement >= v$MIN_NODE_VERSION)"
        
        # Also check npm
        if command_exists "npm"; then
            local npm_version=$(npm --version)
            log_success "npm v$npm_version is installed"
        else
            log_warning "npm not found (usually comes with Node.js)"
        fi
        
        return 0
    else
        log_warning "Node.js v$node_version is installed but version < v$MIN_NODE_VERSION (required >= v$MIN_NODE_VERSION)"
        return 1
    fi
}

install_nodejs() {
    detect_os
    
    local install_method=""
    local install_cmd=""
    
    case "$OS" in
        macos)
            if [ "$PACKAGE_MANAGER" = "homebrew" ]; then
                install_method="Homebrew: brew install node@$NODE_VERSION"
                install_cmd="brew install node@$NODE_VERSION"
            else
                log_error "Homebrew not found. Please install Homebrew from https://brew.sh"
                log_info "Or install Node.js manually: https://nodejs.org/"
                return 1
            fi
            ;;
        ubuntu)
            # Use NodeSource repository for latest LTS
            install_method="NodeSource repository: apt-get install nodejs"
            install_cmd="install_nodejs_ubuntu"
            ;;
        *)
            log_error "Unsupported OS: $OS"
            log_info "Please install Node.js $MIN_NODE_VERSION+ manually"
            log_info "Download from: https://nodejs.org/"
            return 1
            ;;
    esac
    
    # Prompt user (or auto-approve in non-interactive)
    if ! prompt_user "Node.js $MIN_NODE_VERSION+" "$install_method"; then
        log_error "Installation declined by user"
        log_info "Please install Node.js $MIN_NODE_VERSION+ manually and try again"
        return 1
    fi
    
    # Proceed with installation
    log_info "Installing Node.js $NODE_VERSION LTS..."
    
    case "$OS" in
        macos)
            if ! $install_cmd; then
                log_error "Failed to install Node.js via Homebrew"
                return 1
            fi
            ;;
        ubuntu)
            install_nodejs_ubuntu
            ;;
    esac
    
    # Verify installation
    if ! check_nodejs; then
        log_error "Node.js installation verification failed"
        log_info "Please check the installation manually"
        return 1
    fi
    
    log_success "Node.js installed successfully"
    return 0
}

install_nodejs_ubuntu() {
    log_info "Installing Node.js via NodeSource repository..."
    
    # Install prerequisites
    sudo apt-get update
    sudo apt-get install -y ca-certificates curl gnupg
    
    # Add NodeSource GPG key
    sudo mkdir -p /etc/apt/keyrings
    curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | sudo gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg
    
    # Add NodeSource repository for Node.js 18 LTS
    NODE_MAJOR=18
    echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${NODE_MAJOR}.x nodistro main" | sudo tee /etc/apt/sources.list.d/nodesource.list
    
    # Update and install
    sudo apt-get update
    sudo apt-get install -y nodejs
    
    # Verify npm is installed (should come with Node.js)
    if ! command_exists "npm"; then
        log_warning "npm not found after Node.js installation"
        sudo apt-get install -y npm
    fi
}

main() {
    # Check if already installed
    if check_nodejs; then
        return 0
    fi
    
    # Install if missing or version too old
    if ! install_nodejs; then
        log_error "Node.js installation failed"
        exit 1
    fi
}

main "$@"

