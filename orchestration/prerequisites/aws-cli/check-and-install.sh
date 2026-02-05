#!/bin/bash
# Check and install AWS CLI 2.x
# Idempotent: checks if installed with correct version before installing

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../../.." && pwd)}"
source "$REPO_ROOT/lib/logger.sh"
source "$SCRIPT_DIR/../common/detect-os.sh"
source "$SCRIPT_DIR/../common/prompt-helpers.sh"

# Ensure command_exists is available
if ! type command_exists >/dev/null 2>&1; then
    command_exists() {
        command -v "$1" >/dev/null 2>&1
    }
fi

MIN_AWS_CLI_VERSION="2.0"

check_aws_cli() {
    log_step "Checking AWS CLI installation"
    
    # Check if aws exists
    if ! command_exists "aws"; then
        log_warning "aws command not found"
        return 1
    fi
    
    # Get AWS CLI version (format: aws-cli/2.15.0)
    local aws_version=$(aws --version 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1)
    
    if [ -z "$aws_version" ]; then
        log_warning "Could not determine AWS CLI version"
        return 1
    fi
    
    # Extract major version (e.g., 2 from 2.15.0)
    local major_version=$(echo "$aws_version" | cut -d. -f1)
    
    # Check if version meets requirement (AWS CLI 2.x)
    if [ "$major_version" -ge 2 ]; then
        log_success "AWS CLI $aws_version is installed (meets requirement >= 2.x)"
        return 0
    else
        log_warning "AWS CLI $aws_version is installed but version < 2.x (required >= 2.0)"
        return 1
    fi
}

install_aws_cli() {
    detect_os
    
    local install_method=""
    local install_cmd=""
    
    case "$OS" in
        macos)
            if [ "$PACKAGE_MANAGER" = "homebrew" ]; then
                install_method="Homebrew: brew install awscli"
                install_cmd="brew install awscli"
            else
                install_method="Official AWS installer"
                install_cmd="install_aws_cli_macos_manual"
            fi
            ;;
        ubuntu)
            install_method="Official AWS installer"
            install_cmd="install_aws_cli_ubuntu"
            ;;
        *)
            install_method="Official AWS installer"
            install_cmd="install_aws_cli_manual"
            ;;
    esac
    
    # Prompt user (or auto-approve in non-interactive)
    if ! prompt_user "AWS CLI >= 2.x" "$install_method"; then
        log_error "Installation declined by user"
        log_info "Please install AWS CLI >= 2.x manually and try again"
        log_info "Download from: https://aws.amazon.com/cli/"
        return 1
    fi
    
    # Proceed with installation
    log_info "Installing AWS CLI 2.x..."
    
    case "$OS" in
        macos)
            if [ "$PACKAGE_MANAGER" = "homebrew" ]; then
                if ! $install_cmd; then
                    log_error "Failed to install AWS CLI via Homebrew"
                    return 1
                fi
            else
                install_aws_cli_macos_manual
            fi
            ;;
        ubuntu)
            install_aws_cli_ubuntu
            ;;
        *)
            install_aws_cli_manual
            ;;
    esac
    
    # Verify installation
    if ! check_aws_cli; then
        log_error "AWS CLI installation verification failed"
        log_info "Please check the installation manually"
        return 1
    fi
    
    log_success "AWS CLI installed successfully"
    return 0
}

install_aws_cli_ubuntu() {
    log_info "Installing AWS CLI via official installer..."
    
    # Detect architecture
    local arch=$(uname -m)
    case "$arch" in
        x86_64)
            arch="x86_64"
            ;;
        aarch64|arm64)
            arch="aarch64"
            ;;
        *)
            log_error "Unsupported architecture: $arch"
            return 1
            ;;
    esac
    
    # Download AWS CLI installer
    local download_url="https://awscli.amazonaws.com/awscli-exe-linux-${arch}.zip"
    local temp_dir=$(mktemp -d)
    local zip_file="${temp_dir}/awscliv2.zip"
    
    log_info "Downloading AWS CLI installer..."
    curl -o "$zip_file" "$download_url"
    
    # Unzip and install
    log_info "Extracting AWS CLI installer..."
    unzip -q "$zip_file" -d "$temp_dir"
    
    log_info "Installing AWS CLI..."
    sudo "$temp_dir/aws/install"
    
    # Cleanup
    rm -rf "$temp_dir"
}

install_aws_cli_macos_manual() {
    log_info "Installing AWS CLI via official installer..."
    
    # Detect architecture
    local arch=$(uname -m)
    case "$arch" in
        x86_64)
            arch="x86_64"
            ;;
        arm64)
            arch="arm64"
            ;;
        *)
            log_error "Unsupported architecture: $arch"
            return 1
            ;;
    esac
    
    # Download AWS CLI installer
    local download_url="https://awscli.amazonaws.com/AWSCLIV2.pkg"
    local pkg_file="/tmp/AWSCLIV2.pkg"
    
    log_info "Downloading AWS CLI installer..."
    curl -o "$pkg_file" "$download_url"
    
    log_info "Installing AWS CLI (requires sudo)..."
    sudo installer -pkg "$pkg_file" -target /
    
    # Cleanup
    rm -f "$pkg_file"
}

install_aws_cli_manual() {
    log_error "Manual AWS CLI installation not yet implemented"
    log_info "Please install AWS CLI manually:"
    log_info "  macOS: brew install awscli"
    log_info "  Linux: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
    return 1
}

main() {
    # Check if already installed
    if check_aws_cli; then
        return 0
    fi
    
    # Install if missing or version too old
    if ! install_aws_cli; then
        log_error "AWS CLI installation failed"
        exit 1
    fi
}

main "$@"

