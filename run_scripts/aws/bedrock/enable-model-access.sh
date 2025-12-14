#!/bin/bash
# Check and optionally enable Bedrock model access
# Some models may require one-time form submission (e.g., Anthropic models)
# Usage: ./enable-model-access.sh [--provider PROVIDER] [--model MODEL_ID] [--enable] [--list-models] [--list-providers]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
source "$SCRIPT_DIR/../../common/logger.sh"
source "$SCRIPT_DIR/../../common/load-env.sh"

# ============================================================================
# DEFAULT VALUES (can be overridden via arguments or environment variables)
# ============================================================================
DEFAULT_PROVIDER="anthropic"
DEFAULT_MODEL="anthropic.claude-3-haiku-20240307-v1:0"
DEFAULT_REGION="us-east-1"

# ============================================================================
# Initialize variables from environment or defaults
# ============================================================================
PROVIDER="${DEFAULT_PROVIDER}"
MODEL_ID="${BEDROCK_MODEL_ID:-$DEFAULT_MODEL}"
AWS_REGION="${AWS_REGION:-$DEFAULT_REGION}"
AWS_PROFILE="${AWS_PROFILE:-admin}"  # Default to admin for infrastructure operations

# ============================================================================
# Helper Functions (defined early for use in argument parsing)
# ============================================================================

# Show usage information
show_usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Check and optionally enable Bedrock model access.

OPTIONS:
    --provider PROVIDER    Provider name (default: $DEFAULT_PROVIDER)
                          Examples: anthropic, ai21, amazon, cohere, meta, mistral
    --model MODEL_ID       Full model ID to check (default: $DEFAULT_MODEL)
    --list-models          List all available models (optionally filtered by --provider)
    --list-providers       List all available providers
    --enable               Attempt to enable model access if not available
    --verify               Verify model access (show list-foundation-models output)
    -h, --help             Show this help message

EXAMPLES:
    # Check default model ($DEFAULT_PROVIDER / $DEFAULT_MODEL)
    $0

    # Check specific model with explicit provider
    $0 --provider ai21 --model ai21.j2-ultra-v1:0

    # Check model (provider can be inferred but explicit is clearer)
    $0 --model anthropic.claude-3-sonnet-20240229-v1:0

    # List all models from a provider
    $0 --list-models --provider anthropic

    # List all providers
    $0 --list-providers

    # Attempt to enable access
    $0 --provider anthropic --model anthropic.claude-3-sonnet-20240229-v1:0 --enable

    # Verify model access (show list-foundation-models output, matching guide 6.2)
    $0 --verify --provider anthropic --model anthropic.claude-3-haiku-20240307-v1:0

ENVIRONMENT VARIABLES:
    BEDROCK_MODEL_ID       Default model ID to check
    AWS_REGION             AWS region (default: $DEFAULT_REGION)
    AWS_PROFILE            AWS profile to use

EOF
}

# ============================================================================
# Parse command-line arguments
# ============================================================================
ENABLE_IF_MISSING=false
LIST_MODELS=false
LIST_PROVIDERS=false
VERIFY_MODE=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --provider)
            PROVIDER="$2"
            shift 2
            ;;
        --model)
            MODEL_ID="$2"
            shift 2
            ;;
        --enable)
            ENABLE_IF_MISSING=true
            shift
            ;;
        --verify)
            VERIFY_MODE=true
            shift
            ;;
        --list-models)
            LIST_MODELS=true
            shift
            ;;
        --list-providers)
            LIST_PROVIDERS=true
            shift
            ;;
        -h|--help)
            show_usage
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            show_usage
            exit 1
            ;;
    esac
done

# Load environment variables (after parsing arguments)
load_env_file 2>/dev/null || true

# ============================================================================
# Helper Functions
# ============================================================================

# Build AWS CLI profile flag
get_aws_profile_flag() {
    [ -n "$AWS_PROFILE" ] && echo "--profile $AWS_PROFILE" || echo ""
}

# Capitalize first letter of provider name for AWS queries
# e.g., "anthropic" -> "Anthropic", "ai21" -> "Ai21"
capitalize_provider() {
    local provider=$1
    echo "$provider" | sed 's/^./\U&/'
}

# Check if Bedrock service is accessible
check_bedrock_service() {
    log_info "Checking Bedrock service access..."
    
    local profile_flag=$(get_aws_profile_flag)
    
    if aws bedrock list-foundation-models $profile_flag --region "$AWS_REGION" >/dev/null 2>&1; then
        log_success "Bedrock service is accessible"
        return 0
    else
        log_error "Cannot access Bedrock service"
        log_info "Possible reasons:"
        log_info "  1. Bedrock is not available in region: $AWS_REGION"
        log_info "  2. IAM permissions are insufficient"
        log_info "  3. Service is not enabled for your account"
        return 1
    fi
}

# Check if specific model is available
check_model_access() {
    local model=$1
    log_info "Checking access to model: $model"
    
    local profile_flag=$(get_aws_profile_flag)
    
    # Extract foundation model ID (before colon)
    local foundation_model=$(echo "$model" | cut -d: -f1)
    
    # Try to get model details
    if aws bedrock get-foundation-model $profile_flag \
        --region "$AWS_REGION" \
        --model-identifier "$foundation_model" >/dev/null 2>&1; then
        log_success "Model access confirmed: $model"
        return 0
    else
        log_warning "Model access not available: $model"
        return 1
    fi
}

# List available models by provider
list_models_by_provider() {
    local provider="${1:-$PROVIDER}"
    local provider_capitalized=$(capitalize_provider "$provider")
    
    log_info "Listing available ${provider_capitalized} models..."
    
    local profile_flag=$(get_aws_profile_flag)
    
    aws bedrock list-foundation-models $profile_flag \
        --region "$AWS_REGION" \
        --query "modelSummaries[?providerName=='${provider_capitalized}'].{ModelId:modelId,Name:modelName}" \
        --output table 2>/dev/null || {
        log_warning "Could not list ${provider_capitalized} models"
        return 1
    }
}

# List all available providers
list_providers() {
    log_info "Listing all available Bedrock providers..."
    
    local profile_flag=$(get_aws_profile_flag)
    
    aws bedrock list-foundation-models $profile_flag \
        --region "$AWS_REGION" \
        --query "modelSummaries[].providerName" \
        --output text 2>/dev/null | sort -u || {
        log_warning "Could not list providers"
        return 1
    }
}

# List all available models (optionally filtered by provider)
list_all_models() {
    local provider="${1:-}"
    
    local profile_flag=$(get_aws_profile_flag)
    
    if [ -n "$provider" ]; then
        list_models_by_provider "$provider"
    else
        log_info "Listing all available foundation models..."
        aws bedrock list-foundation-models $profile_flag \
            --region "$AWS_REGION" \
            --query "modelSummaries[].{Provider:providerName,ModelId:modelId,Name:modelName}" \
            --output table 2>/dev/null || {
            log_warning "Could not list models"
            return 1
        }
    fi
}

# Attempt to enable model access (if possible)
# Note: This is a best-effort attempt. Some models (e.g., Anthropic) may
# require a one-time usage form submission via the console.
attempt_enable_model() {
    local model=$1
    local provider=$2
    
    log_info "Attempting to enable model access: $model"
    log_warning "Note: Automated enablement may not work for all models"
    log_warning "      Some models may require one-time form submission"
    
    local profile_flag=$(get_aws_profile_flag)
    local foundation_model=$(echo "$model" | cut -d: -f1)
    
    # Try to use create-foundation-model-agreement
    # This requires an offer-token which is complex to obtain programmatically
    log_info "Checking if model agreement can be created..."
    
    # For now, we'll provide instructions rather than attempting
    # The API requires offer tokens that are typically obtained through
    # the console or organization-level setup
    log_warning "Automated enablement via CLI is limited"
    log_info "For some providers (e.g., ${provider^}), the one-time usage form must be"
    log_info "completed via the AWS Console when you first select the model."
    log_info ""
    log_info "If you're in an AWS Organization, the form can be submitted"
    log_info "at the organization level to enable access for all accounts."
    
    return 1
}

# Verify that model appears in list-foundation-models output (matching guide section 6.2)
# This function checks if the model is in the available models list and shows the output
verify_model_in_list() {
    local model=$1
    local provider=$2
    local max_attempts=${3:-3}  # Retry up to 3 times
    local wait_seconds=${4:-10}  # Wait 10 seconds between attempts
    
    local foundation_model=$(echo "$model" | cut -d: -f1)
    local profile_flag=$(get_aws_profile_flag)
    local found=false
    local attempt=1
    local provider_capitalized=$(capitalize_provider "$provider")
    
    log_step "Verifying model appears in available models list"
    log_info "This may take a few moments as access propagates..."
    echo ""
    
    # Retry logic to handle propagation delays
    while [ $attempt -le $max_attempts ]; do
        log_info "Attempt $attempt/$max_attempts: Checking if model is in list..."
        
        # Get list of available models and check if our model is in it
        local model_list=$(aws bedrock list-foundation-models $profile_flag \
            --region "$AWS_REGION" \
            --query "modelSummaries[?contains(modelId, '${foundation_model}')].modelId" \
            --output text 2>/dev/null)
        
        # Check if our model (or a variant) is in the list
        if [ -n "$model_list" ] && echo "$model_list" | grep -q "$foundation_model"; then
            found=true
            log_success "Model found in available models list!"
            break
        fi
        
        if [ $attempt -lt $max_attempts ]; then
            log_info "Model not yet in list. Waiting ${wait_seconds} seconds before retry..."
            sleep $wait_seconds
        fi
        attempt=$((attempt + 1))
    done
    
    # Show the actual list output (matching guide section 6.2)
    echo ""
    log_info "Listing available models (as per guide section 6.2):"
    log_info "Command: aws bedrock list-foundation-models --region $AWS_REGION"
    echo ""
    
    # Show all available models
    if ! aws bedrock list-foundation-models $profile_flag \
        --region "$AWS_REGION" \
        --output table 2>/dev/null; then
        log_warning "Could not list foundation models"
        return 1
    fi
    
    echo ""
    
    # Show provider-specific models for reference
    log_info "Available ${provider_capitalized} models:"
    list_models_by_provider "$provider" || true
    
    echo ""
    
    if [ "$found" = true ]; then
        log_success "✅ Model found in available models list: $model"
        
        # Also verify with get-foundation-model (matching guide section 6.2)
        log_info "Verifying specific model access (as per guide section 6.2):"
        log_info "Command: aws bedrock get-foundation-model --model-identifier $foundation_model --region $AWS_REGION"
        echo ""
        
        if aws bedrock get-foundation-model $profile_flag \
            --region "$AWS_REGION" \
            --model-identifier "$foundation_model" 2>/dev/null; then
            echo ""
            log_success "✅ Model access verified: $model"
            log_info ""
            log_info "You should see ${provider_capitalized} models in the list above and be able to access the specific model."
            return 0
        else
            log_warning "⚠️  Model is in list but get-foundation-model failed"
            log_info "This may indicate a permissions issue or the model is still propagating."
            return 1
        fi
    else
        log_warning "⚠️  Model not found in available models list after $max_attempts attempts"
        log_info ""
        log_info "This may take a few minutes. The model access may still be propagating."
        log_info "You can verify manually by running:"
        log_info "  aws bedrock list-foundation-models --region $AWS_REGION"
        log_info "  aws bedrock get-foundation-model --model-identifier $foundation_model --region $AWS_REGION"
        return 1
    fi
}

# Provide manual enablement instructions
show_manual_instructions() {
    local model=$1
    local provider=$2
    local foundation_model=$(echo "$model" | cut -d: -f1)
    local provider_capitalized=$(capitalize_provider "$provider")
    
    echo ""
    log_step "Manual Enablement Required"
    echo ""
    log_info "To enable Bedrock model access manually:"
    echo ""
    log_info "1. Open AWS Console:"
    log_info "   https://console.aws.amazon.com/bedrock/"
    echo ""
    log_info "2. Navigate to 'Model access' in the left sidebar"
    echo ""
    log_info "3. Click 'Manage model access'"
    echo ""
    log_info "4. Select the model(s) you want to use:"
    
    # Provider-specific guidance
    case "$provider" in
        anthropic)
            log_info "   For ${provider_capitalized} (Claude) models:"
            log_info "   - Claude 3 Haiku (recommended for cost)"
            log_info "   - Claude 3 Sonnet (balanced)"
            log_info "   - Claude 3 Opus (highest quality)"
            ;;
        ai21)
            log_info "   For ${provider_capitalized} (Jurassic) models:"
            log_info "   - J2 Ultra (high quality)"
            log_info "   - J2 Mid (balanced)"
            ;;
        amazon)
            log_info "   For ${provider_capitalized} (Titan) models:"
            log_info "   - Titan Text G1 - Large"
            log_info "   - Titan Text G1 - Lite"
            ;;
        cohere)
            log_info "   For ${provider_capitalized} models:"
            log_info "   - Command models"
            log_info "   - Embed models"
            ;;
        meta)
            log_info "   For ${provider_capitalized} (Llama) models:"
            log_info "   - Llama 2"
            log_info "   - Llama 3"
            ;;
        mistral)
            log_info "   For ${provider_capitalized} models:"
            log_info "   - Mistral 7B"
            log_info "   - Mixtral 8x7B"
            ;;
        *)
            log_info "   Look for models from provider: ${provider_capitalized}"
            log_info "   Use --list-models --provider $provider to see available models"
            ;;
    esac
    
    echo ""
    log_info "   Your requested model: $model"
    echo ""
    log_info "5. Click 'Save changes'"
    echo ""
    log_info "6. Wait for model access to be enabled (may take a few minutes)"
    echo ""
    log_info "7. Wait for model access to be enabled (may take a few minutes)"
    echo ""
    log_info "8. Verify access by running this script again:"
    log_info "   $0 --provider $provider --model $model"
    echo ""
    log_info "Or verify manually with AWS CLI (as per guide section 6.2):"
    log_info "   aws bedrock list-foundation-models --region $AWS_REGION"
    log_info "   aws bedrock get-foundation-model --model-identifier $foundation_model --region $AWS_REGION"
    echo ""
    log_info "Note: For some providers (e.g., ${provider_capitalized}), you may need to complete a one-time"
    log_info "      usage form when selecting the model in the console."
    echo ""
    log_info "Note: If you see errors, the model access may still be propagating."
    log_info "      Wait a few minutes and try again."
    echo ""
}

# ============================================================================
# Main Function
# ============================================================================
main() {
    # Handle list operations first
    if [ "$LIST_PROVIDERS" = true ]; then
        list_providers
        return 0
    fi
    
    if [ "$LIST_MODELS" = true ]; then
        list_all_models "$PROVIDER"
        return 0
    fi
    
    # Main workflow: check model access
    log_step "Bedrock Model Access Check"
    log_info "Provider: $PROVIDER"
    log_info "Model: $MODEL_ID"
    log_info "Region: $AWS_REGION"
    [ -n "$AWS_PROFILE" ] && log_info "Profile: $AWS_PROFILE"
    echo ""
    
    # Step 1: Check Bedrock service access
    if ! check_bedrock_service; then
        log_error "Bedrock service check failed"
        show_manual_instructions "$MODEL_ID" "$PROVIDER"
        exit 1
    fi
    
    echo ""
    
    # Step 2: Check specific model access
    if check_model_access "$MODEL_ID"; then
        log_success "✅ Model access is already enabled!"
        echo ""
        
        # If --verify flag is set, show full verification output (matching guide 6.2)
        if [ "$VERIFY_MODE" = true ]; then
            log_info "Running verification (as per guide section 6.2)..."
            echo ""
            if verify_model_in_list "$MODEL_ID" "$PROVIDER" 1 0; then
                log_success "✅ Verification complete!"
                return 0
            else
                log_warning "Verification had issues, but model access appears enabled"
                return 0
            fi
        else
            log_info "You can proceed with using Bedrock in your application."
            log_info "To see full verification output, run with --verify flag:"
            log_info "  $0 --verify --provider $PROVIDER --model $MODEL_ID"
            return 0
        fi
    fi
    
    echo ""
    
    # Step 3: List available models from same provider (for reference)
    log_info "Listing available models from provider: $PROVIDER (for reference)..."
    list_models_by_provider "$PROVIDER"
    
    echo ""
    
    # Step 4: Attempt automated enablement if requested
    if [ "$ENABLE_IF_MISSING" = true ]; then
        log_info "Attempting automated enablement..."
        if attempt_enable_model "$MODEL_ID" "$PROVIDER"; then
            log_info "Model enablement requested. Verifying access..."
            echo ""
            
            # Verify model appears in list-foundation-models (matching guide 6.2)
            if verify_model_in_list "$MODEL_ID" "$PROVIDER" 3 10; then
                log_success "✅ Model access enabled and verified!"
                log_info "Model appears in available models list and is accessible."
                return 0
            else
                log_warning "Model enablement may still be propagating"
                log_info "Note: Model access may take a few minutes to become available"
                log_info "You can verify later by running this script again"
                return 1
            fi
        else
            log_warning "Automated enablement not possible"
            log_info "Please enable model access manually via AWS Console"
        fi
        echo ""
    fi
    
    # Step 5: Show manual instructions
    show_manual_instructions "$MODEL_ID" "$PROVIDER"
    
    return 1
}

main "$@"

