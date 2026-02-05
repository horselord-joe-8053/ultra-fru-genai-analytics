#!/bin/bash
# Check and install Python 3.10+
# Idempotent: checks if installed with correct version before installing

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../../.." && pwd)}"
source "$REPO_ROOT/lib/logger.sh"
source "$SCRIPT_DIR/../common/detect-os.sh"
source "$SCRIPT_DIR/../common/prompt-helpers.sh"

MIN_PYTHON_VERSION="3.10"
PYTHON_VERSION="3.11"  # Version to install if missing

check_python() {
    log_step "Checking Python installation"
    
    # Check if python3 exists
    if ! command_exists "python3"; then
        log_warning "python3 command not found"
        return 1
    fi
    
    # Get Python version
    local python_version=$(python3 --version 2>&1 | grep -oE '[0-9]+\.[0-9]+')
    
    if [ -z "$python_version" ]; then
        log_warning "Could not determine Python version"
        return 1
    fi
    
    # Check if version meets requirement
    if version_gte "$python_version" "$MIN_PYTHON_VERSION"; then
        log_success "Python $python_version is installed (meets requirement >= $MIN_PYTHON_VERSION)"
        return 0
    else
        log_warning "Python $python_version is installed but version < $MIN_PYTHON_VERSION (required >= $MIN_PYTHON_VERSION)"
        return 1
    fi
}

install_python() {
    detect_os
    
    local install_method=""
    local install_cmd=""
    
    case "$OS" in
        macos)
            if [ "$PACKAGE_MANAGER" = "homebrew" ]; then
                install_method="Homebrew: brew install python@$PYTHON_VERSION"
                install_cmd="brew install python@$PYTHON_VERSION"
            else
                log_error "Homebrew not found. Please install Homebrew from https://brew.sh"
                log_info "Or install Python manually: https://www.python.org/downloads/"
                return 1
            fi
            ;;
        ubuntu)
            # Use deadsnakes PPA for newer Python versions
            install_method="apt with deadsnakes PPA: apt-get install python$PYTHON_VERSION"
            install_cmd="install_python_ubuntu"
            ;;
        *)
            log_error "Unsupported OS: $OS"
            log_info "Please install Python $MIN_PYTHON_VERSION+ manually"
            log_info "Download from: https://www.python.org/downloads/"
            return 1
            ;;
    esac
    
    # Prompt user (or auto-approve in non-interactive)
    if ! prompt_user "Python $MIN_PYTHON_VERSION+" "$install_method"; then
        log_error "Installation declined by user"
        log_info "Please install Python $MIN_PYTHON_VERSION+ manually and try again"
        return 1
    fi
    
    # Proceed with installation
    log_info "Installing Python $PYTHON_VERSION..."
    
    case "$OS" in
        macos)
            if ! $install_cmd; then
                log_error "Failed to install Python via Homebrew"
                return 1
            fi
            ;;
        ubuntu)
            install_python_ubuntu
            ;;
    esac
    
    # Verify installation
    if ! check_python; then
        log_error "Python installation verification failed"
        log_info "Please check the installation manually"
        return 1
    fi
    
    log_success "Python installed successfully"
    return 0
}

install_python_ubuntu() {
    log_info "Adding deadsnakes PPA for Python $PYTHON_VERSION..."
    
    # Install prerequisites
    sudo apt-get update
    sudo apt-get install -y software-properties-common
    
    # Add deadsnakes PPA
    sudo add-apt-repository -y ppa:deadsnakes/ppa
    
    # Update package list
    sudo apt-get update
    
    # Install Python and required packages
    sudo apt-get install -y "python$PYTHON_VERSION" "python$PYTHON_VERSION-venv" "python$PYTHON_VERSION-pip"
    
    # Create symlink if python3 doesn't point to the new version
    if ! command_exists "python3" || ! python3 --version | grep -q "Python $PYTHON_VERSION"; then
        log_info "Creating python3 symlink to python$PYTHON_VERSION"
        sudo update-alternatives --install /usr/bin/python3 python3 "/usr/bin/python$PYTHON_VERSION" 1
    fi
}

main() {
    # Check if already installed
    if check_python; then
        return 0
    fi
    
    # Install if missing or version too old
    if ! install_python; then
        log_error "Python installation failed"
        exit 1
    fi
}

main "$@"

