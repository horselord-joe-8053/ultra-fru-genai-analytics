#!/bin/bash
# Copy EKS Terraform state from legacy key dev/application-eks/terraform.tfstate
# to dev/eks/terraform.tfstate so dev/eks is the single source of truth.
# Run once with AWS credentials; then use ./teardown.sh dev eks as usual.
# Usage: ./migrate-eks-state.sh [dev]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../../../.." && pwd)}"
source "$REPO_ROOT/run_scripts/shared/logger.sh"
source "$REPO_ROOT/run_scripts/shared/load-env.sh"

load_env_file
export AWS_PROFILE="${AWS_PROFILE:-admin}"
export AWS_REGION="${AWS_REGION:-us-east-1}"

ENV="${1:-dev}"
AWS_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text 2>/dev/null)" || {
  log_error "AWS credentials not configured or invalid"
  exit 1
}
BUCKET="${TF_STATE_BUCKET:-fru-terraform-state-${AWS_ACCOUNT_ID}}"
SRC="s3://${BUCKET}/${ENV}/application-eks/terraform.tfstate"
DST="s3://${BUCKET}/${ENV}/eks/terraform.tfstate"

if ! aws s3 ls "$SRC" --region "${AWS_REGION}" &>/dev/null; then
  log_info "No state at ${SRC}; nothing to migrate."
  log_info "Listing state keys under ${ENV}/ in bucket (for reference):"
  aws s3 ls "s3://${BUCKET}/${ENV}/" --region "${AWS_REGION}" 2>/dev/null || true
  exit 0
fi

log_step "Copying EKS state to canonical key (dev/eks)"
log_info "Source: $SRC"
log_info "Dest:   $DST"
aws s3 cp "$SRC" "$DST" --region "${AWS_REGION}" || { log_error "Copy failed"; exit 1; }
log_success "Done. Use: ./teardown.sh $ENV eks (or terragrunt from environments/$ENV/eks)"
