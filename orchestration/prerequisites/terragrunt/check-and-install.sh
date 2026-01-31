#!/bin/bash
# Check and install Terragrunt >= 0.50.0
# Idempotent: checks if installed with correct version before installing

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../../.." && pwd)}"
source "$REPO_ROOT/orchestration/common/logger.sh"
source "$SCRIPT_DIR/../common/detect-os.sh"
source "$SCRIPT_DIR/../common/prompt-helpers.sh"

# Ensure command_exists is available
if ! type command_exists >/dev/null 2>&1; then
    command_exists() {
        command -v "$1" >/dev/null 2>&1
    }
fi

MIN_TERRAGRUNT_VERSION="0.50.0"

check_terragrunt() {
    log_step "Checking Terragrunt installation"
    
    # Check if terragrunt exists
    if ! command_exists "terragrunt"; then
        log_warning "terragrunt command not found"
        return 1
    fi
    
    # Get Terragrunt version (format: terragrunt version v0.50.0)
    local terragrunt_version=$(terragrunt --version 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1)
    
    if [ -z "$terragrunt_version" ]; then
        log_warning "Could not determine Terragrunt version"
        return 1
    fi
    
    # Extract major and minor for comparison (e.g., 0.50 from 0.50.0)
    local major_minor=$(echo "$terragrunt_version" | cut -d. -f1,2)
    local min_major_minor=$(echo "$MIN_TERRAGRUNT_VERSION" | cut -d. -f1,2)
    
    # Check if version meets requirement
    if version_gte "$major_minor" "$min_major_minor"; then
        log_success "Terragrunt $terragrunt_version is installed (meets requirement >= $MIN_TERRAGRUNT_VERSION)"
        return 0
    else
        log_warning "Terragrunt $terragrunt_version is installed but version < $MIN_TERRAGRUNT_VERSION (required >= $MIN_TERRAGRUNT_VERSION)"
        return 1
    fi
}

install_terragrunt() {
    detect_os
    
    local install_method=""
    local install_cmd=""
    
    case "$OS" in
        macos)
            if [ "$PACKAGE_MANAGER" = "homebrew" ]; then
                install_method="Homebrew: brew install terragrunt"
                install_cmd="brew install terragrunt"
            else
                install_method="Manual download from github.com/gruntwork-io/terragrunt"
                install_cmd="install_terragrunt_manual"
            fi
            ;;
        ubuntu)
            install_method="Manual download from github.com/gruntwork-io/terragrunt"
            install_cmd="install_terragrunt_ubuntu"
            ;;
        *)
            install_method="Manual download from github.com/gruntwork-io/terragrunt"
            install_cmd="install_terragrunt_manual"
            ;;
    esac
    
    # Prompt user (or auto-approve in non-interactive)
    if ! prompt_user "Terragrunt >= $MIN_TERRAGRUNT_VERSION" "$install_method"; then
        log_error "Installation declined by user"
        log_info "Please install Terragrunt >= $MIN_TERRAGRUNT_VERSION manually and try again"
        log_info "Download from: https://github.com/gruntwork-io/terragrunt/releases"
        return 1
    fi
    
    # Proceed with installation
    log_info "Installing Terragrunt..."
    
    case "$OS" in
        macos)
            if [ "$PACKAGE_MANAGER" = "homebrew" ]; then
                if ! $install_cmd; then
                    log_error "Failed to install Terragrunt via Homebrew"
                    return 1
                fi
            else
                install_terragrunt_manual
            fi
            ;;
        ubuntu)
            install_terragrunt_ubuntu
            ;;
        *)
            install_terragrunt_manual
            ;;
    esac
    
    # Verify installation
    if ! check_terragrunt; then
        log_error "Terragrunt installation verification failed"
        log_info "Please check the installation manually"
        return 1
    fi
    
    log_success "Terragrunt installed successfully"
    return 0
}

install_terragrunt_ubuntu() {
    log_info "Installing Terragrunt via GitHub releases..."
    
    # Detect architecture
    local arch=$(uname -m)
    case "$arch" in
        x86_64)
            arch="amd64"
            ;;
        aarch64|arm64)
            arch="arm64"
            ;;
        *)
            log_error "Unsupported architecture: $arch"
            return 1
            ;;
    esac
    
    # Download latest Terragrunt
    local version="latest"  # Could pin to specific version
    local download_url="https://github.com/gruntwork-io/terragrunt/releases/${version}/download/terragrunt_linux_${arch}"
    local install_path="/usr/local/bin/terragrunt"
    
    log_info "Downloading Terragrunt from GitHub..."
    sudo curl -L -o "$install_path" "$download_url"
    sudo chmod +x "$install_path"
}

install_terragrunt_manual() {
    log_error "Manual Terragrunt installation not yet implemented"
    log_info "Please install Terragrunt manually:"
    log_info "  macOS: brew install terragrunt"
    log_info "  Linux: https://github.com/gruntwork-io/terragrunt/releases"
    return 1
}

main() {
    # Check if already installed
    if check_terragrunt; then
        return 0
    fi
    
    # Install if missing or version too old
    if ! install_terragrunt; then
        log_error "Terragrunt installation failed"
        exit 1
    fi
}

main "$@"

