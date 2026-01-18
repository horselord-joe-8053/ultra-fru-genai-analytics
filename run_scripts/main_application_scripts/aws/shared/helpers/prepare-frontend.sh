#!/bin/bash
# Prepare frontend for deployment (build if needed)
# Usage: build_frontend_if_needed
#
# This function checks if the frontend needs to be built and builds it if necessary.
# It's used by both ECS and EKS deployment scripts to ensure frontend is ready.

build_frontend_if_needed() {
    local repo_root="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../../.." && pwd)}"
    
    # Check if frontend needs to be built
    local needs_build=false
    
    if [ ! -d "$repo_root/frontend/dist" ]; then
        log_info "Frontend dist directory not found, will build"
        needs_build=true
    else
        # Check if any source files are newer than the dist build
        # This ensures we rebuild when source code changes
        # Use cross-platform stat command (macOS: -f, Linux: -c)
        local dist_file
        dist_file=$(find "$repo_root/frontend/dist" -type f \( -name "*.html" -o -name "*.js" -o -name "*.css" \) 2>/dev/null | head -1)
        local dist_mtime="0"
        if [ -n "$dist_file" ]; then
            dist_mtime=$(stat -f "%m" "$dist_file" 2>/dev/null || stat -c "%Y" "$dist_file" 2>/dev/null || echo "0")
        fi
        
        local src_mtime="0"
        local src_files
        src_files=$(find "$repo_root/frontend/src" -type f \( -name "*.tsx" -o -name "*.ts" -o -name "*.jsx" -o -name "*.js" -o -name "*.css" \) 2>/dev/null | head -1)
        if [ -n "$src_files" ]; then
            src_mtime=$(stat -f "%m" "$src_files" 2>/dev/null || stat -c "%Y" "$src_files" 2>/dev/null || echo "0")
        fi
        
        # Also check package.json and package-lock.json
        local package_mtime="0"
        if [ -f "$repo_root/frontend/package.json" ]; then
            package_mtime=$(stat -f "%m" "$repo_root/frontend/package.json" 2>/dev/null || stat -c "%Y" "$repo_root/frontend/package.json" 2>/dev/null || echo "0")
        fi
        
        # If source is newer than dist, or package.json changed, rebuild
        if [ "$src_mtime" -gt "$dist_mtime" ] || [ "$package_mtime" -gt "$dist_mtime" ]; then
            log_info "Frontend source files are newer than dist, will rebuild"
            needs_build=true
        fi
    fi
    
    if [ "$needs_build" = true ]; then
        log_info "Building frontend..."
        cd "$repo_root/frontend"
        
        # Install dependencies if needed
        if [ ! -d "node_modules" ]; then
            log_info "Installing frontend dependencies..."
            npm install || {
                log_error "Failed to install frontend dependencies"
                return 1
            }
        fi
        
        # Build frontend
        log_info "Running frontend build..."
        npm run build || {
            log_error "Failed to build frontend"
            return 1
        }
        
        log_success "Frontend built successfully"
    else
        log_info "Frontend is already built and up-to-date"
    fi
    
    return 0
}

