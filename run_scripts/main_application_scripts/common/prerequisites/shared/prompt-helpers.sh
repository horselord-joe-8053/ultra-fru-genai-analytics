#!/bin/bash
# Helper functions for user prompts and installation confirmation

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../../../../.." && pwd)}"
source "$REPO_ROOT/orchestration/shared/logger.sh"
source "$SCRIPT_DIR/detect-os.sh"

# Prompt user for installation confirmation
prompt_user() {
    local tool_name=$1
    local install_method=$2
    
    if is_interactive; then
        echo ""
        log_info "$tool_name is required but not installed."
        log_info "This will install via: $install_method"
        echo ""
        read -p "Would you like to proceed? [Y/n]: " response
        
        case "$response" in
            [yY]|""|"yes")
                return 0  # User approved
                ;;
            [nN]|"no")
                return 1  # User declined
                ;;
            *)
                log_warning "Invalid response. Assuming 'no'."
                return 1
                ;;
        esac
    else
        # Non-interactive: auto-approve
        log_info "Non-interactive mode: auto-installing $tool_name"
        return 0
    fi
}

