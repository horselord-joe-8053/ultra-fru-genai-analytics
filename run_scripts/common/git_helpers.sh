#!/bin/bash
# Git helper functions for generating image tags
# Provides consistent tag generation across all deployment scripts

# Generate image tag from git commit SHA
# Detects uncommitted changes and includes working tree hash when dirty
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
    
    # Check if working tree is clean (no uncommitted changes)
    if git diff --quiet && git diff --cached --quiet; then
        # Clean working tree: use commit SHA only
        echo "git-${base_sha}"
    else
        # Dirty working tree: include working tree hash + warn
        # Source logger if available (may not be sourced in all contexts)
        if [ -n "${log_warning:-}" ]; then
            log_warning "Uncommitted changes detected!"
            log_warning "Using working tree hash to ensure unique tag."
            log_info "For production deployments, commit your changes first."
        else
            echo "WARNING: Uncommitted changes detected! Using working tree hash." >&2
        fi
        
        # Generate hash from working tree changes
        # Use shasum on macOS, sha256sum on Linux
        local worktree_hash
        if command -v sha256sum >/dev/null 2>&1; then
            worktree_hash=$(git diff HEAD | sha256sum | cut -c1-7 2>/dev/null)
        elif command -v shasum >/dev/null 2>&1; then
            worktree_hash=$(git diff HEAD | shasum -a 256 | cut -c1-7 2>/dev/null)
        else
            # Fallback: use timestamp-based hash
            worktree_hash=$(date +%s | shasum -a 256 2>/dev/null | cut -c1-7 || echo "unknown")
        fi
        echo "git-${base_sha}-dirty-${worktree_hash}"
    fi
}

