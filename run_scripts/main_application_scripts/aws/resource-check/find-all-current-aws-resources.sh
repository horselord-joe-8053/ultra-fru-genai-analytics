#!/bin/bash
# Find all non-default, non-system AWS resources in the account
# Usage: ./find-all-current-aws-resources.sh [--profile PROFILE] [--region REGION] [--all-regions]
#
# This script provides a comprehensive inventory of all AWS resources in your account,
# excluding default and system-managed resources (where applicable).
#
# Options:
#   --profile PROFILE    AWS profile to use (default: admin)
#   --region REGION      AWS region to check (default: us-east-1, use --all-regions for all regions)
#   --all-regions        Check all regions (default: false)
#   --help, -h           Display this help message

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../../../../" && pwd)}"
source "$REPO_ROOT/run_scripts/shared/logger.sh"
source "$REPO_ROOT/run_scripts/shared/load-env.sh"

AWS_PROFILE="${AWS_PROFILE:-admin}"
AWS_REGION="${AWS_REGION:-us-east-1}"
CHECK_ALL_REGIONS=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --profile)
            AWS_PROFILE="$2"
            shift 2
            ;;
        --region)
            AWS_REGION="$2"
            shift 2
            ;;
        --all-regions)
            CHECK_ALL_REGIONS=true
            shift
            ;;
        --help|-h)
            cat << EOF
Usage: $0 [--profile PROFILE] [--region REGION] [--all-regions]

Find all non-default, non-system AWS resources in your account.

Options:
  --profile PROFILE    AWS profile to use (default: admin)
  --region REGION      AWS region to check (default: us-east-1)
  --all-regions        Check all regions (default: false)
  --help, -h           Display this help message

Examples:
  $0                                    # List resources in us-east-1 with default profile
  $0 --profile admin --region us-east-1 # List resources in us-east-1 with admin profile
  $0 --all-regions                       # List resources in all regions

This script generates a JSON file in the results/ directory with the format:
  aws-fru-YYMMDD_HHMMSS-result.json

EOF
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            log_info "Use --help for usage information"
            exit 1
            ;;
    esac
done

# Get AWS account ID (using centralized resolution)
if [ -z "${AWS_ACCOUNT_ID:-}" ]; then
    source "$REPO_ROOT/run_scripts/shared/load-image-identifiers.sh"
    load_image_identifiers "aws" || exit 1
fi
# Use AWS_ACCOUNT_ID directly (no need for separate ACCOUNT_ID variable)

log_step "AWS Resource Inventory"
log_info "Account ID: $AWS_ACCOUNT_ID"
log_info "Profile: $AWS_PROFILE"
if [ "$CHECK_ALL_REGIONS" = "true" ]; then
    log_info "Regions: ALL"
else
    log_info "Region: $AWS_REGION"
fi
echo ""

# Run Python script
PYTHON_SCRIPT="$SCRIPT_DIR/find-all-current-aws-resources.py"

if [ ! -f "$PYTHON_SCRIPT" ]; then
    log_error "Python script not found: $PYTHON_SCRIPT"
    exit 1
fi

# Build Python command
PYTHON_CMD="python3 \"$PYTHON_SCRIPT\" --profile \"$AWS_PROFILE\" --region \"$AWS_REGION\""
if [ "$CHECK_ALL_REGIONS" = "true" ]; then
    PYTHON_CMD="$PYTHON_CMD --all-regions"
fi

# Execute Python script
eval "$PYTHON_CMD"

# Get the generated file to display summary
RESULTS_DIR="$SCRIPT_DIR/results"
LATEST_FILE=$(ls -t "$RESULTS_DIR"/aws-fru-*.json 2>/dev/null | head -1)

if [ -n "$LATEST_FILE" ] && [ -f "$LATEST_FILE" ]; then
    echo ""
    log_step "Summary"
    TOTAL_RESOURCES=$(python3 -c "import json; data = json.load(open('$LATEST_FILE')); print(data['metadata']['total_resources'])" 2>/dev/null || echo "unknown")
    log_info "Total resources found: $TOTAL_RESOURCES"
    log_info "Account ID: $AWS_ACCOUNT_ID"
    log_info "Profile: $AWS_PROFILE"
    log_info "JSON file: $LATEST_FILE"
fi
