#!/bin/bash
# Deploy data-lake Terraform layer (S3 bucket + IAM permissions)
# Called by: run_scripts/aws/data-lake/setup-and-verify.sh
# Receives: ENVIRONMENT, DRY_RUN, DATA_LAKE_SETUP_MODE from parent

set -e

# This script can be sourced (to export variables) or executed directly
# When sourced, variables are exported to parent shell
# When executed, script exits with appropriate code

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../../.." && pwd)"
source "$SCRIPT_DIR/../../../common/logger.sh"
source "$SCRIPT_DIR/../../../common/load-env.sh"

ENVIRONMENT="${ENVIRONMENT:-dev}"
DRY_RUN="${DRY_RUN:-false}"
MODE="${DATA_LAKE_SETUP_MODE:-standalone}"  # Get mode from parent

# S3 data bucket is created in the infrastructure layer, not a separate data-lake layer
# Get bucket information from infrastructure layer outputs
INFRASTRUCTURE_DIR="$REPO_ROOT/infra/terraform/environments/$ENVIRONMENT/infrastructure"

if [ ! -d "$INFRASTRUCTURE_DIR" ]; then
    log_error "Infrastructure Terraform directory not found: $INFRASTRUCTURE_DIR"
    log_error "Ensure the infrastructure layer is deployed first"
    exit 1
fi

# Check AWS credentials
if ! command_exists aws; then
    log_error "AWS CLI is not installed"
    exit 1
fi

if ! aws sts get-caller-identity --profile "${AWS_PROFILE:-admin}" >/dev/null 2>&1; then
    log_error "AWS credentials not configured. Please set AWS_PROFILE or run 'aws configure'"
    exit 1
fi

# Check if Terragrunt is installed
if ! command_exists terragrunt; then
    log_error "Terragrunt is not installed"
    log_info "Install with: brew install terragrunt"
    exit 1
fi

cd "$INFRASTRUCTURE_DIR"

# Mode-specific behavior
if [ "$MODE" = "standalone" ]; then
    # Idempotent: Check if already deployed
    log_info "Checking if S3 data bucket already exists..."
    if AWS_PROFILE="${AWS_PROFILE:-admin}" terragrunt output s3_data_bucket_id >/dev/null 2>&1; then
        log_info "S3 data bucket infrastructure already deployed"
        
        # Quick verification
        BUCKET_ID=$(AWS_PROFILE="${AWS_PROFILE:-admin}" terragrunt output -raw s3_data_bucket_id 2>/dev/null || echo "")
        if [ -n "$BUCKET_ID" ]; then
            log_success "✓ S3 bucket exists: $BUCKET_ID"
            log_info "Skipping deployment (idempotent mode - bucket is in infrastructure layer)"
            
            # Export for next step
            S3_BUCKET_ID="$BUCKET_ID"
            S3_BUCKET_ARN=$(AWS_PROFILE="${AWS_PROFILE:-admin}" terragrunt output -raw s3_data_bucket_arn 2>/dev/null || echo "")
            S3_DELTA_PATH=$(AWS_PROFILE="${AWS_PROFILE:-admin}" terragrunt output -raw s3_delta_table_path 2>/dev/null || echo "")
                export S3_BUCKET_ID S3_BUCKET_ARN S3_DELTA_PATH
                exit 0
        else
            log_warning "Terraform state exists but outputs are not accessible"
            log_info "The S3 bucket should be created by the infrastructure layer"
            log_info "If infrastructure is not deployed, run: ./run_scripts/aws/run.sh infrastructure dev"
            exit 1
        fi
    else
        log_warning "S3 data bucket not found in infrastructure outputs"
        log_info "The S3 bucket should be created by the infrastructure layer"
        log_info "Attempting to find bucket by naming pattern..."
        
        # Try to find bucket by naming pattern: fru-{env}-analytics-data-{account_id}
        ACCOUNT_ID=$(aws sts get-caller-identity --profile "${AWS_PROFILE:-admin}" --query Account --output text 2>/dev/null || echo "")
        if [ -n "$ACCOUNT_ID" ]; then
            BUCKET_NAME="fru-${ENVIRONMENT}-analytics-data-${ACCOUNT_ID}"
            if aws s3 ls "s3://${BUCKET_NAME}" --profile "${AWS_PROFILE:-admin}" >/dev/null 2>&1; then
                log_success "✓ Found S3 bucket: $BUCKET_NAME"
                S3_BUCKET_ID="$BUCKET_NAME"
                S3_BUCKET_ARN="arn:aws:s3:::${BUCKET_NAME}"
                S3_DELTA_PATH="s3://${BUCKET_NAME}/delta/fru_sales"
                export S3_BUCKET_ID S3_BUCKET_ARN S3_DELTA_PATH
                log_info "Using existing bucket (infrastructure outputs may need refresh)"
                # Export variables for parent script (write to file that parent can source)
                VARS_FILE="${TMPDIR:-/tmp}/data-lake-vars-$$"
                echo "export S3_BUCKET_ID=\"$S3_BUCKET_ID\"" > "$VARS_FILE"
                echo "export S3_BUCKET_ARN=\"$S3_BUCKET_ARN\"" >> "$VARS_FILE"
                echo "export S3_DELTA_PATH=\"$S3_DELTA_PATH\"" >> "$VARS_FILE"
                echo "$VARS_FILE"  # Output file path for parent to source
                exit 0
            else
                log_error "S3 bucket not found: $BUCKET_NAME"
                log_info "The bucket needs to be created by the infrastructure layer"
                log_info "Run: ./run_scripts/aws/run.sh infrastructure dev"
                log_info "Or apply infrastructure layer: cd infra/terraform/environments/dev/infrastructure && terragrunt apply"
                exit 1
            fi
        else
            log_error "Could not determine AWS account ID"
            log_info "Deploy infrastructure first: ./run_scripts/aws/run.sh infrastructure dev"
            exit 1
        fi
    fi
else
    # Full-workflow: Always ensure it's properly configured
    log_info "Ensuring S3 data bucket is properly configured (full-workflow mode)..."
    log_info "Note: S3 bucket is managed by infrastructure layer, not data-lake layer"
fi

if [ "$DRY_RUN" = "true" ]; then
    log_info "[DRY-RUN] Would check S3 data bucket from infrastructure layer"
    AWS_PROFILE="${AWS_PROFILE:-admin}" terragrunt output s3_data_bucket_id
    exit 0
fi

# Get bucket information from infrastructure layer (bucket is already deployed there)
log_info "Getting S3 data bucket information from infrastructure layer..."
S3_BUCKET_ID=$(AWS_PROFILE="${AWS_PROFILE:-admin}" terragrunt output -raw s3_data_bucket_id 2>/dev/null || echo "")
S3_BUCKET_ARN=$(AWS_PROFILE="${AWS_PROFILE:-admin}" terragrunt output -raw s3_data_bucket_arn 2>/dev/null || echo "")
S3_DELTA_PATH=$(AWS_PROFILE="${AWS_PROFILE:-admin}" terragrunt output -raw s3_delta_table_path 2>/dev/null || echo "")

if [ -z "$S3_BUCKET_ID" ]; then
    log_error "Data-lake deployment completed but bucket_id output is not accessible"
    exit 1
fi

log_success "Data-lake infrastructure deployed"
log_info "  S3 bucket: $S3_BUCKET_ID"
if [ -n "$S3_BUCKET_ARN" ]; then
    log_info "  S3 bucket ARN: $S3_BUCKET_ARN"
fi
if [ -n "$S3_DELTA_PATH" ]; then
    log_info "  Delta table path: $S3_DELTA_PATH"
fi

# Export for next step
export S3_BUCKET_ID S3_BUCKET_ARN S3_DELTA_PATH

