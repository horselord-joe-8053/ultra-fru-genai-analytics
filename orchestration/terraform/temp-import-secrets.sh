#!/bin/bash
#
# Import existing AWS Secrets Manager secrets into Terraform state
#
# PURPOSE:
#   This script synchronizes Terraform state with existing Secrets Manager secrets in AWS.
#   It imports secrets that already exist in AWS but are missing from Terraform state.
#
# ⚠️  WHEN TO USE THIS SCRIPT:
#
#   Use this script ONLY when you encounter one of these specific scenarios:
#
#   1. SECRETS WERE RESTORED FROM DELETION (30-day recovery window)
#      - Secrets were deleted and then restored via AWS Console/CLI
#      - Terraform state still thinks secrets don't exist
#      - Terraform tries to create secrets that already exist
#      - Error: "ResourceExistsException: The operation failed because the secret ... already exists"
#
#   2. TERRAFORM STATE WAS LOST OR RECREATED
#      - Terraform state file was deleted or corrupted
#      - New state was initialized but secrets already exist in AWS
#      - Terraform plan shows it wants to create existing secrets
#
#   3. SECRETS WERE CREATED OUTSIDE TERRAFORM
#      - Secrets were created manually via AWS Console/CLI
#      - Secrets were created by another Terraform configuration
#      - Secrets exist in AWS but not in this Terraform state
#
#   DO NOT USE THIS SCRIPT IF:
#   - Secrets don't exist in AWS yet (Terraform will create them)
#   - Secrets are already in Terraform state (no action needed)
#   - You're running a normal deployment (secrets will be created automatically)
#
#   COMMON ERROR MESSAGE THAT INDICATES YOU NEED THIS SCRIPT:
#     "Error: creating Secrets Manager Secret (...): ResourceExistsException: 
#      The operation failed because the secret ... already exists."
#
# WHAT IT DOES:
#   1. Imports 5 Secrets Manager secrets into Terraform state for the specified environment
#   2. Each secret is mapped from its AWS ARN/name to the Terraform resource path
#   3. After import, Terraform will recognize these secrets as managed resources
#
# PREREQUISITES:
#   - AWS credentials configured (AWS_PROFILE or credentials)
#   - Terraform/Terragrunt installed
#   - Secrets must already exist in AWS Secrets Manager
#   - Appropriate AWS permissions to read Secrets Manager
#
# USAGE:
#   ./import-secrets.sh [dev|prod]
#
#   Example:
#     ./import-secrets.sh dev
#

set -e

# ============================================================================
# Script Setup
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
source "$REPO_ROOT/orchestration/common/logger.sh"
source "$REPO_ROOT/orchestration/common/env/load-env.sh"
load_env_file || true

# ============================================================================
# Argument Validation
# ============================================================================

ENVIRONMENT="${1:-dev}"

if [[ ! "$ENVIRONMENT" =~ ^(dev|prod)$ ]]; then
    log_error "Invalid environment: $ENVIRONMENT"
    log_info "Usage: $0 [dev|prod]"
    exit 1
fi

# ============================================================================
# Configuration
# ============================================================================

# Terraform directory for the specified environment's infrastructure layer (module_infra_basic)
# This is where the secrets_manager module is deployed
TERRAFORM_DIR="$REPO_ROOT/module_infra_basic/aws/terra/environments/$ENVIRONMENT/infrastructure"

log_step "Importing Secrets Manager secrets into Terraform state"
log_info "Environment: $ENVIRONMENT"
log_info "Terraform directory: $TERRAFORM_DIR"

cd "$TERRAFORM_DIR"

# ============================================================================
# Secret Import Mapping
# ============================================================================
#
# Each entry maps: "Terraform Resource Path:Secret Name in AWS"
#
# The 5 secrets imported are:
#   1. openai_key: OpenAI API key (for embeddings) - encrypted version
#   2. openai_key_plain: OpenAI API key (for embeddings) - plaintext version
#   3. db_password: Aurora PostgreSQL database password - encrypted version
#   4. db_password_plain: Aurora PostgreSQL database password - plaintext version
#   5. db_username: Aurora PostgreSQL database username (array index [0])
#
# Note: The secret names follow the pattern: fru/{ENVIRONMENT}/{secret-name}
#

imports=(
    "module.secrets_manager.aws_secretsmanager_secret.openai_key:fru/$ENVIRONMENT/openai-api-key"
    "module.secrets_manager.aws_secretsmanager_secret.openai_key_plain:fru/$ENVIRONMENT/openai-api-key-plain"
    "module.secrets_manager.aws_secretsmanager_secret.db_password:fru/$ENVIRONMENT/aurora-db-password"
    "module.secrets_manager.aws_secretsmanager_secret.db_password_plain:fru/$ENVIRONMENT/aurora-db-password-plain"
    "module.secrets_manager.aws_secretsmanager_secret.db_username[0]:fru/$ENVIRONMENT/aurora-db-username"
)

# ============================================================================
# Import Process
# ============================================================================

for import_spec in "${imports[@]}"; do
    # Parse the import specification: "resource_path:secret_name"
    IFS=':' read -r resource secret_id <<< "$import_spec"
    
    log_info "Importing $resource..."
    
    # Run terragrunt import and capture output to temporary file
    # Using process ID ($$) in filename to avoid collisions if script runs concurrently
    if terragrunt import "$resource" "$secret_id" >/tmp/import_output_$$.log 2>&1; then
        # Check for success indicators in the output
        # Terragrunt/Terraform outputs various success messages depending on version
        if grep -q "Import prepared\|Import successful\|Import complete" /tmp/import_output_$$.log; then
            log_success "✓ Successfully imported $resource"
        else
            # Import command succeeded (exit code 0) but check for hidden errors
            # Sometimes terraform import succeeds but with warnings/errors in output
            if grep -q "Error\|error" /tmp/import_output_$$.log; then
                log_warning "⚠ Import may have failed for $resource (check output above)"
                cat /tmp/import_output_$$.log | tail -5
            else
                # No errors found, assume success
                log_success "✓ Successfully imported $resource"
            fi
        fi
    else
        # Import command failed (non-zero exit code)
        # Common reasons: secret doesn't exist, wrong name, permission issues, already imported
        log_warning "⚠ Import failed for $resource"
        cat /tmp/import_output_$$.log | tail -10
    fi
    
    # Clean up temporary log file after each import
    rm -f /tmp/import_output_$$.log
done

# ============================================================================
# Completion
# ============================================================================

log_success "Secret import process completed"
log_info "Run 'terragrunt plan' to verify state is correct"
log_info "Expected: Terraform should show no changes (secrets already exist and match state)"

