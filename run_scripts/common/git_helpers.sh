#!/bin/bash
# Git helper functions for generating image tags
# Provides consistent tag generation across all deployment scripts

# Generate image tag from git commit SHA
# Detects uncommitted changes and includes working tree hash when dirty
# For production deployments, blocks uncommitted changes (fail-fast)
# Usage: IMAGE_TAG=$(generate_image_tag)
generate_image_tag() {
    # Check if git is available and we're in a git repository
    if ! command -v git >/dev/null 2>&1 || ! git rev-parse --git-dir >/dev/null 2>&1; then
        # Not in git repository: use timestamp as fallback
        echo "build-$(date +%Y%m%d-%H%M%S)"
        return
    fi
    
    local base_sha
    base_sha=$(git rev-parse --short HEAD)
    
    # Get environment for suffix (default to dev)
    local environment="${ENVIRONMENT:-dev}"
    # Sanitize environment name (only alphanumeric and underscore)
    environment=$(echo "$environment" | sed 's/[^a-zA-Z0-9_]//g')
    if [ -z "$environment" ]; then
        environment="dev"  # Fallback if sanitization removed everything
    fi
    
    # Check if working tree is clean (no uncommitted changes)
    local has_uncommitted=false
    if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
        has_uncommitted=true
    fi
    
    if [ "$has_uncommitted" = false ]; then
        # Clean working tree: use commit SHA with environment suffix
        echo "git-${base_sha}_${environment}"
        return
    fi
    
    # Dirty working tree detected
    local allow_dirty="${ALLOW_DIRTY_DEPLOYMENT:-false}"
    
    # For production: block dirty deployments unless explicitly allowed
    if [ "$environment" = "prod" ] && [ "$allow_dirty" != "true" ]; then
        # Source logger if available
        if [ -n "${log_error:-}" ]; then
            log_error "Uncommitted changes detected in PRODUCTION deployment!"
            log_error "All changes must be committed before production deployment."
            log_error "To override (NOT RECOMMENDED), set ALLOW_DIRTY_DEPLOYMENT=true"
            log_info "Current uncommitted changes:"
            git status --short | head -10
        else
            echo "ERROR: Uncommitted changes detected in PRODUCTION deployment!" >&2
            echo "All changes must be committed before production deployment." >&2
        fi
        exit 1
    fi
    
    # For dev/staging: allow with warning
    if [ -n "${log_warning:-}" ]; then
        log_warning "Uncommitted changes detected! Using working tree hash to ensure unique tag."
        if [ "$environment" != "prod" ]; then
            log_info "This is allowed in $environment environment for development/testing."
        fi
        log_info "For production deployments, commit your changes first."
    else
        echo "WARNING: Uncommitted changes detected! Using working tree hash." >&2
    fi
    
    # Generate hash from working tree changes
    # Use shasum on macOS, sha256sum on Linux
    local worktree_hash
    if command -v sha256sum >/dev/null 2>&1; then
        worktree_hash=$(git diff HEAD 2>/dev/null | sha256sum | cut -c1-7 2>/dev/null || echo "unknown")
    elif command -v shasum >/dev/null 2>&1; then
        worktree_hash=$(git diff HEAD 2>/dev/null | shasum -a 256 | cut -c1-7 2>/dev/null || echo "unknown")
    else
        # Fallback: use timestamp-based hash
        worktree_hash=$(date +%s | shasum -a 256 2>/dev/null | cut -c1-7 || echo "unknown")
    fi
    echo "git-${base_sha}-dirty-${worktree_hash}_${environment}"
}

