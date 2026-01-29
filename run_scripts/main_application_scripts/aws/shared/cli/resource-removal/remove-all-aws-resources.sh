#!/bin/bash
# Brutal-force removal of all AWS resources listed in find-all-current-aws-resources
# result JSON. Main logic in remove-all-aws-resources.py (boto3). This script is a
# thin wrapper: env, find result JSON, confirmation, invoke Python.
#
# Preserved: Secrets Manager. Optional: S3 state bucket (default preserved).
# Results written to results/aws-fru-removal-YYMMDD_HHMMSS-result.json.
#
# Usage:
#   ./remove-all-aws-resources.sh [--result-json PATH] [--profile PROFILE] [--region REGION] [--dry-run] [--non-interactive] [--no-keep-state-bucket]
#
# Examples:
#   ../resource-check/find-all-current-aws-resources.sh
#   ./remove-all-aws-resources.sh --dry-run
#   ./remove-all-aws-resources.sh --non-interactive

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../../../../../.." && pwd)}"
RESOURCE_CHECK_RESULTS="${SCRIPT_DIR}/../resource-check/results"
PYTHON_SCRIPT="${SCRIPT_DIR}/remove-all-aws-resources.py"

source "$REPO_ROOT/run_scripts/shared/logger.sh"
source "$REPO_ROOT/run_scripts/shared/load-env.sh"

AWS_PROFILE="${AWS_PROFILE:-admin}"
AWS_REGION="${AWS_REGION:-us-east-1}"
RESULT_JSON=""
DRY_RUN="false"
SKIP_CONFIRMATION="false"
KEEP_STATE_BUCKET="true"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --result-json)   RESULT_JSON="$2"; shift 2 ;;
    --profile)       AWS_PROFILE="$2"; shift 2 ;;
    --region)        AWS_REGION="$2"; shift 2 ;;
    --dry-run)       DRY_RUN="true"; shift ;;
    --non-interactive) SKIP_CONFIRMATION="true"; shift ;;
    --no-keep-state-bucket) KEEP_STATE_BUCKET="false"; shift ;;
    -h|--help)
      echo "Usage: $0 [--result-json PATH] [--profile PROFILE] [--region REGION] [--dry-run] [--non-interactive] [--no-keep-state-bucket]"
      echo "  --result-json   JSON from find-all-current-aws-resources.sh (default: latest in resource-check/results/)"
      echo "  --no-keep-state-bucket  Also delete S3 Terraform state bucket"
      exit 0
      ;;
    *) log_error "Unknown option: $1"; exit 1 ;;
  esac
done

load_env_file 2>/dev/null || true
export AWS_PROFILE AWS_REGION

if [ -z "$RESULT_JSON" ]; then
  RESULT_JSON="$(ls -t "$RESOURCE_CHECK_RESULTS"/aws-fru-*.json 2>/dev/null | head -1)"
fi
if [ -z "$RESULT_JSON" ] || [ ! -f "$RESULT_JSON" ]; then
  log_error "No result JSON found. Run find-all-current-aws-resources.sh first or pass --result-json PATH"
  exit 1
fi

if [ ! -f "$PYTHON_SCRIPT" ]; then
  log_error "Python script not found: $PYTHON_SCRIPT"
  exit 1
fi

log_step "Brutal-force AWS resource removal"
log_info "Result JSON: $RESULT_JSON"
log_info "Profile: $AWS_PROFILE  Region: $AWS_REGION"
log_info "Preserved: Secrets Manager (always); S3 state bucket: $KEEP_STATE_BUCKET"
if [ "$DRY_RUN" = "true" ]; then log_warning "DRY-RUN: no changes will be made"; fi
echo ""

if [ "$DRY_RUN" = "false" ] && [ "$SKIP_CONFIRMATION" = "false" ]; then
  log_warning "This will DELETE all resources in the JSON except Secrets Manager (and optionally state bucket)."
  read -p "Type 'yes' to proceed: " confirm
  if [ "$confirm" != "yes" ]; then
    log_info "Cancelled."
    exit 0
  fi
fi

# Install Python deps if missing (boto3)
if ! python3 -c "import boto3" 2>/dev/null; then
  log_info "Installing boto3 (required by remove-all-aws-resources.py)..."
  python3 -m pip install --quiet boto3 || {
    log_error "Failed to install boto3. Run: python3 -m pip install boto3"
    exit 1
  }
fi

PYTHON_ARGS=(
  --result-json "$RESULT_JSON"
  --profile "$AWS_PROFILE"
  --region "$AWS_REGION"
)
[ "$DRY_RUN" = "true" ] && PYTHON_ARGS+=(--dry-run)
[ "$KEEP_STATE_BUCKET" = "false" ] && PYTHON_ARGS+=(--no-keep-state-bucket)

python3 "$PYTHON_SCRIPT" "${PYTHON_ARGS[@]}"
