#!/bin/bash
# Check and install Terraform >= 1.5.0
# Idempotent: checks if installed with correct version before installing

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../../../../.." && pwd)}"
source "$REPO_ROOT/orchestration/shared/logger.sh"
source "$SCRIPT_DIR/../shared/detect-os.sh"
source "$SCRIPT_DIR/../shared/prompt-helpers.sh"

# Ensure command_exists is available
if ! type command_exists >/dev/null 2>&1; then
    command_exists() {
        command -v "$1" >/dev/null 2>&1
    }
fi

MIN_TERRAFORM_VERSION="1.5.0"

check_terraform() {
    log_step "Checking Terraform installation"
    
    # Check if terraform exists
    if ! command_exists "terraform"; then
        log_warning "terraform command not found"
        return 1
    fi
    
    # Get Terraform version (format: Terraform v1.5.0)
    local terraform_version=$(terraform --version 2>&1 | head -n1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
    
    if [ -z "$terraform_version" ]; then
        log_warning "Could not determine Terraform version"
        return 1
    fi
    
    # Extract major and minor for comparison (e.g., 1.5 from 1.5.0)
    local major_minor=$(echo "$terraform_version" | cut -d. -f1,2)
    local min_major_minor=$(echo "$MIN_TERRAFORM_VERSION" | cut -d. -f1,2)
    
    # Check if version meets requirement
    if version_gte "$major_minor" "$min_major_minor"; then
        log_success "Terraform $terraform_version is installed (meets requirement >= $MIN_TERRAFORM_VERSION)"
        return 0
    else
        log_warning "Terraform $terraform_version is installed but version < $MIN_TERRAFORM_VERSION (required >= $MIN_TERRAFORM_VERSION)"
        return 1
    fi
}

install_terraform() {
    detect_os
    
    local install_method=""
    local install_cmd=""
    
    case "$OS" in
        macos)
            if [ "$PACKAGE_MANAGER" = "homebrew" ]; then
                install_method="Homebrew: brew install terraform"
                install_cmd="brew install terraform"
            else
                install_method="Manual download from hashicorp.com"
                install_cmd="install_terraform_manual"
            fi
            ;;
        ubuntu)
            install_method="Hashicorp apt repository: apt-get install terraform"
            install_cmd="install_terraform_ubuntu"
            ;;
        *)
            install_method="Manual download from hashicorp.com"
            install_cmd="install_terraform_manual"
            ;;
    esac
    
    # Prompt user (or auto-approve in non-interactive)
    if ! prompt_user "Terraform >= $MIN_TERRAFORM_VERSION" "$install_method"; then
        log_error "Installation declined by user"
        log_info "Please install Terraform >= $MIN_TERRAFORM_VERSION manually and try again"
        log_info "Download from: https://www.terraform.io/downloads"
        return 1
    fi
    
    # Proceed with installation
    log_info "Installing Terraform..."
    
    case "$OS" in
        macos)
            if [ "$PACKAGE_MANAGER" = "homebrew" ]; then
                if ! $install_cmd; then
                    log_error "Failed to install Terraform via Homebrew"
                    return 1
                fi
            else
                install_terraform_manual
            fi
            ;;
        ubuntu)
            install_terraform_ubuntu
            ;;
        *)
            install_terraform_manual
            ;;
    esac
    
    # Verify installation
    if ! check_terraform; then
        log_error "Terraform installation verification failed"
        log_info "Please check the installation manually"
        return 1
    fi
    
    log_success "Terraform installed successfully"
    return 0
}

install_terraform_ubuntu() {
    log_info "Installing Terraform via Hashicorp repository..."
    
    # Install prerequisites
    sudo apt-get update
    sudo apt-get install -y ca-certificates curl gnupg lsb-release
    
    # Add Hashicorp GPG key
    wget -O- https://apt.releases.hashicorp.com/gpg | \
        sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
    
    # Add Hashicorp repository
    echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] \
        https://apt.releases.hashicorp.com $(lsb_release -cs) main" | \
        sudo tee /etc/apt/sources.list.d/hashicorp.list
    
    # Install Terraform
    sudo apt-get update
    sudo apt-get install -y terraform
}

install_terraform_manual() {
    log_error "Manual Terraform installation not yet implemented"
    log_info "Please install Terraform manually:"
    log_info "  macOS: brew install terraform"
    log_info "  Linux: https://learn.hashicorp.com/tutorials/terraform/install-cli"
    return 1
}

main() {
    # Check if already installed
    if check_terraform; then
        return 0
    fi
    
    # Install if missing or version too old
    if ! install_terraform; then
        log_error "Terraform installation failed"
        exit 1
    fi
}

main "$@"

