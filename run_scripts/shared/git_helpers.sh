#!/bin/bash
# Git helper functions for generating image tags
# Provides consistent tag generation across all deployment scripts

# Generate image tag from git commit SHA
# Format: fru-<env>-<date>-<sha>-<commit-slug> (clean) or fru-<env>-<date>-<sha>-dirty-<timestamp> (dirty)
# Example: fru-dev-20260108-999a986-fix-teardown-script-path or fru-dev-20260108-999a986-dirty-20260117121530
# Note: Dirty builds include timestamp (YYYYMMDDHHMMSS) to ensure uniqueness when rebuilding
#       with the same commit but different file content, preventing digest cache issues in ECS
# 
# This format is:
# - Comprehensible: Easy to understand at a glance
# - Simple: Clear structure with meaningful parts
# - Searchable: Can search by date, environment, or commit message keywords
#
# For production deployments, blocks uncommitted changes (fail-fast)
# Usage: IMAGE_TAG=$(generate_image_tag)
generate_image_tag() {
    # Check if git is available and we're in a git repository
    if ! command -v git >/dev/null 2>&1 || ! git rev-parse --git-dir >/dev/null 2>&1; then
        # Not in git repository: use timestamp as fallback
        local environment="${ENVIRONMENT:-dev}"
        environment=$(echo "$environment" | sed 's/[^a-zA-Z0-9]//g' | tr '[:upper:]' '[:lower:]')
        if [ -z "$environment" ]; then
            environment="dev"
        fi
        echo "fru-${environment}-$(date +%Y%m%d)-build-$(date +%H%M%S)"
        return
    fi
    
    # Get environment (default to dev)
    local environment="${ENVIRONMENT:-dev}"
    # Sanitize environment name (only alphanumeric, lowercase)
    environment=$(echo "$environment" | sed 's/[^a-zA-Z0-9]//g' | tr '[:upper:]' '[:lower:]')
    if [ -z "$environment" ]; then
        environment="dev"  # Fallback if sanitization removed everything
    fi
    
    # Get commit date (YYYYMMDD format for searchability)
    local commit_date
    commit_date=$(git log -1 --format=%cd --date=format:%Y%m%d HEAD 2>/dev/null || date +%Y%m%d)
    
    # Get commit SHA (short, 7 characters)
    local base_sha
    base_sha=$(git rev-parse --short HEAD)
    
    # Check if working tree is clean (no uncommitted changes)
    local has_uncommitted=false
    if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
        has_uncommitted=true
    fi
    
    # Dirty working tree detected
    if [ "$has_uncommitted" = true ]; then
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
            log_warning "Uncommitted changes detected! Tagging as 'dirty'."
            if [ "$environment" != "prod" ]; then
                log_info "This is allowed in $environment environment for development/testing."
            fi
            log_info "For production deployments, commit your changes first."
        else
            echo "WARNING: Uncommitted changes detected! Tagging as 'dirty'." >&2
        fi
        
        # Dirty format: fru-<env>-<date>-<sha>-dirty-<timestamp>
        # Include timestamp to ensure uniqueness when rebuilding with same commit but different file content
        # Format: YYYYMMDDHHMMSS (sortable, clear, fits Docker tag requirements)
        local build_timestamp
        build_timestamp=$(date +%Y%m%d%H%M%S)
        echo "fru-${environment}-${commit_date}-${base_sha}-dirty-${build_timestamp}"
        return
    fi
    
    # Clean working tree: include commit message slug for context
    # Get first line of commit message, sanitize it, and create a slug
    local commit_msg
    commit_msg=$(git log -1 --format=%s HEAD 2>/dev/null || echo "unknown")
    
    # Create a slug from commit message:
    # Docker tag rules: lowercase letters, digits, underscores, periods, and hyphens only
    # 1. Convert to lowercase
    # 2. Remove all invalid characters (keep only alphanumeric, spaces, hyphens, underscores, periods)
    # 3. Replace spaces with hyphens using tr (more reliable than sed)
    # 4. Replace multiple hyphens with single hyphen
    # 5. Remove leading/trailing hyphens
    # 6. Limit to 30 characters
    local commit_slug
    commit_slug=$(echo "$commit_msg" | \
        tr '[:upper:]' '[:lower:]' | \
        sed 's/[^a-z0-9._ -]//g' | \
        tr ' ' '-' | \
        sed 's/-\+/-/g' | \
        sed 's/^-\|-$//g' | \
        cut -c1-30)
    
    # If slug is empty after sanitization, use a default
    if [ -z "$commit_slug" ]; then
        commit_slug="commit"
    fi
    
    # Clean format: fru-<env>-<date>-<sha>-<commit-slug>
    # Note: Removed # wrappers as Docker tags cannot contain # characters
    echo "fru-${environment}-${commit_date}-${base_sha}-${commit_slug}"
}

