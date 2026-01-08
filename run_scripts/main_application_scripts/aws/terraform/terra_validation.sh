#!/bin/bash
# Validate and plan Terraform/Terragrunt configurations
# Fail-fast: stops immediately on first error
# Usage: ./terra_validation.sh [dev|prod|all]

set -e  # Fail-fast: exit on any error

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../../.." && pwd)}"
source "$REPO_ROOT/run_scripts/shared/logger.sh"
source "$REPO_ROOT/run_scripts/shared/load-env.sh"

TERRAFORM_DIR="$REPO_ROOT/infra/terraform/environments"
RESULTS_DIR="$REPO_ROOT/temp_terra_gen/validation_sh_results"
TIMESTAMP=$(date +%y%m%d-%H%M%S)
SCRIPT_PREFIX="terra_validation"
RUN_DIR="${RESULTS_DIR}/${TIMESTAMP}_${SCRIPT_PREFIX}"

# Global variables for summary
declare -a PROCESSED_FILES=()

# Parse arguments
ENVIRONMENT="${1:-all}"

if [[ ! "$ENVIRONMENT" =~ ^(dev|prod|all)$ ]]; then
    log_error "Invalid environment: $ENVIRONMENT"
    log_info "Usage: $0 [dev|prod|all]"
    exit 1
fi

# Create run directory for this execution
mkdir -p "$RUN_DIR"

# Function to get output file path
get_output_file() {
    local env=$1
    local layer=$2
    local operation=$3
    echo "$RUN_DIR/${env}_${layer}_${operation}.txt"
}

# Function to validate a Terragrunt configuration
validate_config() {
    local config_file=$1
    local env=$2
    local layer=$3
    local output_file=$(get_output_file "$env" "$layer" "validate")
    local config_dir=$(dirname "$config_file")
    
    log_step "Validating: $config_file"
    
    cd "$config_dir"
    
    # Run validation (AWS_PROFILE is set globally)
    # Terragrunt will automatically find terragrunt.hcl in the current directory
    if terragrunt validate > "$output_file" 2>&1; then
        log_success "Validation passed: $config_file"
        return 0
    else
        log_error "Validation failed: $config_file"
        log_info "Output saved to: $output_file"
        cat "$output_file"
        return 1
    fi
}

# Function to plan a Terragrunt configuration
plan_config() {
    local config_file=$1
    local env=$2
    local layer=$3
    local output_file=$(get_output_file "$env" "$layer" "plan")
    local config_dir=$(dirname "$config_file")
    
    log_step "Planning: $config_file"
    
    cd "$config_dir"
    
    # Run plan (AWS_PROFILE is set globally)
    # Terragrunt will automatically find terragrunt.hcl in the current directory
    if terragrunt plan > "$output_file" 2>&1; then
        log_success "Plan completed: $config_file"
        log_info "Plan output saved to: $output_file"
        return 0
    else
        log_error "Plan failed: $config_file"
        log_info "Output saved to: $output_file"
        cat "$output_file"
        return 1
    fi
}

# Function to find all deepest-level HCL files
find_hcl_files() {
    local env_filter=$1
    local files=()
    
    if [ "$env_filter" = "all" ]; then
        # Find all terragrunt.hcl files in infrastructure and application directories (exclude .terragrunt-cache)
        while IFS= read -r file; do
            files+=("$file")
        done < <(find "$TERRAFORM_DIR" -type f -name "terragrunt.hcl" ! -path "*/.terragrunt-cache/*" ! -path "*/root.hcl" ! -path "*/env.hcl" | sort)
    else
        # Find files for specific environment (exclude .terragrunt-cache)
        while IFS= read -r file; do
            files+=("$file")
        done < <(find "$TERRAFORM_DIR/$env_filter" -type f -name "terragrunt.hcl" ! -path "*/.terragrunt-cache/*" | sort)
    fi
    
    echo "${files[@]}"
}

# Function to extract environment and layer from file path
get_env_and_layer() {
    local file_path=$1
    local env=$(echo "$file_path" | sed -n 's|.*/environments/\([^/]*\)/.*|\1|p')
    local layer=""
    if [[ "$file_path" == *"/infrastructure/"* ]]; then
        layer="infrastructure"
    elif [[ "$file_path" == *"/application/"* ]]; then
        layer="application"
    fi
    echo "$env $layer"
}

# Check prerequisites
check_prerequisites() {
    log_step "Checking prerequisites"
    
    if ! command -v terragrunt >/dev/null 2>&1; then
        log_error "Terragrunt is not installed"
        log_info "Install with: brew install terragrunt"
        exit 1
    fi
    
    if ! command -v terraform >/dev/null 2>&1; then
        log_error "Terraform is not installed"
        log_info "Install with: brew install terraform"
        exit 1
    fi
    
    # Check AWS credentials and set profile for Terragrunt
    if ! aws sts get-caller-identity --profile admin >/dev/null 2>&1; then
        log_error "AWS credentials not configured (admin profile)"
        log_info "Run: ./run_scripts/aws/setup-aws-profiles.sh"
        exit 1
    fi
    
    # Set AWS_PROFILE for Terragrunt to use admin profile
    export AWS_PROFILE=admin
    
    log_success "Prerequisites check passed"
}

# Setup S3 bucket for Terraform state (idempotent)
setup_state_bucket() {
    log_step "Ensuring Terraform state bucket exists"
    log_info "This is idempotent - safe to run multiple times"
    
    # Load environment variables if not already loaded
    if [ -z "${TF_STATE_BUCKET:-}" ]; then
        load_env_file
    fi
    
    # Call setup-s3-bucket.sh (idempotent)
    if "$SCRIPT_DIR/setup-s3-bucket.sh"; then
        log_success "Terraform state bucket ready"
        return 0
    else
        log_error "Failed to setup Terraform state bucket"
        return 1
    fi
}

# Main validation function
run_validation() {
    log_step "Starting Terraform/Terragrunt validation"
    log_info "Results directory: $RUN_DIR"
    log_info "Timestamp: $TIMESTAMP"
    
    # Find all HCL files
    local hcl_files=($(find_hcl_files "$ENVIRONMENT"))
    
    if [ ${#hcl_files[@]} -eq 0 ]; then
        log_error "No HCL files found for environment: $ENVIRONMENT"
        exit 1
    fi
    
    log_info "Found ${#hcl_files[@]} configuration file(s)"
    
    # Separate infrastructure and application files
    local infra_files=()
    local appl_files=()
    
    for file in "${hcl_files[@]}"; do
        if [[ "$file" == *"/infrastructure/"* ]]; then
            infra_files+=("$file")
        elif [[ "$file" == *"/application/"* ]]; then
            appl_files+=("$file")
        fi
    done
    
    # Phase 1: Validate all files (infrastructure first, then application)
    log_step "Phase 1: Validating all configurations"
    
    # Validate infrastructure files first
    for file in "${infra_files[@]}"; do
        read -r env layer <<< "$(get_env_and_layer "$file")"
        PROCESSED_FILES+=("$file")
        validate_config "$file" "$env" "$layer"
    done
    
    # Validate application files
    for file in "${appl_files[@]}"; do
        read -r env layer <<< "$(get_env_and_layer "$file")"
        PROCESSED_FILES+=("$file")
        validate_config "$file" "$env" "$layer"
    done
    
    log_success "All validations passed"
    
    # Phase 2: Plan application layer only
    log_step "Phase 2: Planning application layer configurations"
    
    for file in "${appl_files[@]}"; do
        read -r env layer <<< "$(get_env_and_layer "$file")"
        plan_config "$file" "$env" "$layer"
    done
    
    log_success "All plans completed successfully"
}

# Generate summary report
generate_summary() {
    local summary_file="$RUN_DIR/summary.txt"
    
    cat > "$summary_file" << EOF
Terraform/Terragrunt Validation Summary
======================================
Timestamp: $TIMESTAMP
Environment: $ENVIRONMENT
Results Directory: $RUN_DIR

Files Processed:
EOF
    
    for file in "${PROCESSED_FILES[@]}"; do
        echo "  - $file" >> "$summary_file"
    done
    
    cat >> "$summary_file" << EOF

Validation: PASSED
Planning: PASSED

All configurations validated and planned successfully.
You can proceed with: ./run_scripts/aws/terraform/deploy.sh
EOF
    
    log_info "Summary report: $summary_file"
    cat "$summary_file"
}

# Main execution
main() {
    check_prerequisites
    setup_state_bucket
    run_validation
    generate_summary
    
    log_success "Validation complete - all checks passed"
    log_info "Results saved to: $RUN_DIR"
}

main "$@"

