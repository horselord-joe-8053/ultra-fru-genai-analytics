#!/bin/bash
# Kubernetes manifest operations
# Usage: find_manifests_directory, generate_kubernetes_manifests, apply_kubernetes_manifests, verify_kubernetes_deployment

# Helper function to check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Find Kubernetes manifests directory
find_manifests_directory() {
    local repo_root="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../../.." && pwd)}"
    local manifests_dir="${MANIFESTS_DIR:-}"
    
    if [ -n "$manifests_dir" ]; then
        if [ -d "$manifests_dir" ]; then
            echo "$manifests_dir"
            return 0
        else
            log_error "Manifests directory not found: $manifests_dir"
            return 1
        fi
    fi
    
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
    local repo_root="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../../.." && pwd)}"
    
    log_info "Generating ConfigMap and Secret from templates..."
    
    # Load environment variables from .env
    if [ -f "$repo_root/run_scripts/shared/load-env.sh" ]; then
        source "$repo_root/run_scripts/shared/load-env.sh" 2>/dev/null || true
        load_env_file 2>/dev/null || true
    fi
    
    # Generate ConfigMap from template
    local configmap_template="$manifests_dir/configmap.yaml"
    local configmap_output="$manifests_dir/configmap-generated.yaml"
    
    if [ -f "$configmap_template" ]; then
        log_info "Generating ConfigMap from template..."
        if command_exists envsubst; then
            # Most variables are now exported by load-env.sh (PGHOST, PGUSER, AWS_REGION, AWS_BEDROCK_MODEL_ID)
            # Only export Kubernetes-specific variables that aren't in load-env.sh
            export OPENAI_EMBED_MODEL="${OPENAI_EMBED_MODEL:-text-embedding-3-small}"
            export USE_AGENT_QUERY="${USE_AGENT_QUERY:-false}"
            export LOG_LEVEL="${LOG_LEVEL:-INFO}"
            
            envsubst < "$configmap_template" > "$configmap_output"
            log_success "ConfigMap generated: configmap-generated.yaml"
        else
            log_warning "envsubst not found, using template as-is"
            cp "$configmap_template" "$configmap_output"
        fi
    fi
    
    # Generate Secret from template
    local secret_template="$manifests_dir/secret.yaml.template"
    local secret_output="$manifests_dir/secret.yaml"
    
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
            log_success "Secret generated: secret.yaml"
        else
            log_warning "envsubst not found, cannot generate secret from template"
            log_info "You'll need to create secret manually: kubectl create secret generic fru-secrets ..."
        fi
    fi
}

# Apply Kubernetes manifests
apply_kubernetes_manifests() {
    local manifests_dir=$1
    local repo_root="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../../.." && pwd)}"
    local dry_run="${DRY_RUN:-false}"
    
    log_step "Applying Kubernetes manifests"
    
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
    
    # Generate ConfigMap and Secret from templates first
    generate_kubernetes_manifests "$manifests_dir"
    
    if [ -z "$container_image" ]; then
        log_warning "CONTAINER_IMAGE not set"
        log_info "Manifests will be applied without image substitution"
        log_info "Make sure your manifests reference the correct image"
    else
        log_info "Using container image: $container_image"
    fi
    
    # Find YAML files (exclude templates, prefer generated files)
    local yaml_files=()
    
    # Prefer generated files if they exist, otherwise use templates
    if [ -f "$manifests_dir/configmap-generated.yaml" ]; then
        yaml_files+=("$manifests_dir/configmap-generated.yaml")
    elif [ -f "$manifests_dir/configmap.yaml" ]; then
        yaml_files+=("$manifests_dir/configmap.yaml")
    fi
    
    if [ -f "$manifests_dir/secret.yaml" ]; then
        yaml_files+=("$manifests_dir/secret.yaml")
    fi
    
    # Add other YAML files (deployment, service, ingress, etc.)
    while IFS= read -r file; do
        local basename_file=$(basename "$file")
        # Skip templates and already-added files
        if [[ "$basename_file" != "configmap.yaml" && \
              "$basename_file" != "configmap-generated.yaml" && \
              "$basename_file" != "secret.yaml.template" && \
              "$basename_file" != "secret.yaml" && \
              "$basename_file" != ".gitignore" && \
              "$basename_file" != "README.md" ]]; then
            yaml_files+=("$file")
        fi
    done < <(find "$manifests_dir" \( -name "*.yaml" -o -name "*.yml" \) | sort)
    
    if [ ${#yaml_files[@]} -eq 0 ]; then
        log_warning "No YAML files found in $manifests_dir"
        return 0
    fi
    
    log_info "Found ${#yaml_files[@]} manifest file(s)"
    
    # Apply each manifest
    for yaml_file in "${yaml_files[@]}"; do
        log_info "Applying: $(basename "$yaml_file")"
        
        if [ "$dry_run" = "true" ]; then
            # Dry-run: show what would be applied
            if [ -n "$container_image" ]; then
                if command_exists envsubst; then
                    export CONTAINER_IMAGE="$container_image"
                    envsubst < "$yaml_file" | kubectl apply --dry-run=client -f -
                else
                    sed "s|\${CONTAINER_IMAGE}|$container_image|g; s|<CONTAINER_IMAGE>|$container_image|g" "$yaml_file" | kubectl apply --dry-run=client -f -
                fi
            else
                kubectl apply --dry-run=client -f "$yaml_file"
            fi
            log_info "[DRY-RUN] Would apply: $(basename "$yaml_file")"
        else
            # Actual apply
            if [ -n "$container_image" ]; then
                # Use envsubst if available, otherwise use sed
                if command_exists envsubst; then
                    export CONTAINER_IMAGE="$container_image"
                    envsubst < "$yaml_file" | kubectl apply -f -
                else
                    # Fallback to sed (simple substitution)
                    sed "s|\${CONTAINER_IMAGE}|$container_image|g; s|<CONTAINER_IMAGE>|$container_image|g" "$yaml_file" | kubectl apply -f -
                fi
            else
                kubectl apply -f "$yaml_file"
            fi
        fi
    done
    
    log_success "Manifests applied successfully"
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

