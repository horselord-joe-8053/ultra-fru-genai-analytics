#!/bin/bash
# Kubernetes manifest helper functions
# Functions for finding, generating, applying, and verifying Kubernetes manifests
#
# CRITICAL: Kubeconfig exec.env vs exec.args Authentication Issue
# ================================================================
# Problem: When kubectl's exec plugin runs in nested subprocess contexts (e.g., 
# from bash functions within scripts), exec.env environment variables may not be 
# properly inherited by the spawned 'aws' process, causing "Unauthorized" errors.
#
# Root Cause: 
#   - aws eks update-kubeconfig generates kubeconfig with:
#     exec:
#       command: aws
#       args: ['eks', 'get-token', ...]
#       env: [{name: AWS_PROFILE, value: admin}]
#   - kubectl spawns: aws eks get-token (AWS_PROFILE from env)
#   - In subprocess contexts, exec.env may not be inherited correctly
#
# Solution:
#   1. Generate kubeconfig with aws eks update-kubeconfig (uses exec.env)
#   2. Edit kubeconfig to move --profile from exec.env to exec.args:
#      exec:
#        command: aws
#        args: ['--profile', 'admin', 'eks', 'get-token', ...]
#        # NO exec.env section
#   - kubectl spawns: aws --profile admin eks get-token (--profile from args)
#   - Command-line arguments always work, no env inheritance needed
#
# Implementation: Uses dedicated kubeconfig file + Python3 to edit YAML

# Find Kubernetes manifests directory
find_manifests_directory() {
    local repo_root="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../../.." && pwd)}"
    
    # Try common locations
    local possible_dirs=(
        "$repo_root/infra/k8s"
        "$repo_root/infra/kubernetes"
        "$repo_root/k8s"
        "$repo_root/kubernetes"
    )
    
    for dir in "${possible_dirs[@]}"; do
        if [ -d "$dir" ]; then
            echo "$dir"
            return 0
        fi
    done
    
    return 1
}

# Generate ConfigMap and Secret from templates
generate_kubernetes_manifests() {
    local manifests_dir=$1
    # Resolve repo_root: use REPO_ROOT env var if set, otherwise resolve from script location
    local repo_root="${REPO_ROOT:-}"
    if [ -z "$repo_root" ]; then
        repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../../.." && pwd)"
    fi
    # Ensure absolute path
    if [[ "$repo_root" != /* ]]; then
        repo_root="$(cd "$repo_root" && pwd)"
    fi
    
    log_info "Generating Kubernetes manifests from templates..."
    
    # Set up directories
    local templates_dir="$manifests_dir/templates"
    local generated_dir="$manifests_dir/generated"
    
    # Clean up old generated files before generating new ones
    # This ensures generated/ always reflects the last generation run
    if [ -d "$generated_dir" ]; then
        log_info "Cleaning up previous generated manifests..."
        rm -rf "$generated_dir"
    fi
    mkdir -p "$generated_dir"
    
    # Load environment variables from .env
    if [ -f "$repo_root/run_scripts/shared/load-env.sh" ]; then
        source "$repo_root/run_scripts/shared/load-env.sh" 2>/dev/null || true
        load_env_file 2>/dev/null || true
    fi
    
    # Generate ConfigMap from template
    local configmap_template="$templates_dir/configmap.template.yaml"
    local configmap_output="$generated_dir/configmap-generated.yaml"
    
    if [ -f "$configmap_template" ]; then
        log_info "Generating ConfigMap from template..."
        if command_exists envsubst; then
            # Most variables are now exported by load-env.sh (PGUSER, AWS_REGION, AWS_BEDROCK_MODEL_ID)
            # For PGHOST, try to get from Terraform infrastructure outputs (for EKS deployments)
            # This ensures we use the Aurora endpoint instead of localhost
            # Try multiple possible paths for the Terraform infrastructure directory
            local terraform_dir=""
            local possible_paths=(
                "${repo_root}/infra/terraform/providers/aws/environments/dev/infrastructure"
                "${repo_root}/infra/terraform/environments/dev/infrastructure"
                "$(cd "$repo_root" && find . -type d -path "*/infrastructure" -name "terragrunt.hcl" -o -name "*.hcl" | head -1 | xargs dirname 2>/dev/null)"
            )
            
            for path in "${possible_paths[@]}"; do
                if [ -d "$path" ] && [ -f "$path/terragrunt.hcl" ]; then
                    terraform_dir="$path"
                    break
                fi
            done
            
            if [ -n "$terraform_dir" ] && command_exists terragrunt; then
                log_info "Fetching Aurora endpoint from Terraform infrastructure outputs..."
                log_info "Terraform directory: $terraform_dir"
                local aurora_endpoint
                # Use AWS_PROFILE if set, otherwise terragrunt will use default credentials
                local aws_profile="${AWS_PROFILE:-admin}"
                if aurora_endpoint=$(cd "$terraform_dir" && AWS_PROFILE="$aws_profile" terragrunt output -raw aurora_endpoint 2>/dev/null); then
                    if [ -n "$aurora_endpoint" ] && [ "$aurora_endpoint" != "null" ]; then
                        export PGHOST="$aurora_endpoint"
                        log_info "Using Aurora endpoint from Terraform: $PGHOST"
                    else
                        log_warning "Aurora endpoint from Terraform is empty, using PGHOST from environment or default"
                        export PGHOST="${PGHOST:-localhost}"
                    fi
                else
                    log_warning "Could not fetch Aurora endpoint from Terraform, using PGHOST from environment or default"
                    export PGHOST="${PGHOST:-localhost}"
                fi
            else
                # Fallback to environment variable or localhost
                if [ -z "$terraform_dir" ]; then
                    log_info "Terraform infrastructure directory not found, using PGHOST from environment or default"
                else
                    log_info "terragrunt not available, using PGHOST from environment or default"
                fi
                export PGHOST="${PGHOST:-localhost}"
            fi
            
            # Export all variables with defaults BEFORE envsubst (envsubst doesn't understand ${VAR:-default} syntax)
            export PGUSER="${PGUSER:-postgres}"
            export AWS_REGION="${AWS_REGION:-us-east-1}"
            export AWS_BEDROCK_INFERENCE_PROFILE_ID="${AWS_BEDROCK_INFERENCE_PROFILE_ID:-}"
            export AWS_BEDROCK_MODEL_ID="${AWS_BEDROCK_MODEL_ID:-anthropic.claude-3-haiku-20240307-v1:0}"
            export OPENAI_EMBED_MODEL="${OPENAI_EMBED_MODEL:-text-embedding-3-small}"
            export USE_AGENT_QUERY="${USE_AGENT_QUERY:-false}"
            export LOG_LEVEL="${LOG_LEVEL:-INFO}"
            export ENABLE_ANALYTICS_SCHEDULER="${ENABLE_ANALYTICS_SCHEDULER:-false}"
            export ANALYTICS_SCHEDULER_INTERVAL_SECONDS="${ANALYTICS_SCHEDULER_INTERVAL_SECONDS:-3600}"
            # Get CloudFront domain from Terraform output for CORS
            export ALLOWED_ORIGINS="${ALLOWED_ORIGINS:-https://d325mh0wy4je4e.cloudfront.net}"
            
            envsubst < "$configmap_template" > "$configmap_output"
            log_success "ConfigMap generated: configmap-generated.yaml"
        else
            log_warning "envsubst not found, using template as-is"
            cp "$configmap_template" "$configmap_output"
        fi
    fi
    
    # Generate Secret from template
    local secret_template="$templates_dir/secret.template.yaml"
    local secret_output="$generated_dir/secret-generated.yaml"
    
    if [ -f "$secret_template" ]; then
        log_info "Generating Secret from template..."
        if command_exists envsubst; then
            # Export sensitive variables for envsubst (Kubernetes Secret template)
            # Note: PGPASSWORD and OPENAI_API_KEY are now exported by load-env.sh
            # Load bedrock credentials from .env (not exported by load-env.sh for security)
            # These are used to populate Kubernetes Secret for application runtime
            if [ -f "$repo_root/.env" ]; then
                source "$repo_root/.env"
                export AWS_ACCESS_KEY_ID="${AWS_BEDROCK_ACCESS_KEY_ID:-}"
                export AWS_SECRET_ACCESS_KEY="${AWS_BEDROCK_SECRET_ACCESS_KEY:-}"
            fi
            
            envsubst < "$secret_template" > "$secret_output"
            log_success "Secret generated: secret-generated.yaml"
        else
            log_warning "envsubst not found, cannot generate secret from template"
            log_info "You'll need to create secret manually: kubectl create secret generic fru-secrets ..."
        fi
    fi
    
    # Generate Deployment from template (if CONTAINER_IMAGE is available)
    local deployment_template="$templates_dir/deployment.template.yaml"
    local deployment_output="$generated_dir/deployment-generated.yaml"
    
    if [ -f "$deployment_template" ]; then
        log_info "Generating Deployment from template..."
        if command_exists envsubst; then
            # CONTAINER_IMAGE should be set by the calling script (apply_kubernetes_manifests)
            # If not set, export empty string (will be set later in apply_kubernetes_manifests)
            export CONTAINER_IMAGE="${CONTAINER_IMAGE:-}"
            envsubst < "$deployment_template" > "$deployment_output"
            log_success "Deployment generated: deployment-generated.yaml"
        else
            log_warning "envsubst not found, using template as-is"
            cp "$deployment_template" "$deployment_output"
        fi
    fi
}

# Apply Kubernetes manifests with fail-fast error handling and verification
apply_kubernetes_manifests() {
    local manifests_dir=$1
    local repo_root="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../../.." && pwd)}"
    local dry_run="${DRY_RUN:-false}"
    
    log_step "Applying Kubernetes manifests"
    
    # Generate ConfigMap and Secret from templates first
    generate_kubernetes_manifests "$manifests_dir"
    
    # Resolve CONTAINER_IMAGE for AWS deployment
    # This ensures IMAGE_PREFIX is replaced with actual ECR URI
    if [ -f "$repo_root/run_scripts/shared/load-env.sh" ]; then
        source "$repo_root/run_scripts/shared/load-env.sh" 2>/dev/null || true
    fi
    
    if [ -z "${CONTAINER_IMAGE:-}" ]; then
        # CONTAINER_IMAGE not set: generate it (will resolve IMAGE_PREFIX to ECR URI)
        if command_exists resolve_container_image_for_aws; then
            CONTAINER_IMAGE=$(resolve_container_image_for_aws)
            export CONTAINER_IMAGE
        fi
    elif [[ "$CONTAINER_IMAGE" != *".dkr.ecr."* ]]; then
        # CONTAINER_IMAGE set but doesn't look like ECR URI: resolve it
        # This handles cases where IMAGE_PREFIX from .env is not an ECR URI
        if command_exists resolve_container_image_for_aws; then
            CONTAINER_IMAGE=$(resolve_container_image_for_aws)
            export CONTAINER_IMAGE
        fi
    fi
    
    local container_image="$CONTAINER_IMAGE"
    
    if [ -z "$container_image" ]; then
        log_warning "CONTAINER_IMAGE not set"
        log_info "Manifests will be applied without image substitution"
        log_info "Make sure your manifests reference the correct image"
    else
        log_info "Using container image: $container_image"
    fi
    
    # Generate Deployment with CONTAINER_IMAGE (if not already generated)
    local generated_dir="$manifests_dir/generated"
    local deployment_template="$manifests_dir/templates/deployment.template.yaml"
    local deployment_output="$generated_dir/deployment-generated.yaml"
    
    if [ -f "$deployment_template" ] && [ -n "$container_image" ] && [ ! -f "$deployment_output" ]; then
        log_info "Generating Deployment with container image..."
        export CONTAINER_IMAGE="$container_image"
        if command_exists envsubst; then
            envsubst < "$deployment_template" > "$deployment_output"
            log_success "Deployment generated with image: $container_image"
        else
            log_warning "envsubst not found, using sed fallback"
            sed "s|\${CONTAINER_IMAGE}|$container_image|g" "$deployment_template" > "$deployment_output"
        fi
    fi
    
    # Find YAML files: generated files first, then non-template files from root
    local yaml_files=()
    local generated_dir="$manifests_dir/generated"
    
    # Add all generated files from generated/ directory
    if [ -d "$generated_dir" ]; then
        while IFS= read -r file; do
            if [ -f "$file" ]; then
                yaml_files+=("$file")
            fi
        done < <(find "$generated_dir" -name "*.yaml" -type f | sort)
    fi
    
    # Add non-template files from root (service.yaml, ingress.yaml, etc.)
    while IFS= read -r file; do
        local basename_file
        basename_file=$(basename "$file")
        # Skip templates, generated files, Helm values files, and documentation
        if [[ "$basename_file" == "configmap.yaml" || \
              "$basename_file" == "configmap-generated.yaml" || \
              "$basename_file" == "secret.template.yaml" || \
              "$basename_file" == "secret.yaml" || \
              "$basename_file" == "secret-generated.yaml" || \
              "$basename_file" == "deployment.yaml" || \
              "$basename_file" == "deployment-generated.yaml" || \
              "$basename_file" == ".gitignore" || \
              "$basename_file" == "README.md" || \
              "$basename_file" == "ingress-nginx-values-cloud.yaml" || \
              "$basename_file" == "ingress-nginx-values-local.yaml" ]]; then
            continue
        fi
            yaml_files+=("$file")
    done < <(find "$manifests_dir" -maxdepth 1 \( -name "*.yaml" -o -name "*.yml" \) -type f | sort)
    
    if [ ${#yaml_files[@]} -eq 0 ]; then
        log_warning "No YAML files found in $manifests_dir"
        return 0
    fi
    
    log_info "Found ${#yaml_files[@]} manifest file(s): ${yaml_files[*]//$manifests_dir\//}"
    
    # Ensure AWS_PROFILE and related AWS env vars are EXPORTED for kubectl exec plugin
    # Critical: The exec plugin spawns a new 'aws' process that must inherit these
    # Note: The kubeconfig exec plugin also has AWS_PROFILE in exec.env, but explicit export ensures inheritance
    local aws_profile="${AWS_PROFILE:-admin}"
    local aws_region="${AWS_REGION:-us-east-1}"
    export AWS_PROFILE="$aws_profile"
    export AWS_REGION="$aws_region"
    export AWS_DEFAULT_REGION="$aws_region"
    export AWS_SDK_LOAD_CONFIG=1  # Ensure AWS SDK loads config file
    
    # Verify AWS credentials work (without kubectl/exec plugin)
    # NOTE: We don't check kubectl auth can-i because it has the SAME exec plugin issue as kubectl apply
    # Instead, we rely on fail-fast logic to catch kubectl apply failures
    log_info "Verifying AWS credentials (without kubectl)..."
    if aws --profile "$aws_profile" sts get-caller-identity >/dev/null 2>&1; then
        local aws_account=$(aws --profile "$aws_profile" sts get-caller-identity --query Account --output text 2>/dev/null || echo "unknown")
        log_info "AWS credentials valid (Account: $aws_account)"
    else
        log_warning "AWS credentials check failed - kubectl apply may fail"
    fi
    
    # Use dedicated kubeconfig file (isolates from default ~/.kube/config)
    # This avoids caching issues and provides clean slate for editing
    local dedicated_kubeconfig=$(mktemp)
    local original_kubeconfig="${KUBECONFIG:-}"
    export KUBECONFIG="$dedicated_kubeconfig"
    # Store cleanup values in env vars for trap access (traps run in different scope)
    export _KUBECONFIG_CLEANUP_DEDICATED="$dedicated_kubeconfig"
    export _KUBECONFIG_CLEANUP_ORIGINAL="$original_kubeconfig"
    log_info "Using dedicated kubeconfig file: $dedicated_kubeconfig"
    
    # Cleanup function to restore original KUBECONFIG and remove temp file
    cleanup_kubeconfig() {
        local cleanup_original="${_KUBECONFIG_CLEANUP_ORIGINAL:-}"
        local cleanup_dedicated="${_KUBECONFIG_CLEANUP_DEDICATED:-}"
        if [ -n "$cleanup_original" ]; then
            export KUBECONFIG="$cleanup_original"
        else
            unset KUBECONFIG
        fi
        if [ -n "$cleanup_dedicated" ] && [ -f "$cleanup_dedicated" ]; then
            rm -f "$cleanup_dedicated" 2>/dev/null || true
        fi
        unset _KUBECONFIG_CLEANUP_DEDICATED _KUBECONFIG_CLEANUP_ORIGINAL
    }
    trap cleanup_kubeconfig EXIT INT TERM
    
    # Refresh kubeconfig to ensure it's up-to-date (but don't check kubectl auth)
    # If kubectl apply fails due to auth, our fail-fast logic will catch it
    local cluster_name="${EKS_CLUSTER_NAME:-}"
    if [ -z "$cluster_name" ]; then
        # Try to get cluster name from original kubeconfig if available
        if [ -n "$original_kubeconfig" ] && [ -f "$original_kubeconfig" ]; then
            local current_context=$(KUBECONFIG="$original_kubeconfig" kubectl config current-context 2>/dev/null || echo "")
            if [[ "$current_context" == arn:aws:eks:* ]]; then
                cluster_name=$(echo "$current_context" | sed 's|arn:aws:eks:[^:]*:[^:]*:cluster/||')
            fi
        fi
        # Fallback: Try common cluster name patterns (environment-based)
        if [ -z "$cluster_name" ]; then
            local env="${ENVIRONMENT:-dev}"
            cluster_name="fru-${env}-cluster"
            log_info "Using fallback cluster name: $cluster_name"
        fi
    fi
    if [ -n "$cluster_name" ] && command_exists aws; then
        log_info "Refreshing dedicated kubeconfig for cluster: $cluster_name"
        # Generate kubeconfig with aws eks update-kubeconfig (uses exec.env by default)
        aws --profile "$aws_profile" eks update-kubeconfig --region "$aws_region" --name "$cluster_name" --kubeconfig "$dedicated_kubeconfig" >/dev/null 2>&1 || true
        
        # OPTION 2: Edit kubeconfig to move --profile from exec.env to exec.args
        # This fixes the exec.env inheritance issue by putting --profile directly in command args
        if [ -f "$dedicated_kubeconfig" ] && [ -s "$dedicated_kubeconfig" ]; then
            log_info "Editing kubeconfig to use --profile in exec.args instead of exec.env..."
            
            # Use Python to edit YAML (more robust than sed for YAML structure)
            if command_exists python3; then
                python3 <<PYTHON_SCRIPT
import yaml
import sys
import os

kubeconfig_path = "$dedicated_kubeconfig"
aws_profile = "$aws_profile"

try:
    with open(kubeconfig_path, 'r') as f:
        config = yaml.safe_load(f)
    
    # Find user with exec config
    if 'users' in config and len(config['users']) > 0:
        user = config['users'][0]
        if 'user' in user and 'exec' in user['user']:
            exec_config = user['user']['exec']
            
            # Move --profile from exec.env to exec.args
            # Check if exec.env has AWS_PROFILE
            if 'env' in exec_config:
                env_list = exec_config.get('env', [])
                for i, env_item in enumerate(env_list):
                    if isinstance(env_item, dict) and env_item.get('name') == 'AWS_PROFILE':
                        # Found AWS_PROFILE in exec.env - remove it
                        env_list.pop(i)
                        break
                
                # Remove empty env list
                if not env_list:
                    del exec_config['env']
                else:
                    exec_config['env'] = env_list
            
            # Add --profile to beginning of exec.args if not already present
            if 'args' in exec_config:
                args = exec_config['args']
                # Check if --profile is already in args
                has_profile = False
                for arg in args:
                    if arg == '--profile' or (isinstance(arg, str) and arg.startswith('--profile=')):
                        has_profile = True
                        break
                
                if not has_profile:
                    # Insert --profile and profile value at the beginning of args
                    # Insert after command name if present, otherwise at start
                    new_args = ['--profile', aws_profile]
                    new_args.extend(args)
                    exec_config['args'] = new_args
            
            # Write modified config back
            with open(kubeconfig_path, 'w') as f:
                yaml.dump(config, f, default_flow_style=False, sort_keys=False)
            
            sys.exit(0)
        else:
            sys.stderr.write("Warning: No exec config found in kubeconfig\\n")
            sys.exit(1)
    else:
        sys.stderr.write("Warning: No users found in kubeconfig\\n")
        sys.exit(1)
except Exception as e:
    sys.stderr.write(f"Error editing kubeconfig: {e}\\n")
    sys.exit(1)
PYTHON_SCRIPT
                
                if [ $? -eq 0 ]; then
                    log_info "✅ Kubeconfig edited successfully: --profile now in exec.args"
                else
                    log_warning "⚠️ Kubeconfig edit failed (Python), but continuing anyway"
                fi
            else
                # Fallback: Use sed to edit YAML (less robust but works if structure is predictable)
                log_warning "Python3 not available, attempting sed-based kubeconfig edit (may be fragile)..."
                # This is a simple sed-based approach - may break if YAML structure changes
                # Remove exec.env AWS_PROFILE line
                sed -i '' '/- name: AWS_PROFILE$/,/value: '"$aws_profile"'$/d' "$dedicated_kubeconfig" 2>/dev/null || \
                sed -i '/- name: AWS_PROFILE$/,/value: '"$aws_profile"'$/d' "$dedicated_kubeconfig" 2>/dev/null || true
                # Remove empty env: [] line if it exists
                sed -i '' '/^[[:space:]]*env:[[:space:]]*$/d' "$dedicated_kubeconfig" 2>/dev/null || \
                sed -i '/^[[:space:]]*env:[[:space:]]*$/d' "$dedicated_kubeconfig" 2>/dev/null || true
                # Add --profile to beginning of args (very fragile - assumes specific format)
                # This is a best-effort fallback - Python approach is preferred
                log_warning "Sed-based edit may not work reliably - Python3 recommended"
            fi
            
            # Verify dedicated kubeconfig is still valid after editing
            if [ -s "$dedicated_kubeconfig" ]; then
                log_info "Dedicated kubeconfig edited and ready ($(wc -l < "$dedicated_kubeconfig" | tr -d ' ') lines)"
            else
                log_warning "Dedicated kubeconfig may be invalid after editing"
            fi
        else
            log_warning "Dedicated kubeconfig file may be empty or invalid"
        fi
        
        # Re-export AWS env vars (still needed for other commands, but not for kubectl exec plugin now)
        export AWS_PROFILE="$aws_profile"
        export AWS_REGION="$aws_region"
        export AWS_DEFAULT_REGION="$aws_region"
        export AWS_SDK_LOAD_CONFIG=1
        # Brief pause to ensure kubeconfig file write completes
        sleep 0.5
    fi
    
    # Apply each manifest with fail-fast error handling and verification
    local applied_count=0
    local failed_count=0
    
    for yaml_file in "${yaml_files[@]}"; do
        local manifest_name=$(basename "$yaml_file")
        log_info "Applying: $manifest_name"
        
        if [ "$dry_run" = "true" ]; then
            # Dry-run: show what would be applied
            if [ -n "$container_image" ]; then
                if command_exists envsubst; then
                    export CONTAINER_IMAGE="$container_image"
                    envsubst < "$yaml_file" | kubectl apply --dry-run=client -f - 2>&1
                else
                    sed "s|\${CONTAINER_IMAGE}|$container_image|g; s|<CONTAINER_IMAGE>|$container_image|g" "$yaml_file" | kubectl apply --dry-run=client -f - 2>&1
                fi
            else
                kubectl apply --dry-run=client -f "$yaml_file" 2>&1
            fi
            local kubectl_exit_code=$?
            if [ $kubectl_exit_code -eq 0 ]; then
                log_info "[DRY-RUN] Would apply: $manifest_name"
                ((applied_count++))
            else
                log_error "[DRY-RUN] Failed to validate: $manifest_name (exit code: $kubectl_exit_code)"
                ((failed_count++))
                # Don't fail on dry-run, just track failures
            fi
        else
            # Actual apply - ensure AWS_PROFILE is exported for kubectl exec plugin
            export AWS_PROFILE="$aws_profile"
            
            # Prepare manifest content (substitute container image if needed)
            local temp_file=$(mktemp)
            local apply_failed=false
            local apply_error=""
            
            if [ -n "$container_image" ]; then
                # Use envsubst if available, otherwise use sed
                if command_exists envsubst; then
                    export CONTAINER_IMAGE="$container_image"
                    if ! envsubst < "$yaml_file" > "$temp_file" 2>&1; then
                        log_error "Failed to process $manifest_name with envsubst"
                        rm -f "$temp_file"
                        ((failed_count++))
                        continue
                    fi
                else
                    # Fallback to sed (simple substitution)
                    if ! sed "s|\${CONTAINER_IMAGE}|$container_image|g; s|<CONTAINER_IMAGE>|$container_image|g" "$yaml_file" > "$temp_file" 2>&1; then
                        log_error "Failed to process $manifest_name with sed"
                        rm -f "$temp_file"
                        ((failed_count++))
                        continue
                    fi
                fi
            else
                cp "$yaml_file" "$temp_file"
            fi
            
            # Extract resource kind and name from manifest for verification
            local resource_kind=$(grep -E "^kind:" "$temp_file" | head -1 | awk '{print $2}' || echo "")
            local resource_name=$(grep -E "^  name:" "$temp_file" | head -1 | awk '{print $2}' || echo "")
            local resource_namespace=$(grep -E "^  namespace:" "$temp_file" | head -1 | awk '{print $2}' || echo "default")
            
            # Try kubectl apply (without problematic pipes)
            # Ensure AWS_PROFILE is still set right before kubectl call (may have been reset)
            # NOTE: KUBECONFIG is already set to dedicated_kubeconfig from function start
            export AWS_PROFILE="$aws_profile"
            export AWS_REGION="$aws_region"
            export AWS_DEFAULT_REGION="$aws_region"
            export AWS_SDK_LOAD_CONFIG=1
            
            # Debug: Log environment right before kubectl apply to diagnose differences
            log_info "Debug: AWS_PROFILE=$AWS_PROFILE before kubectl apply for $manifest_name"
            log_info "Debug: kubectl context: $(kubectl config current-context 2>/dev/null || echo 'none')"
            log_info "Debug: temp_file path: $temp_file"
            log_info "Debug: Function sourced from: ${BASH_SOURCE[0]}"
            log_info "Debug: Script name: ${0:-N/A}"
            log_info "Debug: Parent PID: $PPID"
            log_info "Debug: Shell: $SHELL"
            log_info "Debug: AWS credentials check: $(aws sts get-caller-identity --profile "$aws_profile" --query Account --output text 2>/dev/null || echo 'failed')"
            # NOTE: We don't check kubectl auth can-i here because it has the same exec plugin issue
            # We'll just try kubectl apply directly - if it fails, fail-fast logic will catch it
            
            local kubectl_output
            local kubectl_exit_code
            
            # Use explicit AWS_PROFILE prefix as additional safeguard
            kubectl_output=$(AWS_PROFILE="$aws_profile" kubectl apply --validate=false -f "$temp_file" 2>&1)
            kubectl_exit_code=$?
            
            # Debug: Log kubectl exit code and output snippet
            log_info "Debug: kubectl apply exit code: $kubectl_exit_code for $manifest_name"
            if [ $kubectl_exit_code -ne 0 ]; then
                log_info "Debug: kubectl apply error output: $(echo "$kubectl_output" | head -5)"
            fi
            
            # Check if apply succeeded
            if [ $kubectl_exit_code -eq 0 ]; then
                # Apply succeeded - verify resource actually exists
                log_info "kubectl apply succeeded for $manifest_name"
                
                # Wait a moment for resource to be created
                sleep 0.5
                
                # Verify resource exists based on kind
                local verify_cmd=""
                case "$resource_kind" in
                    ConfigMap)
                        verify_cmd="kubectl get configmap $resource_name -n $resource_namespace >/dev/null 2>&1"
                        ;;
                    Secret)
                        verify_cmd="kubectl get secret $resource_name -n $resource_namespace >/dev/null 2>&1"
                        ;;
                    Deployment)
                        verify_cmd="kubectl get deployment $resource_name -n $resource_namespace >/dev/null 2>&1"
                        ;;
                    Service)
                        verify_cmd="kubectl get service $resource_name -n $resource_namespace >/dev/null 2>&1"
                        ;;
                    Ingress)
                        verify_cmd="kubectl get ingress $resource_name -n $resource_namespace >/dev/null 2>&1"
                        ;;
                    *)
                        # For unknown types, just check if kubectl can list them
                        verify_cmd="kubectl get $resource_kind $resource_name -n $resource_namespace >/dev/null 2>&1"
                        ;;
                esac
                
                if [ -n "$verify_cmd" ] && [ -n "$resource_name" ]; then
                    if eval "$verify_cmd"; then
                        log_success "✓ Verified: $resource_kind/$resource_name exists in namespace $resource_namespace"
                        
                        # For Deployment: Wait for pods to become ready (critical for availability)
                        if [ "$resource_kind" = "Deployment" ]; then
                            log_info "Waiting for Deployment $resource_name to become available (pods ready)..."
                            local wait_timeout="${DEPLOYMENT_WAIT_TIMEOUT:-5m}"
                            if kubectl wait --for=condition=available --timeout="$wait_timeout" "deployment/$resource_name" -n "$resource_namespace" >/dev/null 2>&1; then
                                log_success "✓ Deployment $resource_name is available (pods are ready)"
                            else
                                log_warning "⚠ Deployment $resource_name exists but pods may not be ready yet (timeout: $wait_timeout)"
                                log_info "Check pod status: kubectl get pods -l app=$resource_name -n $resource_namespace"
                                log_info "This is non-fatal - pods may still be starting"
                                # Don't fail - pods may take time to start, but resource is created
                            fi
                        fi
                        
                        # For Ingress: Optionally wait for load balancer provisioning (optional, can take 1-5 min)
                        if [ "$resource_kind" = "Ingress" ]; then
                            log_info "Ingress $resource_name created (ALB provisioning may take 1-5 minutes)..."
                            # Ingress ALB provisioning can take time - we don't wait by default
                            # User can check with: kubectl get ingress $resource_name
                            log_info "Check ALB status: kubectl get ingress $resource_name -n $resource_namespace"
                        fi
                        
                        ((applied_count++))
                    else
                        log_error "✗ FAILED: $resource_kind/$resource_name does not exist after apply"
                        log_error "kubectl apply reported success but resource verification failed"
                        log_error "kubectl output: $kubectl_output"
                        ((failed_count++))
                        apply_failed=true
                    fi
                else
                    # Can't verify (unknown type or missing name) - trust kubectl exit code
                    log_info "Applied: $manifest_name (verification skipped - unknown resource type or name)"
                    ((applied_count++))
                fi
            else
                # Apply failed - check if it's an auth error on existing resource (can use replace)
                local error_msg="$kubectl_output"
                if echo "$error_msg" | grep -qi "error when retrieving current configuration\|must be logged in" 2>/dev/null; then
                    log_warning "kubectl apply failed with auth error for existing resource, trying replace..."
                    
                    # Try replace instead
                    local replace_output
                    replace_output=$(kubectl replace --validate=false -f "$temp_file" 2>&1)
                    local replace_exit_code=$?
                    
                    if [ $replace_exit_code -eq 0 ]; then
                        # Replace succeeded - verify resource exists
                        log_success "✓ Replaced: $manifest_name using kubectl replace"
                        
                        sleep 0.5
                        
                        # Verify resource exists (same logic as above)
                        if [ -n "$verify_cmd" ] && [ -n "$resource_name" ]; then
                            if eval "$verify_cmd"; then
                                log_success "✓ Verified: $resource_kind/$resource_name exists after replace"
                                
                                # For Deployment: Wait for pods to become ready after replace
                                if [ "$resource_kind" = "Deployment" ]; then
                                    log_info "Waiting for Deployment $resource_name to become available after replace..."
                                    local wait_timeout="${DEPLOYMENT_WAIT_TIMEOUT:-5m}"
                                    if kubectl wait --for=condition=available --timeout="$wait_timeout" "deployment/$resource_name" -n "$resource_namespace" >/dev/null 2>&1; then
                                        log_success "✓ Deployment $resource_name is available (pods are ready)"
                                    else
                                        log_warning "⚠ Deployment $resource_name exists but pods may not be ready yet (timeout: $wait_timeout)"
                                        log_info "Check pod status: kubectl get pods -l app=$resource_name -n $resource_namespace"
                                        # Don't fail - pods may take time to start
                                    fi
                                fi
                                
                                ((applied_count++))
                            else
                                log_error "✗ FAILED: $resource_kind/$resource_name does not exist after replace"
                                log_error "kubectl replace reported success but resource verification failed"
                                log_error "kubectl output: $replace_output"
                                ((failed_count++))
                                apply_failed=true
                            fi
                        else
                            log_info "Replaced: $manifest_name (verification skipped)"
                            ((applied_count++))
                        fi
                    else
                        log_error "✗ FAILED: Both kubectl apply and replace failed for $manifest_name"
                        log_error "Apply error: $error_msg"
                        log_error "Replace error: $replace_output"
                        ((failed_count++))
                        apply_failed=true
                    fi
                else
                    # Apply failed for other reasons (not auth error on existing resource)
                    log_error "✗ FAILED: kubectl apply failed for $manifest_name"
                    log_error "Exit code: $kubectl_exit_code"
                    log_error "Error: $error_msg"
                    ((failed_count++))
                    apply_failed=true
                fi
            fi
            
            # Clean up temp file
            rm -f "$temp_file"
            
            # Fail fast if this manifest failed
            if [ "$apply_failed" = "true" ]; then
                log_error ""
                log_error "════════════════════════════════════════════════════════════════"
                log_error "MANIFEST APPLICATION FAILED - FAIL-FAST"
                log_error "════════════════════════════════════════════════════════════════"
                log_error "Failed to apply: $manifest_name"
                log_error "Resource: $resource_kind/$resource_name (namespace: $resource_namespace)"
                log_error ""
                log_error "Summary:"
                log_error "  - Successfully applied: $applied_count manifest(s)"
                log_error "  - Failed: $failed_count manifest(s)"
                log_error ""
                log_error "Action required:"
                log_error "  1. Review the error messages above"
                log_error "  2. Check kubectl connectivity: kubectl get nodes"
                log_error "  3. Verify authentication: kubectl auth can-i get configmaps"
                log_error "  4. Check manifest syntax: kubectl apply --dry-run=client -f $yaml_file"
                log_error ""
                return 1
            fi
        fi
    done
    
    # Final verification summary
    if [ "$dry_run" != "true" ]; then
        if [ $failed_count -eq 0 ]; then
            log_success "All ${#yaml_files[@]} manifest(s) applied and verified successfully"
            log_info "  - ConfigMaps/Secrets: Created and verified"
            log_info "  - Deployments/Services: Created and verified"
            log_info "  - Generated manifests kept in generated/ for reference"
            
            return 0
        else
            log_error ""
            log_error "════════════════════════════════════════════════════════════════"
            log_error "MANIFEST APPLICATION INCOMPLETE"
            log_error "════════════════════════════════════════════════════════════════"
            log_error "Successfully applied: $applied_count manifest(s)"
            log_error "Failed: $failed_count manifest(s)"
            log_error ""
            return 1
        fi
    else
        # Dry-run mode: return 0 if validation passed, 1 if validation failed
        log_info "[DRY-RUN] Would apply: $applied_count manifest(s)"
        if [ $failed_count -gt 0 ]; then
            log_warning "[DRY-RUN] Validation failed: $failed_count manifest(s)"
            return 1
        else
            return 0
        fi
    fi
}

# Verify deployment status
verify_kubernetes_deployment() {
    log_step "Verifying deployment status"
    
    # Check pods
    log_info "Checking pod status..."
    if kubectl get pods >/dev/null 2>&1; then
        kubectl get pods
        local pending_pods=$(kubectl get pods --field-selector=status.phase!=Running,status.phase!=Succeeded 2>/dev/null | tail -n +2 | wc -l | tr -d ' ')
        if [ "$pending_pods" -gt 0 ]; then
            log_warning "Some pods are not running yet"
            log_info "Check status with: kubectl get pods"
        else
            log_success "All pods are running"
        fi
    else
        log_warning "No pods found (may be normal if manifests don't create pods yet)"
    fi
    
    # Check services
    log_info "Checking service status..."
    if kubectl get svc >/dev/null 2>&1; then
        kubectl get svc
    else
        log_info "No services found"
    fi
    
    # Check ingress (if applicable)
    log_info "Checking ingress status..."
    if kubectl get ingress >/dev/null 2>&1; then
        kubectl get ingress
    else
        log_info "No ingress found (may be normal)"
    fi
}
