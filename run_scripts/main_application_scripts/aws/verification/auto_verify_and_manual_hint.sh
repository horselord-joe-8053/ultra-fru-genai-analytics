#!/bin/bash
# Auto-verify deployment and show manual test hints
# Replaces: post_run_verify.sh + manual_test_hint.sh
# Usage: ./auto_verify_and_manual_hint.sh <deployment-type> <environment> [dry-run]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
VERIFICATION_DIR="$SCRIPT_DIR"

# Source common utilities
source "$REPO_ROOT/run_scripts/shared/logger.sh"
source "$REPO_ROOT/run_scripts/shared/load-env.sh"
load_env_file || log_warning "Could not load .env"

# Get parameters
# CONTAINER_TYPE is used (set via environment variable from run.sh)
ENVIRONMENT="${2:-dev}"
DRY_RUN="${3:-false}"

# Determine container type from CONTAINER_TYPE (exported by run.sh)
CONTAINER_TYPE="${CONTAINER_TYPE:-ecs}"  # Default to ecs if not set

# Export for child scripts
export CONTAINER_TYPE ENVIRONMENT DRY_RUN REPO_ROOT

echo ""
log_step "═══════════════════════════════════════════════════════════════════════════════"
log_step "Post-Deployment Verification and Manual Test Hints"
log_step "═══════════════════════════════════════════════════════════════════════════════"
echo ""

# Step 1: Fetch deployment information
log_step "Substep 1/4: Fetching deployment information from Terraform..."
source "$VERIFICATION_DIR/fetch-deployment-info.sh" "$DEPLOYMENT_TYPE" "$ENVIRONMENT" "$DRY_RUN"

# Step 2: Quick service status checks (lightweight, no retry)
if [ "$DRY_RUN" != "true" ]; then
    log_step "Substep 2/4: Checking service status..."
    source "$VERIFICATION_DIR/check-service-status.sh"
    check_service_status "$DEPLOYMENT_TYPE" "$ENVIRONMENT" || true  # Don't fail on status checks
    echo ""
fi

# Step 3: Print manual test hints
log_step "Substep 3/4: Displaying manual test hints..."
source "$VERIFICATION_DIR/print-manual-hints.sh"
print_manual_test_hints

# Step 4: Comprehensive endpoint validation (with retry logic)
if [ "$DRY_RUN" != "true" ]; then
    log_step "Substep 4/4: Validating deployment endpoints (comprehensive)..."
    source "$VERIFICATION_DIR/diagnose-failures.sh"  # For diagnose_api_failure()
    source "$VERIFICATION_DIR/validate-endpoints.sh"
    validate_urls || true  # Don't fail script if validation has issues
    echo ""
fi

log_success "═══════════════════════════════════════════════════════════════════════════════"
log_success "Verification complete!"
log_success "═══════════════════════════════════════════════════════════════════════════════"

