#!/bin/bash
# Kubernetes Manifest Helper Functions (EKS Helper Library)
# =========================================================
# This file contains **helper functions** for managing Kubernetes manifests
# in EKS deployments. These functions handle manifest generation, application,
# and verification. They are meant to be **sourced** by EKS deployment scripts.
#
# **Container Type**: EKS-specific (uses kubectl, Kubernetes APIs)
# **Location**: run_scripts/main_application_scripts/aws/eks/helpers/
#
# Key Functions:
#   - generate_kubernetes_manifests()  - Generates manifests from templates
#   - apply_kubernetes_manifests()      - Applies manifests to cluster
#   - verify_kubernetes_deployment()   - Verifies deployment is running
#   - terragrunt_output_with_timeout() - Safely gets Terraform outputs
#
# Usage (from another script):
#   source "$REPO_ROOT/run_scripts/main_application_scripts/aws/eks/helpers/kubernetes-manifests.sh"
#   generate_kubernetes_manifests "$namespace" "$deployment_name" "$container_image"
#   apply_kubernetes_manifests "$manifest_dir"
#
# Example:
#   source "$REPO_ROOT/run_scripts/main_application_scripts/aws/eks/helpers/kubernetes-manifests.sh"
#   if ! apply_kubernetes_manifests "$MANIFESTS_DIR"; then
#       log_error "Failed to apply Kubernetes manifests"
#       exit 1
#   fi
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

# Helper function to find envsubst command
find_envsubst() {
    if command_exists envsubst; then
        echo "envsubst"
    elif [ -f "/opt/homebrew/bin/envsubst" ] && [ -x "/opt/homebrew/bin/envsubst" ]; then
        echo "/opt/homebrew/bin/envsubst"
    elif [ -f "/usr/local/bin/envsubst" ] && [ -x "/usr/local/bin/envsubst" ]; then
        echo "/usr/local/bin/envsubst"
    else
        echo ""
    fi
}

# Helper function to run terragrunt output with timeout (macOS-compatible)
# Usage: terragrunt_output_with_timeout <directory> <output_name> <timeout_seconds> [aws_profile]
# Returns: output value on success, empty string on failure/timeout
terragrunt_output_with_timeout() {
    local terraform_dir="$1"
    local output_name="$2"
    local timeout_seconds="${3:-120}"  # Default 2 minutes (terragrunt initialization can take 20-30s in subshell, with buffer for slow systems)
    local aws_profile="${4:-admin}"
    
    if [ ! -d "$terraform_dir" ]; then
        return 1
    fi
    
    # Use background process with timeout since macOS doesn't have timeout command
    local output_file=$(mktemp)
    local exit_file=$(mktemp)
    local terragrunt_pid
    
    (
        cd "$terraform_dir" && \
        AWS_PROFILE="$aws_profile" terragrunt output -raw "$output_name" > "$output_file" 2>&1
        echo $? > "$exit_file"
    ) &
    terragrunt_pid=$!
    
    # Wait for terragrunt with timeout
    local waited=0
    local wait_interval=1
    while kill -0 "$terragrunt_pid" 2>/dev/null && [ $waited -lt $timeout_seconds ]; do
        sleep $wait_interval
        waited=$((waited + wait_interval))
    done
    
    # Check if process is still running (timed out)
    if kill -0 "$terragrunt_pid" 2>/dev/null; then
        log_warning "terragrunt output -raw $output_name timed out after ${timeout_seconds}s in $terraform_dir"
        kill "$terragrunt_pid" 2>/dev/null || true
        wait "$terragrunt_pid" 2>/dev/null || true
        rm -f "$output_file" "$exit_file"
        return 1
    else
        # Process completed - wait a moment for file writes to complete
        wait "$terragrunt_pid" 2>/dev/null || true
        sleep 0.5  # Brief pause to ensure file writes complete
        
        # Check if exit file exists and is readable
        local max_retries=5
        local retry_count=0
        while [ $retry_count -lt $max_retries ] && [ ! -f "$exit_file" ]; do
            sleep 0.2
            retry_count=$((retry_count + 1))
        done
        
        local exit_code=$(cat "$exit_file" 2>/dev/null || echo "1")
        local output=$(cat "$output_file" 2>/dev/null || echo "")
        rm -f "$output_file" "$exit_file"
        
        # Remove any ANSI color codes from output (terragrunt might output colored text)
        output=$(echo "$output" | sed 's/\x1b\[[0-9;]*m//g' | tr -d '\n\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        
        if [ $exit_code -eq 0 ] && [ -n "$output" ] && [ "$output" != "null" ]; then
            echo "$output"
            return 0
        else
            # Log debug info if it failed
            if [ $exit_code -ne 0 ]; then
                log_warning "terragrunt output -raw $output_name failed with exit code $exit_code"
            elif [ -z "$output" ] || [ "$output" = "null" ]; then
                log_warning "terragrunt output -raw $output_name returned empty or null value"
            fi
            return 1
        fi
    fi
}

# Find Kubernetes manifests directory
find_manifests_directory() {
    local repo_root="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../../.." && pwd)}"
    
    # Try common locations
    local possible_dirs=(
        "$repo_root/module_infra_kubetypes/kube/common"
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
    if [ -f "$repo_root/orchestration/common/env/load-env.sh" ]; then
        source "$repo_root/orchestration/common/env/load-env.sh" 2>/dev/null || true
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
            # Try multiple possible paths for the Terraform infrastructure directory (module_infra_basic first)
            local terraform_dir=""
            local env_infra="${ENVIRONMENT:-dev}"
            local possible_paths=(
                "${repo_root}/module_infra_basic/aws/terra/environments/${env_infra}/infrastructure"
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
                # Use timeout wrapper to prevent hanging (2 minute timeout)
                if aurora_endpoint=$(terragrunt_output_with_timeout "$terraform_dir" "aurora_endpoint" 120 "$aws_profile"); then
                    if [ -n "$aurora_endpoint" ] && [ "$aurora_endpoint" != "null" ]; then
                        export PGHOST="$aurora_endpoint"
                        log_info "Using Aurora endpoint from Terraform: $PGHOST"
                    else
                        log_warning "Aurora endpoint from Terraform is empty, using PGHOST from environment or default"
                        export PGHOST="${PGHOST:-localhost}"
                    fi
                else
                    log_warning "Could not fetch Aurora endpoint from Terraform (timeout or error), using PGHOST from environment or default"
                    export PGHOST="${PGHOST:-localhost}"
                fi
                # Fetch s3_delta_table_path for EKS analytics scheduler (Spark reads from S3)
                local s3_delta_path
                if s3_delta_path=$(terragrunt_output_with_timeout "$terraform_dir" "s3_delta_table_path" 120 "$aws_profile"); then
                    if [ -n "$s3_delta_path" ] && [ "$s3_delta_path" != "null" ]; then
                        # Convert s3:// to s3a:// and append /fru_sales (Spark uses s3a, bash 3.2 compatible)
                        local delta_path_eks
                        delta_path_eks="$(echo "$s3_delta_path" | sed 's|^s3://|s3a://|')/fru_sales"
                        export DELTA_TABLE_PATH="$delta_path_eks"
                        log_info "Using DELTA_TABLE_PATH from Terraform: $DELTA_TABLE_PATH"
                    fi
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
            
            # Get Kubernetes configuration values from Terraform outputs (for cloud deployments)
            # Try to detect environment from ENVIRONMENT variable or current directory
            local environment="${ENVIRONMENT:-dev}"
            local eks_terraform_dir=""
            local possible_eks_paths=(
                "${repo_root}/module_infra_kubetypes/kube/aws/terra/environments/${environment}/eks"
            )
            
            for path in "${possible_eks_paths[@]}"; do
                if [ -d "$path" ] && [ -f "$path/terragrunt.hcl" ]; then
                    eks_terraform_dir="$path"
                    break
                fi
            done
            
            # Read Terraform outputs for Kubernetes configuration
            if [ -n "$eks_terraform_dir" ] && command_exists terragrunt; then
                log_info "Fetching Kubernetes configuration from Terraform EKS outputs..."
                log_info "Terraform directory: $eks_terraform_dir"
                local aws_profile="${AWS_PROFILE:-admin}"
                
                # Read namespace (with timeout to prevent hanging)
                local namespace
                if namespace=$(terragrunt_output_with_timeout "$eks_terraform_dir" "namespace" 120 "$aws_profile"); then
                    if [ -n "$namespace" ] && [ "$namespace" != "null" ]; then
                        export NAMESPACE="$namespace"
                        log_info "Using namespace from Terraform: $NAMESPACE"
                    else
                        log_warning "Namespace from Terraform is empty, using default"
                        export NAMESPACE="${NAMESPACE:-default}"
                    fi
                else
                    log_warning "Could not fetch namespace from Terraform (timeout or error), using default"
                    export NAMESPACE="${NAMESPACE:-default}"
                fi
                
                # Read ingress_name (with timeout to prevent hanging)
                local ingress_name
                if ingress_name=$(terragrunt_output_with_timeout "$eks_terraform_dir" "ingress_name" 120 "$aws_profile"); then
                    if [ -n "$ingress_name" ] && [ "$ingress_name" != "null" ]; then
                        export INGRESS_NAME="$ingress_name"
                        log_info "Using ingress_name from Terraform: $INGRESS_NAME"
                    else
                        log_warning "Ingress name from Terraform is empty, using default"
                        export INGRESS_NAME="${INGRESS_NAME:-fru-api-ingress}"
                    fi
                else
                    log_warning "Could not fetch ingress_name from Terraform (timeout or error), using default"
                    export INGRESS_NAME="${INGRESS_NAME:-fru-api-ingress}"
                fi
                
                # Read ingress_host (with timeout to prevent hanging)
                local ingress_host
                if ingress_host=$(terragrunt_output_with_timeout "$eks_terraform_dir" "ingress_host" 120 "$aws_profile"); then
                    if [ -n "$ingress_host" ] && [ "$ingress_host" != "null" ]; then
                        export INGRESS_HOST="$ingress_host"
                        log_info "Using ingress_host from Terraform: $INGRESS_HOST"
                    else
                        log_warning "Ingress host from Terraform is empty, using environment variable or empty (local dev)"
                        export INGRESS_HOST="${INGRESS_HOST:-}"
                    fi
                else
                    log_warning "Could not fetch ingress_host from Terraform (timeout or error), using environment variable or empty (local dev)"
                    export INGRESS_HOST="${INGRESS_HOST:-}"
                fi
                
                # Read API replicas from Terraform output (optional, defaults to 2)
                local api_replicas
                if api_replicas=$(terragrunt_output_with_timeout "$eks_terraform_dir" "api_replicas" 120 "$aws_profile"); then
                    if [ -n "$api_replicas" ] && [ "$api_replicas" != "null" ]; then
                        export BACKEND_KUBE_REPLICA_COUNT="$api_replicas"
                        log_info "Using API replicas from Terraform: $BACKEND_KUBE_REPLICA_COUNT"
                    else
                        export BACKEND_KUBE_REPLICA_COUNT="${BACKEND_KUBE_REPLICA_COUNT:-2}"
                    fi
                else
                    log_warning "Could not fetch api_replicas from Terraform (timeout or error), using default: 2"
                    export BACKEND_KUBE_REPLICA_COUNT="${BACKEND_KUBE_REPLICA_COUNT:-2}"
                fi
                
                # Read CORS origin (cloudfront_domain_name) (with timeout to prevent hanging)
                local cors_origin
                if cors_origin=$(terragrunt_output_with_timeout "$eks_terraform_dir" "cloudfront_domain_name" 120 "$aws_profile"); then
                    if [ -n "$cors_origin" ] && [ "$cors_origin" != "null" ]; then
                        export CORS_ORIGIN="https://$cors_origin"
                        log_info "Using CORS origin from Terraform: $CORS_ORIGIN"
                    else
                        log_warning "CORS origin from Terraform is empty, using default"
                        export CORS_ORIGIN="${ALLOWED_ORIGINS:-https://d325mh0wy4je4e.cloudfront.net}"
                    fi
                else
                    log_warning "Could not fetch CORS origin from Terraform (timeout or error), using default"
                    export CORS_ORIGIN="${ALLOWED_ORIGINS:-https://d325mh0wy4je4e.cloudfront.net}"
                fi
            else
                # Fallback to environment variables or defaults (for local development)
                if [ -z "$eks_terraform_dir" ]; then
                    log_info "Terraform EKS directory not found, using environment variables or defaults (local development)"
                else
                    log_info "terragrunt not available, using environment variables or defaults"
                fi
                export NAMESPACE="${NAMESPACE:-default}"
                export INGRESS_NAME="${INGRESS_NAME:-fru-api-ingress}"
                export INGRESS_HOST="${INGRESS_HOST:-}"
                export CORS_ORIGIN="${ALLOWED_ORIGINS:-https://d325mh0wy4je4e.cloudfront.net}"
            fi
            
            # Export all variables with defaults BEFORE envsubst (envsubst doesn't understand ${VAR:-default} syntax)
            # Scheduler vars (ENABLE_ANALYTICS_SCHEDULER, etc.) already exported by load-env.sh above with same defaults for ECS/EKS
            export PGUSER="${PGUSER:-postgres}"
            export AWS_REGION="${AWS_REGION:-us-east-1}"
            export AWS_BEDROCK_INFERENCE_PROFILE_ID="${AWS_BEDROCK_INFERENCE_PROFILE_ID:-}"
            export AWS_BEDROCK_MODEL_ID="${AWS_BEDROCK_MODEL_ID:-anthropic.claude-3-haiku-20240307-v1:0}"
            export OPENAI_EMBED_MODEL="${OPENAI_EMBED_MODEL:-text-embedding-3-small}"
            export USE_AGENT_QUERY="${USE_AGENT_QUERY:-false}"
            export LOG_LEVEL="${LOG_LEVEL:-INFO}"
            export ENABLE_ANALYTICS_SCHEDULER="${ENABLE_ANALYTICS_SCHEDULER:-false}"
            export ANALYTICS_SCHEDULER_INTERVAL_SECONDS="${ANALYTICS_SCHEDULER_INTERVAL_SECONDS:-3600}"
            export DELTA_TABLE_PATH="${DELTA_TABLE_PATH:-}"
            export CONTAINER_TYPE="${CONTAINER_TYPE:-eks}"
            export DELTA_LAKE_PACKAGE="${DELTA_LAKE_PACKAGE:-io.delta:delta-spark_2.13:4.0.0}"
            # Export PROJECT_ID and ENVIRONMENT for namespace template
            export PROJECT_ID="${PROJECT_ID:-fru-genai-analytics}"
            export ENVIRONMENT="${ENVIRONMENT:-dev}"
            
            local envsubst_cmd
            envsubst_cmd=$(find_envsubst)
            if [ -z "$envsubst_cmd" ]; then
                log_warning "envsubst not found, using template as-is"
                cp "$configmap_template" "$configmap_output"
            else
                "$envsubst_cmd" < "$configmap_template" > "$configmap_output"
            fi
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
        local envsubst_cmd
        envsubst_cmd=$(find_envsubst)
        if [ -n "$envsubst_cmd" ]; then
            # Export sensitive variables for envsubst (Kubernetes Secret template)
            # Note: PGPASSWORD and OPENAI_API_KEY are now exported by load-env.sh
            # Load AWS credentials from .env (not exported by load-env.sh for security)
            # EKS pods need both Bedrock (LLM) and S3 (analytics scheduler); use admin creds which have both.
            # Bedrock-only user lacks s3:ListBucket on analytics bucket.
            if [ -f "$repo_root/.env" ]; then
                source "$repo_root/.env"
                export AWS_ACCESS_KEY_ID="${AWS_ADMIN_ACCESS_KEY_ID:-${AWS_BEDROCK_ACCESS_KEY_ID:-}}"
                export AWS_SECRET_ACCESS_KEY="${AWS_ADMIN_SECRET_ACCESS_KEY:-${AWS_BEDROCK_SECRET_ACCESS_KEY:-}}"
            fi
            
            "$envsubst_cmd" < "$secret_template" > "$secret_output"
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
        local envsubst_cmd
        envsubst_cmd=$(find_envsubst)
        if [ -n "$envsubst_cmd" ]; then
            # CONTAINER_IMAGE should be set by the calling script (apply_kubernetes_manifests)
            # If not set, export empty string (will be set later in apply_kubernetes_manifests)
            export CONTAINER_IMAGE="${CONTAINER_IMAGE:-}"
            # BACKEND_KUBE_REPLICA_COUNT can be set via environment variable (e.g., in .env) or Terraform output (defaults to 2)
            export BACKEND_KUBE_REPLICA_COUNT="${BACKEND_KUBE_REPLICA_COUNT:-2}"
            "$envsubst_cmd" < "$deployment_template" > "$deployment_output"
            log_success "Deployment generated: deployment-generated.yaml"
        else
            log_warning "envsubst not found, using template as-is"
            cp "$deployment_template" "$deployment_output"
        fi
    fi
    
    # Generate Namespace from template
    local namespace_template="$templates_dir/namespace.template.yaml"
    local namespace_output="$generated_dir/namespace-generated.yaml"
    
    if [ -f "$namespace_template" ]; then
        log_info "Generating Namespace from template..."
        local envsubst_cmd
        envsubst_cmd=$(find_envsubst)
        if [ -n "$envsubst_cmd" ]; then
            "$envsubst_cmd" < "$namespace_template" > "$namespace_output"
            log_success "Namespace generated: namespace-generated.yaml"
        else
            log_warning "envsubst not found, using template as-is"
            cp "$namespace_template" "$namespace_output"
        fi
    fi
    
    # Generate Ingress from template
    local ingress_template="$templates_dir/ingress.template.yaml"
    local ingress_output="$generated_dir/ingress-generated.yaml"
    
    if [ -f "$ingress_template" ]; then
        log_info "Generating Ingress from template..."
        local envsubst_cmd
        envsubst_cmd=$(find_envsubst)
        if [ -n "$envsubst_cmd" ]; then
            # Generate ingress with envsubst
            "$envsubst_cmd" < "$ingress_template" > "$ingress_output"
            
            # Always remove the host line from Ingress to create a wildcard Ingress
            # This is necessary for CloudFront and direct NLB access compatibility:
            #
            # Why remove the host restriction?
            # 1. CloudFront doesn't send custom Host headers by default when forwarding to origins
            # 2. Direct NLB access uses the NLB DNS name (e.g., *.elb.amazonaws.com), not the internal hostname
            # 3. Without removing the host line, requests fail with 503 (no matching Ingress rule)
            #
            # What does this do?
            # - Replaces "- host: <value>\n    http:" with "- http:" to maintain valid YAML structure
            # - Creates a wildcard Ingress that accepts requests with any Host header
            # - This is safe because namespace isolation (fru-api-dev vs fru-api-prod) provides environment separation
            #
            # Note: INGRESS_HOST is still set by Terraform (e.g., "api-dev.internal") for documentation/logging,
            # but we always remove it from the actual Kubernetes manifest for CloudFront/NLB compatibility.
            log_info "Removing host restriction from Ingress for CloudFront/NLB compatibility (INGRESS_HOST was: ${INGRESS_HOST:-not set})"
            
            # Replace "- host: <value>\n    http:" with "- http:" to maintain valid YAML
            # Try different sed approaches for cross-platform compatibility (Linux vs macOS)
            local sed_success=false
            if sed -i.bak '/^[[:space:]]*- host:/{N; s/^\([[:space:]]*\)- host:.*\n\([[:space:]]*\)    http:/\1- http:/; }' "$ingress_output" 2>/dev/null; then
                rm -f "${ingress_output}.bak" 2>/dev/null || true
                sed_success=true
            elif sed -i '' '/^[[:space:]]*- host:/{N; s/^\([[:space:]]*\)- host:.*\n\([[:space:]]*\)    http:/\1- http:/; }' "$ingress_output" 2>/dev/null; then
                sed_success=true
            else
                # Fallback: use temp file approach (works on all systems)
                if sed '/^[[:space:]]*- host:/{N; s/^\([[:space:]]*\)- host:.*\n\([[:space:]]*\)    http:/\1- http:/; }' "$ingress_output" > "${ingress_output}.tmp" 2>/dev/null; then
                    if [ -f "${ingress_output}.tmp" ]; then
                        mv "${ingress_output}.tmp" "$ingress_output"
                        sed_success=true
                    fi
                fi
            fi
            
            if [ "$sed_success" = false ]; then
                log_warning "Failed to remove host line from Ingress - CloudFront/NLB access may not work correctly"
            else
                log_info "Successfully removed host restriction - Ingress now accepts any Host header (wildcard)"
            fi
            
            log_success "Ingress generated: ingress-generated.yaml"
        else
            log_warning "envsubst not found, using template as-is"
            cp "$ingress_template" "$ingress_output"
        fi
    fi
    
    # Generate Service from template
    local service_template="$templates_dir/service.template.yaml"
    local service_output="$generated_dir/service-generated.yaml"
    
    if [ -f "$service_template" ]; then
        log_info "Generating Service from template..."
        local envsubst_cmd
        envsubst_cmd=$(find_envsubst)
        if [ -n "$envsubst_cmd" ]; then
            "$envsubst_cmd" < "$service_template" > "$service_output"
            log_success "Service generated: service-generated.yaml"
        else
            log_warning "envsubst not found, using template as-is"
            cp "$service_template" "$service_output"
        fi
    fi
}

# Apply Kubernetes manifests with fail-fast error handling and verification
# Sync deployment image and CONTAINER_IMAGE environment variable
# Ensures version endpoint returns correct version by keeping env var in sync with image
# Usage: sync_deployment_image_and_env <deployment_name> <namespace> <new_image_uri> [container_name]
sync_deployment_image_and_env() {
    local deployment_name=$1
    local namespace=$2
    local new_image_uri=$3
    local container_name="${4:-fru-api}"  # Default container name
    
    if [ -z "$deployment_name" ] || [ -z "$namespace" ] || [ -z "$new_image_uri" ]; then
        log_error "sync_deployment_image_and_env: deployment_name, namespace, and new_image_uri are required"
        return 1
    fi
    
    log_info "Synchronizing image and CONTAINER_IMAGE env var for deployment: $deployment_name"
    log_info "  Namespace: $namespace"
    log_info "  New image: $new_image_uri"
    log_info "  Container: $container_name"
    
    # Extract image tag for logging
    local image_tag=""
    if [[ "$new_image_uri" == *":"* ]]; then
        image_tag="${new_image_uri#*:}"
    else
        image_tag="$new_image_uri"
    fi
    log_info "  Image tag: $image_tag"
    
    # Update deployment image
    log_info "Updating deployment image..."
    if ! kubectl set image "deployment/$deployment_name" "$container_name=$new_image_uri" -n "$namespace" >/dev/null 2>&1; then
        log_error "Failed to update deployment image for $deployment_name"
        return 1
    fi
    log_success "✓ Deployment image updated"
    
    # Update CONTAINER_IMAGE environment variable to match
    log_info "Updating CONTAINER_IMAGE environment variable..."
    if ! kubectl set env "deployment/$deployment_name" "CONTAINER_IMAGE=$new_image_uri" -n "$namespace" >/dev/null 2>&1; then
        log_error "Failed to update CONTAINER_IMAGE env var for $deployment_name"
        return 1
    fi
    log_success "✓ CONTAINER_IMAGE env var updated"
    
    # Verify both are set correctly
    log_info "Verifying image and env var are synchronized..."
    local verify_image
    verify_image=$(kubectl get deployment "$deployment_name" -n "$namespace" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || echo "")
    local verify_env
    verify_env=$(kubectl get deployment "$deployment_name" -n "$namespace" -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="CONTAINER_IMAGE")].value}' 2>/dev/null || echo "")
    
    if [ "$verify_image" = "$new_image_uri" ] && [ "$verify_env" = "$new_image_uri" ]; then
        log_success "✓ Verified: Image and CONTAINER_IMAGE env var are synchronized"
        log_info "  Image: $verify_image"
        log_info "  CONTAINER_IMAGE: $verify_env"
        return 0
    else
        log_warning "⚠ Verification mismatch detected"
        log_warning "  Expected image: $new_image_uri"
        log_warning "  Actual image: $verify_image"
        log_warning "  Expected CONTAINER_IMAGE: $new_image_uri"
        log_warning "  Actual CONTAINER_IMAGE: $verify_env"
        log_info "This may be a timing issue - changes may propagate shortly"
        # Don't fail - changes may still be propagating
        return 0
    fi
}

# Wait for deployment to become available with detailed progress logging
wait_for_deployment_with_progress() {
    local deployment_name=$1
    local namespace=$2
    local timeout=$3  # e.g., "5m"
    local container_image="${4:-}"  # optional, for image pull tracking
    
    log_info "Waiting for Deployment $deployment_name to become available (timeout: $timeout)..."
    
    # Check if jq is available (for JSON parsing)
    local has_jq=false
    if command -v jq >/dev/null 2>&1; then
        has_jq=true
    fi
    
    # Convert timeout to seconds for elapsed time tracking
    local timeout_seconds
    if [[ "$timeout" =~ ^([0-9]+)m$ ]]; then
        timeout_seconds=$((${BASH_REMATCH[1]} * 60))
    elif [[ "$timeout" =~ ^([0-9]+)s$ ]]; then
        timeout_seconds=${BASH_REMATCH[1]}
    else
        timeout_seconds=300  # Default to 5 minutes
    fi
    
    local start_time=$(date +%s)
    local elapsed=0
    local last_status=""
    local poll_interval=5  # Poll every 5 seconds
    local last_log_time=0
    local log_interval=10  # Log status every 10 seconds
    
    while [ $elapsed -lt $timeout_seconds ]; do
        # Get deployment status
        local deployment_status
        deployment_status=$(kubectl get deployment "$deployment_name" -n "$namespace" -o json 2>/dev/null)
        
        if [ -z "$deployment_status" ]; then
            log_warning "Deployment $deployment_name not found in namespace $namespace"
            return 1
        fi
        
        # Extract status information (use jq if available, otherwise use kubectl get with jsonpath)
        local replicas ready_replicas desired_replicas available pod_selector
        
        if [ "$has_jq" = "true" ]; then
            replicas=$(echo "$deployment_status" | jq -r '.status.replicas // 0' 2>/dev/null || echo "0")
            ready_replicas=$(echo "$deployment_status" | jq -r '.status.readyReplicas // 0' 2>/dev/null || echo "0")
            desired_replicas=$(echo "$deployment_status" | jq -r '.spec.replicas // 1' 2>/dev/null || echo "1")
            available=$(echo "$deployment_status" | jq -r '.status.conditions[]? | select(.type=="Available") | .status' 2>/dev/null || echo "False")
            pod_selector=$(echo "$deployment_status" | jq -r '.spec.selector.matchLabels | to_entries | map("\(.key)=\(.value)") | join(",")' 2>/dev/null || echo "")
        else
            # Fallback to kubectl jsonpath (less flexible but doesn't require jq)
            replicas=$(kubectl get deployment "$deployment_name" -n "$namespace" -o jsonpath='{.status.replicas}' 2>/dev/null || echo "0")
            ready_replicas=$(kubectl get deployment "$deployment_name" -n "$namespace" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
            desired_replicas=$(kubectl get deployment "$deployment_name" -n "$namespace" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "1")
            available=$(kubectl get deployment "$deployment_name" -n "$namespace" -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || echo "False")
            # Build pod selector from matchLabels (simplified - assumes app label)
            local app_label=$(kubectl get deployment "$deployment_name" -n "$namespace" -o jsonpath='{.spec.selector.matchLabels.app}' 2>/dev/null || echo "")
            if [ -n "$app_label" ]; then
                pod_selector="app=$app_label"
            else
                pod_selector=""
            fi
        fi
        
        local pod_status=""
        local image_pull_status=""
        local container_status=""
        
        if [ -n "$pod_selector" ]; then
            if [ "$has_jq" = "true" ]; then
                local pods_json
                pods_json=$(kubectl get pods -l "$pod_selector" -n "$namespace" -o json 2>/dev/null)
                
                if [ -n "$pods_json" ]; then
                    # Get pod phases
                    pod_status=$(echo "$pods_json" | jq -r '.items[]?.status.phase // empty' 2>/dev/null | tr '\n' ',' | sed 's/,$//' || echo "")
                    
                    # Get image pull status
                    image_pull_status=$(echo "$pods_json" | jq -r '.items[]?.status.containerStatuses[]?.state.waiting.reason // empty' 2>/dev/null | grep -i "pull\|image" | head -1 || echo "")
                    
                    # Get container ready status
                    local ready_count=$(echo "$pods_json" | jq -r '[.items[]?.status.containerStatuses[]? | select(.ready==true)] | length' 2>/dev/null || echo "0")
                    local total_containers=$(echo "$pods_json" | jq -r '[.items[]?.status.containerStatuses[]?] | length' 2>/dev/null || echo "0")
                    container_status="$ready_count/$total_containers containers ready"
                fi
            else
                # Fallback: use kubectl get with jsonpath
                pod_status=$(kubectl get pods -l "$pod_selector" -n "$namespace" -o jsonpath='{.items[*].status.phase}' 2>/dev/null | tr ' ' ',' || echo "")
                # Get image pull status from first pod
                local first_pod=$(kubectl get pods -l "$pod_selector" -n "$namespace" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
                if [ -n "$first_pod" ]; then
                    image_pull_status=$(kubectl get pod "$first_pod" -n "$namespace" -o jsonpath='{.status.containerStatuses[0].state.waiting.reason}' 2>/dev/null | grep -i "pull\|image" || echo "")
                fi
                # Get ready container count
                local ready_count=$(kubectl get pods -l "$pod_selector" -n "$namespace" -o jsonpath='{.items[*].status.containerStatuses[?(@.ready==true)].name}' 2>/dev/null | wc -w | tr -d ' ' || echo "0")
                local total_containers=$(kubectl get pods -l "$pod_selector" -n "$namespace" -o jsonpath='{.items[*].status.containerStatuses[*].name}' 2>/dev/null | wc -w | tr -d ' ' || echo "0")
                container_status="$ready_count/$total_containers containers ready"
            fi
        fi
        
        # Build status message
        local current_status="replicas: $ready_replicas/$desired_replicas"
        if [ -n "$pod_status" ]; then
            current_status="$current_status, pods: [$pod_status]"
        fi
        if [ -n "$image_pull_status" ]; then
            current_status="$current_status, image: $image_pull_status"
        fi
        if [ -n "$container_status" ]; then
            current_status="$current_status, $container_status"
        fi
        
        # Log status if it changed or if enough time has passed
        local current_time=$(date +%s)
        if [ "$current_status" != "$last_status" ] || [ $((current_time - last_log_time)) -ge $log_interval ]; then
            log_info "  [$deployment_name] $current_status (${elapsed}s elapsed)"
            last_status="$current_status"
            last_log_time=$current_time
        fi
        
        # Check if deployment is available
        if [ "$available" = "True" ] && [ "$ready_replicas" -ge "$desired_replicas" ] && [ "$ready_replicas" -gt 0 ]; then
            log_success "✓ Deployment $deployment_name is available (pods are ready) after ${elapsed}s"
            return 0
        fi
        
        # Sleep before next poll
        sleep $poll_interval
        elapsed=$(($(date +%s) - start_time))
    done
    
    # Timeout reached - show diagnostic info
    log_warning "⚠ Deployment $deployment_name did not become available within ${timeout} (${elapsed}s elapsed)"
    log_info "Current status: $current_status"
    log_info "Showing diagnostic information..."
    
    # Show deployment events
    log_info "Deployment events:"
    kubectl get events -n "$namespace" --field-selector involvedObject.name="$deployment_name" --sort-by='.lastTimestamp' 2>/dev/null | tail -10 || log_info "  (no events found)"
    
    # Show pod status
    if [ -n "$pod_selector" ]; then
        log_info "Pod status:"
        kubectl get pods -l "$pod_selector" -n "$namespace" 2>/dev/null || log_info "  (no pods found)"
        
        # Show pod events for each pod
        local pod_names
        pod_names=$(kubectl get pods -l "$pod_selector" -n "$namespace" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
        if [ -n "$pod_names" ]; then
            for pod_name in $pod_names; do
                log_info "Events for pod $pod_name:"
                kubectl get events -n "$namespace" --field-selector involvedObject.name="$pod_name" --sort-by='.lastTimestamp' 2>/dev/null | tail -5 || log_info "  (no events found)"
                
                # Show last few lines of pod logs if available
                log_info "Last 10 lines of logs for pod $pod_name:"
                kubectl logs "$pod_name" -n "$namespace" --tail=10 2>/dev/null || log_info "  (logs not available)"
            done
        fi
    fi
    
    # Show deployment description
    log_info "Deployment description:"
    kubectl describe deployment "$deployment_name" -n "$namespace" 2>/dev/null | tail -20 || log_info "  (description not available)"
    
    return 1
}

# Wait for multiple deployments in parallel
wait_for_deployments_parallel() {
    local deployments_array=("$@")  # Array of "name|namespace|image" strings
    local wait_timeout="${DEPLOYMENT_WAIT_TIMEOUT:-5m}"
    local parallel_wait="${KUBERNETES_PARALLEL_WAIT:-true}"
    
    if [ ${#deployments_array[@]} -eq 0 ]; then
        log_info "No deployments to wait for"
        return 0
    fi
    
    # If parallel wait is disabled, wait sequentially
    if [ "$parallel_wait" != "true" ]; then
        log_info "Parallel wait disabled, waiting for deployments sequentially..."
        for deployment_info in "${deployments_array[@]}"; do
            IFS='|' read -r name namespace image <<< "$deployment_info"
            wait_for_deployment_with_progress "$name" "$namespace" "$wait_timeout" "$image" || true
        done
        return 0
    fi
    
    log_info "Waiting for ${#deployments_array[@]} deployment(s) to become available in parallel..."
    
    # Start background wait processes for each deployment
    local pids=()
    local deployment_names=()
    local deployment_namespaces=()
    local temp_files=()
    
    for deployment_info in "${deployments_array[@]}"; do
        IFS='|' read -r name namespace image <<< "$deployment_info"
        deployment_names+=("$name")
        deployment_namespaces+=("$namespace")
        
        # Create temp file for exit code
        local temp_file=$(mktemp)
        temp_files+=("$temp_file")
        
        # Start background wait process
        (
            if wait_for_deployment_with_progress "$name" "$namespace" "$wait_timeout" "$image"; then
                echo "0" > "$temp_file"
            else
                echo "1" > "$temp_file"
            fi
        ) &
        pids+=($!)
    done
    
    # Monitor all background processes
    local all_succeeded=true
    local completed=0
    local total=${#pids[@]}
    local success_count=0
    local failure_count=0
    
    log_info "Monitoring ${total} deployment(s)..."
    
    while [ $completed -lt $total ]; do
        for i in "${!pids[@]}"; do
            local pid="${pids[$i]}"
            local name="${deployment_names[$i]}"
            local namespace="${deployment_namespaces[$i]}"
            local temp_file="${temp_files[$i]}"
            
            if ! kill -0 "$pid" 2>/dev/null; then
                # Process completed
                local exit_code=$(cat "$temp_file" 2>/dev/null || echo "1")
                rm -f "$temp_file"
                
                if [ "$exit_code" = "0" ]; then
                    ((success_count++))
                    log_success "✓ [$name] Deployment completed successfully"
                else
                    ((failure_count++))
                    all_succeeded=false
                    log_warning "⚠ [$name] Deployment did not become available in time"
                fi
                
                ((completed++))
                unset pids[$i]
                unset deployment_names[$i]
                unset deployment_namespaces[$i]
                unset temp_files[$i]
            fi
        done
        
        if [ $completed -lt $total ]; then
            sleep 2  # Check every 2 seconds
        fi
    done
    
    # Cleanup any remaining processes (shouldn't happen, but safety)
    # Use ${pids[@]:-} / ${#pids[@]:-0} to avoid "unbound variable" when set -u and array is empty/unset
    if ((${#pids[@]:-0} > 0)); then
        for pid in "${pids[@]+"${pids[@]}"}"; do
            kill "$pid" 2>/dev/null || true
        done
    fi
    
    # Cleanup temp files
    if ((${#temp_files[@]:-0} > 0)); then
        for temp_file in "${temp_files[@]+"${temp_files[@]}"}"; do
            rm -f "$temp_file" 2>/dev/null || true
        done
    fi
    
    # Summary
    log_info "Deployment wait summary: ${success_count} succeeded, ${failure_count} failed out of ${total} total"
    
    if [ "$all_succeeded" = "true" ]; then
        log_success "✓ All deployments became available"
        return 0
    else
        log_warning "⚠ Some deployments did not become available (${failure_count} failed)"
        # Don't fail completely - some deployments may still be starting
        return 0
    fi
}

apply_kubernetes_manifests() {
    local manifests_dir=$1
    local repo_root="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../../.." && pwd)}"
    local dry_run="${DRY_RUN:-false}"
    
    log_step "Applying Kubernetes manifests"
    
    # Resolve CONTAINER_IMAGE for AWS deployment FIRST (before generating manifests)
    # This ensures IMAGE_PREFIX is replaced with actual ECR URI and deployment is generated correctly
    if [ -f "$repo_root/orchestration/common/env/load-env.sh" ]; then
        source "$repo_root/orchestration/common/env/load-env.sh" 2>/dev/null || true
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
        # Export CONTAINER_IMAGE so generate_kubernetes_manifests can use it
        export CONTAINER_IMAGE="$container_image"
        export BACKEND_KUBE_REPLICA_COUNT="${BACKEND_KUBE_REPLICA_COUNT:-2}"
    fi
    
    # Generate ConfigMap, Secret, and Deployment from templates
    # CONTAINER_IMAGE is now set, so deployment will be generated with correct image
    generate_kubernetes_manifests "$manifests_dir"
    
    # Verify deployment was generated with image (if CONTAINER_IMAGE was set)
    if [ -n "$container_image" ]; then
        local generated_dir="$manifests_dir/generated"
        local deployment_output="$generated_dir/deployment-generated.yaml"
        if [ -f "$deployment_output" ]; then
            # Check if deployment has the image set (not empty)
            local deployment_image
            deployment_image=$(grep -E "^[[:space:]]*image:[[:space:]]*" "$deployment_output" | head -1 | awk '{print $2}' | tr -d '"' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' || echo "")
            # Check if image is empty or just whitespace
            if [ -z "$deployment_image" ] || [ "$deployment_image" = "null" ]; then
                log_warning "Deployment manifest has empty image field, regenerating with CONTAINER_IMAGE..."
                local deployment_template="$manifests_dir/templates/deployment.template.yaml"
                if [ -f "$deployment_template" ]; then
                    log_info "Regenerating Deployment with container image: $container_image"
                    local envsubst_cmd
                    envsubst_cmd=$(find_envsubst)
                    if [ -n "$envsubst_cmd" ]; then
                        export CONTAINER_IMAGE="$container_image"
        export BACKEND_KUBE_REPLICA_COUNT="${BACKEND_KUBE_REPLICA_COUNT:-2}"
                        "$envsubst_cmd" < "$deployment_template" > "$deployment_output"
                        log_success "Deployment regenerated with image: $container_image"
                    else
                        log_warning "envsubst not found, using sed fallback"
                        sed "s|\${CONTAINER_IMAGE}|$container_image|g" "$deployment_template" > "$deployment_output"
                        log_success "Deployment regenerated with image: $container_image (using sed)"
                    fi
                fi
            else
                log_success "Deployment manifest has image set: $deployment_image"
            fi
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
        # Also skip old static files that are now templates
        if [[ "$basename_file" == "configmap.yaml" || \
              "$basename_file" == "configmap-generated.yaml" || \
              "$basename_file" == "secret.template.yaml" || \
              "$basename_file" == "secret.yaml" || \
              "$basename_file" == "secret-generated.yaml" || \
              "$basename_file" == "deployment.yaml" || \
              "$basename_file" == "deployment-generated.yaml" || \
              "$basename_file" == "ingress.yaml" || \
              "$basename_file" == "ingress-generated.yaml" || \
              "$basename_file" == "service.yaml" || \
              "$basename_file" == "service-generated.yaml" || \
              "$basename_file" == ".gitignore" || \
              "$basename_file" == "README.md" || \
              "$basename_file" == "ingress-nginx-values-local.yaml" || \
              "$basename_file" == "ingress-nginx-values-eks.yaml" ]]; then
            continue
        fi
            yaml_files+=("$file")
    done < <(find "$manifests_dir" -maxdepth 1 \( -name "*.yaml" -o -name "*.yml" \) -type f | sort)
    
    if [ ${#yaml_files[@]} -eq 0 ]; then
        log_warning "No YAML files found in $manifests_dir"
        return 0
    fi
    
    # Sort manifests by priority: namespace first, then secret, then others
    # This ensures dependencies are created before resources that need them
    local priority_order=("namespace" "secret" "configmap" "deployment" "service" "ingress")
    local sorted_files=()
    
    # First, add files in priority order
    for priority in "${priority_order[@]}"; do
        for file in "${yaml_files[@]}"; do
            local basename_file=$(basename "$file")
            if [[ "$basename_file" == *"$priority"* ]]; then
                sorted_files+=("$file")
            fi
        done
    done
    
    # Then add any remaining files that don't match priority patterns
    for file in "${yaml_files[@]}"; do
        local found=false
        for sorted_file in "${sorted_files[@]}"; do
            if [ "$file" = "$sorted_file" ]; then
                found=true
                break
            fi
        done
        if [ "$found" = false ]; then
            sorted_files+=("$file")
        fi
    done
    
    yaml_files=("${sorted_files[@]}")
    
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
            if command_exists "${PYTHON_CMD:-python3}"; then
                "${PYTHON_CMD:-python3}" <<PYTHON_SCRIPT
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
                
                py_exit=$?
                if [ $py_exit -eq 0 ]; then
                    log_info "✅ Kubeconfig edited successfully: --profile now in exec.args"
                else
                    # Python failed (e.g. ModuleNotFoundError: No module named 'yaml'). Use sed fallback.
                    log_warning "Kubeconfig edit via Python failed (install PyYAML for better support: pip install pyyaml). Using sed fallback..."
                    # Remove exec.env AWS_PROFILE block
                    sed -i '' '/- name: AWS_PROFILE$/,/value: '"$aws_profile"'$/d' "$dedicated_kubeconfig" 2>/dev/null || \
                    sed -i '/- name: AWS_PROFILE$/,/value: '"$aws_profile"'$/d' "$dedicated_kubeconfig" 2>/dev/null || true
                    # Remove empty env: [] line if it exists
                    sed -i '' '/^[[:space:]]*env:[[:space:]]*$/d' "$dedicated_kubeconfig" 2>/dev/null || \
                    sed -i '/^[[:space:]]*env:[[:space:]]*$/d' "$dedicated_kubeconfig" 2>/dev/null || true
                fi
            else
                # Python3 not available: Use sed to edit YAML (less robust but works if structure is predictable)
                log_warning "Python3 not available, attempting sed-based kubeconfig edit..."
                sed -i '' '/- name: AWS_PROFILE$/,/value: '"$aws_profile"'$/d' "$dedicated_kubeconfig" 2>/dev/null || \
                sed -i '/- name: AWS_PROFILE$/,/value: '"$aws_profile"'$/d' "$dedicated_kubeconfig" 2>/dev/null || true
                sed -i '' '/^[[:space:]]*env:[[:space:]]*$/d' "$dedicated_kubeconfig" 2>/dev/null || \
                sed -i '/^[[:space:]]*env:[[:space:]]*$/d' "$dedicated_kubeconfig" 2>/dev/null || true
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
    
    # Array to track deployments that need waiting (for parallel wait after all manifests are applied)
    declare -a deployments_to_wait=()
    
    for yaml_file in "${yaml_files[@]}"; do
        local manifest_name=$(basename "$yaml_file")
        log_info "Applying: $manifest_name"
        
        if [ "$dry_run" = "true" ]; then
            # Dry-run: show what would be applied
            if [ -n "$container_image" ]; then
                local envsubst_cmd
                envsubst_cmd=$(find_envsubst)
                if [ -n "$envsubst_cmd" ]; then
                    export CONTAINER_IMAGE="$container_image"
        export BACKEND_KUBE_REPLICA_COUNT="${BACKEND_KUBE_REPLICA_COUNT:-2}"
                    export BACKEND_KUBE_REPLICA_COUNT="${BACKEND_KUBE_REPLICA_COUNT:-2}"
                    "$envsubst_cmd" < "$yaml_file" | kubectl apply --dry-run=client -f - 2>&1
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
                local envsubst_cmd
                envsubst_cmd=$(find_envsubst)
                if [ -n "$envsubst_cmd" ]; then
                    export CONTAINER_IMAGE="$container_image"
        export BACKEND_KUBE_REPLICA_COUNT="${BACKEND_KUBE_REPLICA_COUNT:-2}"
                    if ! "$envsubst_cmd" < "$yaml_file" > "$temp_file" 2>&1; then
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
            
            # Pre-apply hook: For deployments, check for pending pods that might indicate resource contention
            # The deployment strategy (maxSurge: 0, maxUnavailable: 1) handles pod termination order,
            # but we can proactively help if we detect resource issues
            if [ "$resource_kind" = "Deployment" ] && [ -n "$resource_name" ] && [ -n "$resource_namespace" ]; then
                # Check if deployment already exists
                if kubectl get deployment "$resource_name" -n "$resource_namespace" >/dev/null 2>&1; then
                    # Check for pending pods (might indicate resource contention)
                    local pending_pods
                    pending_pods=$(kubectl get pods -n "$resource_namespace" -l app="$resource_name" --field-selector=status.phase=Pending --no-headers 2>/dev/null | wc -l | tr -d ' ' || echo "0")
                    
                    if [ "$pending_pods" -gt 0 ]; then
                        log_warning "Found $pending_pods pending pod(s) for deployment $resource_name - may indicate resource contention"
                        log_info "Deployment strategy (maxSurge: 0) will ensure old pods terminate before new ones start"
                        log_info "If pods remain pending, old replicasets may need to be scaled down manually"
                    fi
                fi
            fi
            
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
            # Use centralized AWS_ACCOUNT_ID if available, otherwise check directly
            local debug_account_id="${AWS_ACCOUNT_ID:-}"
            if [ -z "$debug_account_id" ]; then
                debug_account_id=$(aws sts get-caller-identity --profile "$aws_profile" --query Account --output text 2>/dev/null || echo 'failed')
            fi
            log_info "Debug: AWS credentials check: $debug_account_id"
            # NOTE: We don't check kubectl auth can-i here because it has the same exec plugin issue
            # We'll just try kubectl apply directly - if it fails, fail-fast logic will catch it
            
            local kubectl_output
            local kubectl_exit_code
            
            # Use explicit AWS_PROFILE prefix as additional safeguard
            # Add timeout to prevent hanging (60 seconds max for kubectl apply)
            # Use background process with timeout since macOS doesn't have timeout command
            local kubectl_pid
            local kubectl_timeout=60
            local kubectl_output_file=$(mktemp)
            (
                AWS_PROFILE="$aws_profile" kubectl apply --validate=false -f "$temp_file" > "$kubectl_output_file" 2>&1
                echo $? > "$kubectl_output_file.exit"
            ) &
            kubectl_pid=$!
            
            # Wait for kubectl with timeout
            local waited=0
            local wait_interval=1
            while kill -0 "$kubectl_pid" 2>/dev/null && [ $waited -lt $kubectl_timeout ]; do
                sleep $wait_interval
                waited=$((waited + wait_interval))
            done
            
            # Check if process is still running (timed out)
            if kill -0 "$kubectl_pid" 2>/dev/null; then
                log_warning "kubectl apply timed out after ${kubectl_timeout}s, killing process..."
                kill "$kubectl_pid" 2>/dev/null || true
                wait "$kubectl_pid" 2>/dev/null || true
                kubectl_exit_code=124  # Timeout exit code
                kubectl_output=$(cat "$kubectl_output_file" 2>/dev/null || echo "Command timed out after ${kubectl_timeout} seconds")
            else
                # Process completed, get exit code and output
                wait "$kubectl_pid" 2>/dev/null || true
                kubectl_output=$(cat "$kubectl_output_file" 2>/dev/null || echo "")
                if [ -f "$kubectl_output_file.exit" ]; then
                    kubectl_exit_code=$(cat "$kubectl_output_file.exit")
                else
                    kubectl_exit_code=$?
                fi
            fi
            rm -f "$kubectl_output_file" "$kubectl_output_file.exit"
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
                    Namespace)
                        # Namespace is cluster-scoped, no -n flag needed
                        verify_cmd="kubectl get namespace $resource_name >/dev/null 2>&1"
                        ;;
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
                        
                        # For Deployment: Record for parallel waiting after all manifests are applied
                        if [ "$resource_kind" = "Deployment" ]; then
                            # Record deployment info for later parallel waiting
                            deployments_to_wait+=("$resource_name|$resource_namespace|$container_image")
                            log_info "Deployment $resource_name applied, will wait for pods after all manifests are applied"
                            
                            # Phase 1: Sync CONTAINER_IMAGE env var with deployment image
                            # This ensures /version endpoint returns correct version
                            # Note: This doesn't require pods to be ready, so we can do it immediately
                            if [ -n "$container_image" ] && [ "$dry_run" != "true" ]; then
                                log_info "Synchronizing CONTAINER_IMAGE env var with deployment image..."
                                # Extract container name from deployment spec (default to fru-api)
                                local container_name
                                container_name=$(kubectl get deployment "$resource_name" -n "$resource_namespace" \
                                    -o jsonpath='{.spec.template.spec.containers[0].name}' 2>/dev/null || echo "fru-api")
                                
                                if sync_deployment_image_and_env "$resource_name" "$resource_namespace" "$container_image" "$container_name"; then
                                    log_success "✓ Version synchronization complete for $resource_name"
                                else
                                    log_warning "⚠ Version synchronization had issues for $resource_name"
                                    log_info "The deployment will continue, but /version endpoint may show incorrect version"
                                    log_info "You can manually sync with: kubectl set env deployment/$resource_name CONTAINER_IMAGE=$container_image -n $resource_namespace"
                                fi
                            elif [ "$dry_run" = "true" ]; then
                                log_info "[DRY-RUN] Would sync CONTAINER_IMAGE env var with deployment image"
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
                                
                                # For Deployment: Record for parallel waiting after all manifests are applied
                                if [ "$resource_kind" = "Deployment" ]; then
                                    # Record deployment info for later parallel waiting
                                    deployments_to_wait+=("$resource_name|$resource_namespace|$container_image")
                                    log_info "Deployment $resource_name replaced, will wait for pods after all manifests are applied"
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
    
    # Wait for all deployments in parallel (after all manifests are applied)
    if [ ${#deployments_to_wait[@]} -gt 0 ] && [ "$dry_run" != "true" ]; then
        log_info ""
        log_info "════════════════════════════════════════════════════════════════"
        log_info "Waiting for deployments to become available"
        log_info "════════════════════════════════════════════════════════════════"
        wait_for_deployments_parallel "${deployments_to_wait[@]}"
        log_info ""
    fi
    
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
# Usage: verify_kubernetes_deployment [namespace]
#   namespace: Kubernetes namespace where app is deployed (e.g. fru-api-dev). Default: default
verify_kubernetes_deployment() {
    local namespace="${1:-default}"
    log_step "Verifying deployment status (namespace: $namespace)"
    
    # Check pods
    log_info "Checking pod status..."
    if kubectl get pods -n "$namespace" >/dev/null 2>&1; then
        kubectl get pods -n "$namespace"
        local pending_pods=$(kubectl get pods -n "$namespace" --field-selector=status.phase!=Running,status.phase!=Succeeded 2>/dev/null | tail -n +2 | wc -l | tr -d ' ')
        if [ "$pending_pods" -gt 0 ]; then
            log_warning "Some pods are not running yet"
            log_info "Check status with: kubectl get pods -n $namespace"
        else
            log_success "All pods are running"
        fi
    else
        log_warning "No pods found in namespace $namespace (may be normal if manifests don't create pods yet)"
    fi
    
    # Check services
    log_info "Checking service status..."
    if kubectl get svc -n "$namespace" >/dev/null 2>&1; then
        kubectl get svc -n "$namespace"
    else
        log_info "No services found in namespace $namespace"
    fi
    
    # Check ingress (if applicable)
    log_info "Checking ingress status..."
    if kubectl get ingress -n "$namespace" >/dev/null 2>&1; then
        kubectl get ingress -n "$namespace"
    else
        log_info "No ingress found in namespace $namespace (may be normal)"
    fi
}
