#!/bin/bash
# OS detection and package manager utilities
# Detects operating system (macOS/Ubuntu) and available package managers

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../../../../.." && pwd)}"

# Global variables (set by detect_os)
OS=""
PACKAGE_MANAGER=""
INSTALL_CMD=""
UPDATE_CMD=""

# Detect operating system
detect_os() {
    case "$(uname -s)" in
        Darwin*)
            OS="macos"
            if command_exists "brew"; then
                PACKAGE_MANAGER="homebrew"
                INSTALL_CMD="brew install"
                UPDATE_CMD="brew update"
            else
                PACKAGE_MANAGER="none"
                INSTALL_CMD=""
                UPDATE_CMD=""
            fi
            ;;
        Linux*)
            # Check if Ubuntu/Debian
            if [ -f /etc/os-release ]; then
                . /etc/os-release
                if [ "$ID" = "ubuntu" ] || [ "$ID" = "debian" ]; then
                    OS="ubuntu"
                    PACKAGE_MANAGER="apt"
                    INSTALL_CMD="sudo apt-get install -y"
                    UPDATE_CMD="sudo apt-get update"
                else
                    OS="linux"
                    PACKAGE_MANAGER="unknown"
                    INSTALL_CMD=""
                    UPDATE_CMD=""
                fi
            else
                OS="linux"
                PACKAGE_MANAGER="unknown"
                INSTALL_CMD=""
                UPDATE_CMD=""
            fi
            ;;
        *)
            OS="unknown"
            PACKAGE_MANAGER="unknown"
            INSTALL_CMD=""
            UPDATE_CMD=""
            ;;
    esac
}

# Check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Check if interactive terminal
is_interactive() {
    if [ -t 0 ] && [ "${CI:-false}" != "true" ] && [ "${NONINTERACTIVE:-false}" != "true" ]; then
        return 0  # Interactive
    else
        return 1  # Non-interactive
    fi
}

# Compare version numbers (returns 0 if version1 >= version2)
version_gte() {
    local version1=$1
    local version2=$2
    
    # Extract major and minor versions
    local v1_major=$(echo "$version1" | cut -d. -f1)
    local v1_minor=$(echo "$version1" | cut -d. -f2)
    local v2_major=$(echo "$version2" | cut -d. -f1)
    local v2_minor=$(echo "$version2" | cut -d. -f2)
    
    if [ "$v1_major" -gt "$v2_major" ]; then
        return 0
    elif [ "$v1_major" -eq "$v2_major" ] && [ "$v1_minor" -ge "$v2_minor" ]; then
        return 0
    else
        return 1
    fi
}

# command_exists function is defined above and available to sourcing scripts
# No need to export as scripts source this file directly

