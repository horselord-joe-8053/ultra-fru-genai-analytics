#!/bin/bash
# Main AWS deployment orchestrator
# This script provides a menu to choose AWS deployment option
# Usage: ./run.sh [ecs|eks|terraform]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/../common/logger.sh"

show_menu() {
    echo ""
    log_info "AWS Deployment Options:"
    echo "  1) ECS Fargate Deployment"
    echo "  2) EKS (Kubernetes) Deployment"
    echo "  3) Terraform Infrastructure Deployment"
    echo "  4) Exit"
    echo ""
}

main() {
    log_step "AWS Deployment Menu"
    
    # Check AWS credentials first
    "$SCRIPT_DIR/check-aws-credentials.sh" || exit 1
    
    # If deployment type provided as argument, use it
    if [ $# -gt 0 ]; then
        case $1 in
            ecs)
                log_info "Starting ECS deployment..."
                "$SCRIPT_DIR/ecs/deploy.sh" "${@:2}"
                ;;
            eks)
                log_info "Starting EKS deployment..."
                "$SCRIPT_DIR/eks/deploy.sh" "${@:2}"
                ;;
            terraform)
                log_info "Starting Terraform deployment..."
                "$SCRIPT_DIR/terraform/deploy.sh" "${@:2}"
                ;;
            *)
                log_error "Unknown deployment type: $1"
                log_info "Usage: $0 [ecs|eks|terraform] [options...]"
                exit 1
                ;;
        esac
        return 0
    fi
    
    # Interactive menu
    while true; do
        show_menu
        read -p "Select an option (1-4): " choice
        
        case $choice in
            1)
                log_info "Starting ECS deployment..."
                "$SCRIPT_DIR/ecs/deploy.sh"
                break
                ;;
            2)
                log_info "Starting EKS deployment..."
                "$SCRIPT_DIR/eks/deploy.sh"
                break
                ;;
            3)
                log_info "Starting Terraform deployment..."
                "$SCRIPT_DIR/terraform/deploy.sh"
                break
                ;;
            4)
                log_info "Exiting..."
                exit 0
                ;;
            *)
                log_error "Invalid option. Please select 1-4."
                ;;
        esac
    done
}

main "$@"

