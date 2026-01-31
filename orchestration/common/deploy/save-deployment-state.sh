#!/bin/bash
# Deployment State Tracking
# Phase 5: Saves deployment state with version information to JSON file
# Usage: save_deployment_state <environment> <container_type> <backend_version> <frontend_version> <cloudfront_invalidation_id>

# Source logger if available
REPO_ROOT_SAVE="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
if [ -f "$REPO_ROOT_SAVE/orchestration/common/logger.sh" ]; then
    source "$REPO_ROOT_SAVE/orchestration/common/logger.sh"
else
    # Fallback logging functions
    log_info() { echo "[INFO] $*"; }
    log_success() { echo "[SUCCESS] $*"; }
    log_warning() { echo "[WARNING] $*"; }
    log_error() { echo "[ERROR] $*"; }
fi

save_deployment_state() {
    local environment=$1
    local container_type=$2
    local backend_version=$3
    local frontend_version=$4
    local cloudfront_invalidation_id=$5
    
    local repo_root="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
    local state_file="$repo_root/.deployment-state.json"
    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    
    log_info "Saving deployment state..."
    
    # Create deployment entry
    local deployment_entry
    deployment_entry=$(cat <<EOF
{
  "timestamp": "$timestamp",
  "environment": "${environment:-unknown}",
  "container_type": "${container_type:-unknown}",
  "backend_version": "${backend_version:-unknown}",
  "frontend_version": "${frontend_version:-unknown}",
  "cloudfront_invalidation_id": "${cloudfront_invalidation_id:-none}"
}
EOF
)
    
    # Read existing state or create new
    local state_json
    if [ -f "$state_file" ] && [ -s "$state_file" ]; then
        state_json=$(cat "$state_file" 2>/dev/null || echo "{}")
    else
        state_json="{}"
    fi
    
    # Update state using jq if available, otherwise use simple append
    if command -v jq >/dev/null 2>&1; then
        # Use jq to properly merge JSON
        state_json=$(echo "$state_json" | jq --argjson entry "$deployment_entry" '
            .last_deployment = $entry |
            .deployments = (.deployments // []) + [$entry] |
            .deployments = .deployments[-10:]  # Keep only last 10 deployments
        ')
    else
        # Fallback: simple JSON structure (less robust but works without jq)
        log_warning "jq not available - using simple JSON format"
        # Create simple JSON structure
        cat > "$state_file" <<EOF
{
  "last_deployment": $deployment_entry,
  "deployments": [$deployment_entry],
  "note": "jq not available - limited functionality"
}
EOF
        log_success "Deployment state saved to $state_file"
        return 0
    fi
    
    # Write updated state
    echo "$state_json" > "$state_file"
    log_success "Deployment state saved to $state_file"
    log_info "  Environment: $environment"
    log_info "  Container Type: $container_type"
    log_info "  Backend Version: ${backend_version:-not set}"
    log_info "  Frontend Version: ${frontend_version:-not set}"
    log_info "  CloudFront Invalidation: ${cloudfront_invalidation_id:-none}"
    
    return 0
}

# If script is run directly, execute function
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    save_deployment_state "$@"
fi
