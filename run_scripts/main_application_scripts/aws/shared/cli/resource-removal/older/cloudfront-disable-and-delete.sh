#!/bin/bash
# One-time utility: disable and delete a specific CloudFront distribution by ID.
#
# This is intended for legacy/stray distributions whose tags or naming do not
# match the current Terraform module conventions (e.g. old ECS distributions
# with Name = fru-dev-cloudfront instead of fru-dev-cloudfront-ecs).
#
# Usage:
#   ./cloudfront-disable-and-delete.sh --cf-id <CLOUDFRONT_DISTRIBUTION_ID> [--profile <aws-profile>] [--region <aws-region>] [--dry-run]
#
# Example:
#   ./cloudfront-disable-and-delete.sh --cf-id E1WE0B8OOEG12D --profile admin
#
# Steps:
#   1. Fetch current DistributionConfig and ETag
#   2. Update DistributionConfig.Enabled = false (disable)
#   3. Wait until CloudFront reports Enabled=false and Status=Deployed
#   4. Fetch fresh ETag
#   5. Delete the distribution
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../../../../../.." && pwd)}"
source "$REPO_ROOT/run_scripts/shared/logger.sh"
source "$REPO_ROOT/run_scripts/shared/load-env.sh"

CF_ID=""
AWS_PROFILE="${AWS_PROFILE:-admin}"
AWS_REGION="${AWS_REGION:-us-east-1}"
DRY_RUN="false"

print_usage() {
  cat << EOF
Usage: $0 --cf-id <CLOUDFRONT_DISTRIBUTION_ID> [--profile <aws-profile>] [--region <aws-region>] [--dry-run]

Disable and delete a specific CloudFront distribution by ID.

Options:
  --cf-id       CloudFront distribution ID (required)
  --profile     AWS CLI profile (default: ${AWS_PROFILE})
  --region      AWS region for CloudFront API (default: ${AWS_REGION})
  --dry-run     Show what would be done without making changes
  -h, --help    Show this help message

Example:
  $0 --cf-id E1WE0B8OOEG12D --profile admin
EOF
}

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --cf-id)
      CF_ID="$2"
      shift 2
      ;;
    --profile)
      AWS_PROFILE="$2"
      shift 2
      ;;
    --region)
      AWS_REGION="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN="true"
      shift
      ;;
    -h|--help)
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

if [ -z "$CF_ID" ]; then
  log_error "--cf-id is required"
  print_usage
  exit 1
fi

log_step "CloudFront Disable & Delete (one-off utility)"
log_info "CloudFront Distribution ID: $CF_ID"
log_info "Profile: $AWS_PROFILE"
log_info "Region: $AWS_REGION"
if [ "$DRY_RUN" = "true" ]; then
  log_info "Mode: DRY-RUN (no changes will be made)"
fi
echo ""

if [ "$DRY_RUN" = "true" ]; then
  log_info "[DRY-RUN] Would fetch current DistributionConfig and ETag for $CF_ID"
  log_info "[DRY-RUN] Would update DistributionConfig.Enabled = false"
  log_info "[DRY-RUN] Would wait until Enabled=false and Status=Deployed"
  log_info "[DRY-RUN] Would delete distribution $CF_ID"
  exit 0
fi

# Step 1: Fetch current DistributionConfig and ETag
log_info "Fetching current DistributionConfig and ETag..."
DIST_CONFIG_JSON="$(aws cloudfront get-distribution-config \
  --id "$CF_ID" \
  --profile "$AWS_PROFILE" \
  --output json 2>/dev/null || echo "")"

if [ -z "$DIST_CONFIG_JSON" ]; then
  log_error "Failed to fetch distribution config for ID: $CF_ID"
  log_info "Ensure the distribution ID is correct and you have permissions."
  exit 1
fi

ETAG="$(printf '%s\n' "$DIST_CONFIG_JSON" | jq -r '.ETag' 2>/dev/null || echo "")"
if [ -z "$ETAG" ] || [ "$ETAG" = "null" ]; then
  # Fallback: explicit ETag query
  ETAG="$(aws cloudfront get-distribution-config \
    --id "$CF_ID" \
    --profile "$AWS_PROFILE" \
    --query 'ETag' \
    --output text 2>/dev/null || echo "")"
fi

if [ -z "$ETAG" ] || [ "$ETAG" = "None" ]; then
  log_error "Could not determine ETag for distribution $CF_ID"
  exit 1
fi

DIST_CONFIG_ONLY="$(printf '%s\n' "$DIST_CONFIG_JSON" | jq '.DistributionConfig' 2>/dev/null || echo "")"
if [ -z "$DIST_CONFIG_ONLY" ] || [ "$DIST_CONFIG_ONLY" = "null" ]; then
  log_error "Failed to extract DistributionConfig for $CF_ID"
  exit 1
fi

CURRENT_ENABLED="$(printf '%s\n' "$DIST_CONFIG_ONLY" | jq -r '.Enabled' 2>/dev/null || echo "true")"
log_info "Current Enabled flag: $CURRENT_ENABLED"

if [ "$CURRENT_ENABLED" = "false" ]; then
  log_info "Distribution is already disabled; will proceed to deletion step after short status check."
else
  # Step 2: Disable distribution (set Enabled=false)
  log_info "Disabling distribution (Enabled=false)..."
  TMP_CONFIG="$(mktemp)"
  printf '%s\n' "$DIST_CONFIG_ONLY" | jq '.Enabled = false' > "$TMP_CONFIG"

  if aws cloudfront update-distribution \
    --id "$CF_ID" \
    --if-match "$ETAG" \
    --distribution-config "file://$TMP_CONFIG" \
    --profile "$AWS_PROFILE" >/dev/null 2>&1; then
    log_success "Disable request submitted successfully"
  else
    log_error "Failed to submit disable request for $CF_ID"
    rm -f "$TMP_CONFIG"
    exit 1
  fi
  rm -f "$TMP_CONFIG"
fi

# Step 3: Wait until CloudFront reports Enabled=false and Status=Deployed
log_info "Waiting for distribution to become disabled and deployed (this may take several minutes)..."
MAX_WAIT=180   # 180 * 10s = 30 minutes
attempt=0

while [ $attempt -lt $MAX_WAIT ]; do
  ENABLED_STATUS="$(aws cloudfront get-distribution-config \
    --id "$CF_ID" \
    --profile "$AWS_PROFILE" \
    --query 'DistributionConfig.Enabled' \
    --output text 2>/dev/null || echo "true")"

  DIST_STATUS="$(aws cloudfront get-distribution \
    --id "$CF_ID" \
    --profile "$AWS_PROFILE" \
    --query 'Distribution.Status' \
    --output text 2>/dev/null || echo "not-found")"

  if [ "$DIST_STATUS" = "not-found" ] || [ "$DIST_STATUS" = "None" ]; then
    log_info "Distribution $CF_ID no longer exists (already deleted)"
    exit 0
  fi

  if [ "$ENABLED_STATUS" = "False" ] && [ "$DIST_STATUS" = "Deployed" ]; then
    log_success "Distribution is now disabled (Enabled=false, Status=Deployed)"
    break
  fi

  attempt=$((attempt + 1))
  if [ $((attempt % 6)) -eq 0 ]; then
    minutes=$((attempt / 6))
    log_info "  Still waiting... (${minutes} minute(s) elapsed, Enabled=${ENABLED_STATUS}, Status=${DIST_STATUS})"
  fi
  sleep 10
done

if [ $attempt -ge $MAX_WAIT ]; then
  log_warning "Timed out waiting for distribution to disable after 30 minutes"
  log_warning "Current state: Enabled=${ENABLED_STATUS}, Status=${DIST_STATUS}"
  log_warning "Delete may still fail with DistributionNotDisabled."
fi

# Step 4: Fetch fresh ETag for deletion
log_info "Fetching fresh ETag for deletion..."
DELETE_ETAG="$(aws cloudfront get-distribution-config \
  --id "$CF_ID" \
  --profile "$AWS_PROFILE" \
  --query 'ETag' \
  --output text 2>/dev/null || echo "")"

if [ -z "$DELETE_ETAG" ] || [ "$DELETE_ETAG" = "None" ]; then
  log_error "Could not fetch ETag for deletion; aborting delete for $CF_ID"
  exit 1
fi

# Step 5: Delete distribution
log_info "Deleting distribution $CF_ID..."
if aws cloudfront delete-distribution \
  --id "$CF_ID" \
  --if-match "$DELETE_ETAG" \
  --profile "$AWS_PROFILE" >/dev/null 2>&1; then
  log_success "CloudFront distribution $CF_ID deletion initiated successfully"
  log_info "Note: Full deletion may take 10–20+ minutes to complete."
else
  log_error "Failed to delete CloudFront distribution $CF_ID"
  log_info "Check CloudFront console or run 'aws cloudfront get-distribution --id $CF_ID' for details."
  exit 1
fi

