#!/bin/bash
# Main orchestrator for prerequisite checking and installation
# Usage: ./check-and-install.sh [workflow]
#   workflow: "local" or "aws" (determines which prerequisites to install)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREREQUISITES_DIR="$SCRIPT_DIR"  # Save the prerequisites directory
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../../../.." && pwd)}"
source "$REPO_ROOT/run_scripts/shared/logger.sh"
source "$SCRIPT_DIR/shared/detect-os.sh"

WORKFLOW="${1:-local}"  # Default to "local" if not specified

# Restore SCRIPT_DIR after sourcing detect-os.sh (which sets its own SCRIPT_DIR)
SCRIPT_DIR="$PREREQUISITES_DIR"

# Detect OS at startup
detect_os

check_prerequisites() {
    log_step "Checking and installing prerequisites for workflow: $WORKFLOW"
    log_info "Operating System: $OS"
    log_info "Package Manager: $PACKAGE_MANAGER"
    echo ""
    
    local failed=0
    
    case "$WORKFLOW" in
        local)
            log_info "Local development prerequisites: Python, Node.js, Docker"
            echo ""
            
            # Python
            if ! "$PREREQUISITES_DIR/python/check-and-install.sh"; then
                log_error "Python prerequisite failed"
                failed=$((failed + 1))
            fi
            echo ""
            
            # Node.js
            if ! "$PREREQUISITES_DIR/nodejs/check-and-install.sh"; then
                log_error "Node.js prerequisite failed"
                failed=$((failed + 1))
            fi
            echo ""
            
            # Docker
            if ! "$PREREQUISITES_DIR/docker/check-and-install.sh"; then
                log_error "Docker prerequisite failed"
                failed=$((failed + 1))
            fi
            ;;
            
        aws)
            log_info "AWS deployment prerequisites: Python, AWS CLI, Terraform, Terragrunt, Docker"
            echo ""
            
            # Python
            if ! "$PREREQUISITES_DIR/python/check-and-install.sh"; then
                log_error "Python prerequisite failed"
                failed=$((failed + 1))
            fi
            echo ""
            
            # AWS CLI
            if ! "$PREREQUISITES_DIR/aws-cli/check-and-install.sh"; then
                log_error "AWS CLI prerequisite failed"
                failed=$((failed + 1))
            fi
            echo ""
            
            # Terraform
            if ! "$PREREQUISITES_DIR/terraform/check-and-install.sh"; then
                log_error "Terraform prerequisite failed"
                failed=$((failed + 1))
            fi
            echo ""
            
            # Terragrunt
            if ! "$PREREQUISITES_DIR/terragrunt/check-and-install.sh"; then
                log_error "Terragrunt prerequisite failed"
                failed=$((failed + 1))
            fi
            echo ""
            
            # Docker (for building images)
            if ! "$PREREQUISITES_DIR/docker/check-and-install.sh"; then
                log_error "Docker prerequisite failed"
                failed=$((failed + 1))
            fi
            ;;
            
        *)
            log_error "Unknown workflow: $WORKFLOW"
            log_info "Valid workflows: local, aws"
            exit 1
            ;;
    esac
    
    echo ""
    if [ $failed -gt 0 ]; then
        log_error "$failed prerequisite(s) failed"
        return 1
    else
        log_success "All prerequisites installed and verified"
        return 0
    fi
}

main() {
    check_prerequisites
}

main "$@"

