#!/bin/bash
# Teardown CloudFront distributions for a specific container type (ECS or EKS)
# before S3 bucket cleanup.
#
# SYNOPSIS:
#   ./teardown-cloudfront.sh <ENVIRONMENT> --container-type <ecs|eks> [OPTIONS]
#
# DESCRIPTION:
#   This helper is called by higher-level teardown scripts (e.g.
#   teardown-resources-nonshared.sh) to:
#     - Find CloudFront distributions for this project/environment/container-type
#       using the Name tag: fru-<env>-cloudfront-<ecs|eks>
#     - For each matching distribution, call the standalone
#       cloudfront-disable-and-delete.sh CLI to:
#         * Disable the distribution (Enabled=false)
#         * Wait for disable to complete
#         * Delete the distribution
#   This ensures CloudFront is removed before S3 buckets are cleaned up,
#   preventing deletion failures due to CloudFront origins.
#
# OPTIONS:
#   ENVIRONMENT          Environment name (dev, staging, prod) - positional arg
#   --container-type     Container type (ecs or eks) - REQUIRED
#   --dry-run            Show what would be done without making changes
#   --force, --skip-confirmation
#                        Currently ignored (included for symmetry with callers)
#   --help, -h           Show usage
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../../../../../.." && pwd)}"

source "$REPO_ROOT/run_scripts/shared/logger.sh"
source "$REPO_ROOT/run_scripts/shared/load-env.sh"

DRY_RUN="${DRY_RUN:-false}"
AWS_PROFILE="${AWS_PROFILE:-admin}"
AWS_REGION="${AWS_REGION:-us-east-1}"  # CloudFront is global, region mostly for logs
PROJECT_NAME="fru"

ENVIRONMENT="${1:-dev}"
shift || true

CONTAINER_TYPE=""

print_usage() {
  cat << EOF
Usage: $0 <ENVIRONMENT> --container-type <ecs|eks> [--dry-run]

Teardown CloudFront distributions for this project/environment/container-type.

This helper:
  - Discovers CloudFront distributions tagged with:
      Name = ${PROJECT_NAME}-<ENVIRONMENT>-cloudfront-<ecs|eks>
  - For each match, calls:
      run_scripts/main_application_scripts/aws/shared/cli/cloudfront-disable-and-delete.sh --cf-id <ID>

Examples:
  $0 dev --container-type ecs
  $0 dev --container-type eks --dry-run
EOF
}

# Parse options
while [[ $# -gt 0 ]]; do
  case "$1" in
    --container-type)
      CONTAINER_TYPE="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN="true"
      shift
      ;;
    --force|--skip-confirmation)
      # Accepted for symmetry; no interactive prompts here
      shift
      ;;
    --help|-h)
      print_usage
      exit 0
      ;;
    *)
      log_error "Unknown option: $1"
      print_usage
      exit 1
      ;;
  esac
done

# Validate environment
if [[ ! "$ENVIRONMENT" =~ ^(dev|staging|prod)$ ]]; then
  log_error "Invalid environment: $ENVIRONMENT"
  log_info "Must be: dev, staging, or prod"
  exit 1
fi

# Validate container type
if [ -z "$CONTAINER_TYPE" ]; then
  log_error "--container-type is required"
  print_usage
  exit 1
fi

if [ "$CONTAINER_TYPE" != "ecs" ] && [ "$CONTAINER_TYPE" != "eks" ]; then
  log_error "Invalid container type: $CONTAINER_TYPE"
  log_info "Must be 'ecs' or 'eks'"
  exit 1
fi

log_step "Substep 4.5: Teardown CloudFront Distributions"
log_info "Environment: $ENVIRONMENT"
log_info "Container Type: $CONTAINER_TYPE"
log_info "Profile: $AWS_PROFILE"
log_info "Region (for logs): $AWS_REGION"
if [ "$DRY_RUN" = "true" ]; then
  log_info "Mode: DRY-RUN (no CloudFront changes will be made)"
fi
echo ""

NAME_TAG_VALUE="${PROJECT_NAME}-${ENVIRONMENT}-cloudfront-${CONTAINER_TYPE}"

log_info "Searching for CloudFront distributions with tag:"
log_info "  Name = $NAME_TAG_VALUE"

# Use Resource Groups Tagging API to find CloudFront distributions by Name tag
dist_arns=$(aws resourcegroupstaggingapi get-resources \
  --profile "$AWS_PROFILE" \
  --resource-type-filters "cloudfront:distribution" \
  --tag-filters "Key=Name,Values=$NAME_TAG_VALUE" \
  --query 'ResourceTagMappingList[].ResourceARN' \
  --output text 2>/dev/null || echo "")

if [ -z "$dist_arns" ] || [ "$dist_arns" = "None" ]; then
  log_info "No CloudFront distributions found for tag Name=$NAME_TAG_VALUE"
  echo ""
  exit 0
fi

# Extract IDs from ARNs (arn:aws:cloudfront::ACCOUNT:distribution/ID)
dist_ids=""
for arn in $dist_arns; do
  id_part="${arn##*/}"
  if [ -n "$id_part" ]; then
    dist_ids+="$id_part "
  fi
done

if [ -z "$dist_ids" ]; then
  log_info "No valid CloudFront distribution IDs parsed from ARNs:"
  log_info "  $dist_arns"
  echo ""
  exit 0
fi

log_info "Found CloudFront distribution ID(s): $dist_ids"
echo ""

CLI_HELPER="$REPO_ROOT/run_scripts/main_application_scripts/aws/shared/cli/resource-removal/older/cloudfront-disable-and-delete.sh"

if [ ! -f "$CLI_HELPER" ]; then
  log_error "CloudFront disable/delete helper not found: $CLI_HELPER"
  log_info "Cannot proceed with CloudFront teardown; please ensure the helper exists."
  exit 1
fi

overall_failed="false"

for dist_id in $dist_ids; do
  log_info "Processing CloudFront distribution: $dist_id"

  cmd="$CLI_HELPER --cf-id $dist_id --profile $AWS_PROFILE"
  if [ "$DRY_RUN" = "true" ]; then
    cmd="$cmd --dry-run"
  fi

  log_info "Running: $cmd"

  if $cmd; then
    log_success "CloudFront distribution $dist_id teardown completed (disable + delete initiated)"
  else
    log_error "CloudFront distribution $dist_id teardown encountered errors"
    overall_failed="true"
  fi

  echo ""
done

if [ "$overall_failed" = "true" ]; then
  log_error "One or more CloudFront distributions had issues during teardown."
  exit 1
fi

log_success "CloudFront teardown completed for tag Name=$NAME_TAG_VALUE"
echo ""
