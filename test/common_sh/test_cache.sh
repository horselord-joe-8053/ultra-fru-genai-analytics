#!/usr/bin/env bash
# Cache utility functions for AWS deployment values
# Uses pipe-delimited format for robustness

# Cache file location
# Calculate REPO_ROOT if not set
# Note: REPO_ROOT should be set by setup_test_environment() before this script is sourced
# But if not, we calculate it from the script location
if [ -z "${REPO_ROOT:-}" ]; then
    # Find this script's actual location
    # When sourced, BASH_SOURCE[0] in the sourcing context points to the sourcing script
    # So we need to find test_cache.sh's actual location
    # test_environment.sh sources this with: source "$(dirname "${BASH_SOURCE[0]}")/test_cache.sh"
    # So the path passed to source is: test/common_sh/test_cache.sh (relative to test_environment.sh's dir)
    # We can find it by looking for the cache file in common locations
    local possible_repo_root
    # Try to find repo root by looking for test/cache_files directory
    # Start from current directory and go up
    possible_repo_root="$(pwd)"
    while [ "$possible_repo_root" != "/" ]; do
        if [ -d "$possible_repo_root/test/cache_files" ]; then
            REPO_ROOT="$possible_repo_root"
            break
        fi
        possible_repo_root="$(dirname "$possible_repo_root")"
    done
    
    # If still not found, try calculating from script location
    # This script is at test/common_sh/test_cache.sh relative to repo root
    if [ -z "${REPO_ROOT:-}" ]; then
        # Get the directory where test_environment.sh is (which sources this)
        # BASH_SOURCE array: [0] = sourcing script, [1] = this script (if we're in a function)
        local sourcing_script="${BASH_SOURCE[0]}"
        # If sourced with relative path, resolve it
        if [[ "$sourcing_script" != /* ]]; then
            sourcing_script="$(cd "$(dirname "$sourcing_script")" && pwd)/$(basename "$sourcing_script")"
        fi
        # test_environment.sh sources: "$(dirname "${BASH_SOURCE[0]}")/test_cache.sh"
        # So the dirname gives us test/common_sh/, go up 2 levels
        local script_dir
        script_dir="$(cd "$(dirname "$sourcing_script")" && pwd)"
        # If this script is test_cache.sh, go up 2 levels
        if [[ "$(basename "$sourcing_script")" == "test_cache.sh" ]] || [[ "$script_dir" == *"/test/common_sh" ]]; then
            REPO_ROOT="$(cd "$script_dir/../.." && pwd)"
        else
            # Otherwise, assume we're in test/common_sh/ and go up 2 levels
            REPO_ROOT="$(cd "$script_dir/../.." && pwd)"
        fi
    fi
    export REPO_ROOT
fi
CACHE_DIR="${REPO_ROOT}/test/cache_files"
CACHE_FILE="${CACHE_DIR}/test_cached_aws_setups.txt"

# Default TTL in seconds (1 hour)
CACHE_TTL_SECONDS="${CACHE_TTL_SECONDS:-3600}"

# Ensure cache directory exists
ensure_cache_dir() {
    if [ ! -d "$CACHE_DIR" ]; then
        mkdir -p "$CACHE_DIR" 2>/dev/null || {
            if command -v log_warning >/dev/null 2>&1; then
                log_warning "Could not create cache directory: $CACHE_DIR"
            fi
            return 1
        }
    fi
    return 0
}

# Migrate cache file to include test_env column
# Adds test_env='aws' to existing entries (assumes they were created for AWS tests)
migrate_cache_file() {
    if [ ! -f "$CACHE_FILE" ]; then
        return 0  # No cache file, nothing to migrate
    fi
    
    # Check if already migrated (header has test_env)
    if head -1 "$CACHE_FILE" | grep -q "test_env"; then
        return 0  # Already migrated
    fi
    
    local temp_file="${CACHE_FILE}.migrate.$$"
    local header_line="env_var_name|environment|deployment_type|aws_region|test_env|datetime_value_obtained|value|problem"
    
    echo "$header_line" > "$temp_file"
    
    # Process each line (skip header)
    while IFS= read -r line || [ -n "$line" ]; do
        if [[ "$line" == env_var_name* ]]; then
            continue  # Skip old header
        fi
        
        # Skip empty lines
        if [ -z "$line" ]; then
            continue
        fi
        
        # Count fields (pipe-delimited)
        local field_count
        field_count=$(echo "$line" | awk -F'|' '{print NF}')
        
        if [ "$field_count" -eq 7 ]; then
            # Old format: insert 'aws' as field 5
            # Format: env_var_name|environment|deployment_type|aws_region|datetime|value|problem
            # New:    env_var_name|environment|deployment_type|aws_region|test_env|datetime|value|problem
            local part1
            part1=$(echo "$line" | awk -F'|' '{print $1"|"$2"|"$3"|"$4}')
            local part2
            part2=$(echo "$line" | awk -F'|' '{print $5"|"$6"|"$7}')
            echo "${part1}|aws|${part2}" >> "$temp_file"
        elif [ "$field_count" -eq 8 ]; then
            # Already migrated, keep as-is
            echo "$line" >> "$temp_file"
        fi
    done < "$CACHE_FILE"
    
    # Atomic replace
    if mv "$temp_file" "$CACHE_FILE" 2>/dev/null; then
        return 0
    else
        rm -f "$temp_file" 2>/dev/null || true
        return 1
    fi
}

# Read cache value for a given key
# Parameters:
#   $1: env_var_name (e.g., "ALB_DNS")
#   $2: environment (e.g., "dev")
#   $3: deployment_type (e.g., "ecs-full")
#   $4: aws_region (e.g., "us-east-1")
#   $5: test_env (e.g., "aws" or "local")
# Returns: value if found and valid, empty string otherwise
# Sets: CACHE_VALUE, CACHE_DATETIME, CACHE_PROBLEM
read_cache_value() {
    local env_var_name="$1"
    local environment="$2"
    local deployment_type="$3"
    local aws_region="$4"
    local test_env="${5:-aws}"  # Default to 'aws' for backward compatibility
    
    # Reset output variables
    CACHE_VALUE=""
    CACHE_DATETIME=""
    CACHE_PROBLEM=""
    
    # Ensure cache directory exists
    if ! ensure_cache_dir; then
        return 1
    fi
    
    # Migrate cache file if needed (one-time migration)
    migrate_cache_file
    
    # Check if cache file exists
    if [ ! -f "$CACHE_FILE" ]; then
        return 1  # Cache miss
    fi
    
    # Read cache file and find matching entry
    # Format: env_var_name|environment|deployment_type|aws_region|test_env|datetime_value_obtained|value|problem
    local cache_line
    cache_line=$(grep "^${env_var_name}|${environment}|${deployment_type}|${aws_region}|${test_env}|" "$CACHE_FILE" 2>/dev/null | tail -1)
    
    if [ -z "$cache_line" ]; then
        return 1  # Cache miss
    fi
    
    # Parse cache line (pipe-delimited)
    # Extract fields directly using awk (more reliable than array splitting)
    CACHE_DATETIME=$(echo "$cache_line" | awk -F'|' '{print $6}')  # Was $5, now $6
    CACHE_VALUE=$(echo "$cache_line" | awk -F'|' '{print $7}')    # Was $6, now $7
    CACHE_PROBLEM=$(echo "$cache_line" | awk -F'|' '{print $8}')  # Was $7, now $8
    
    # Validate we got the required fields
    if [ -z "$CACHE_DATETIME" ] || [ -z "$CACHE_VALUE" ]; then
        if command -v log_warning >/dev/null 2>&1; then
            log_warning "Invalid cache line format: $cache_line (missing required fields)"
        fi
        return 1
    fi
    
    # Check if value is NULL (failed fetch)
    if [ -z "$CACHE_VALUE" ] || [ "$CACHE_VALUE" = "NULL" ]; then
        return 1  # Cache miss (treat failed fetches as miss)
    fi
    
    # Check TTL
    if ! is_cache_valid "$CACHE_DATETIME"; then
        return 1  # Cache expired
    fi
    
    return 0  # Cache hit
}

# Check if cache entry is valid (not expired)
# Parameters:
#   $1: datetime_string (YYYY-MM-DD_hhmmss format)
# Returns: 0 if valid, 1 if expired
is_cache_valid() {
    local datetime_string="$1"
    
    if [ -z "$datetime_string" ]; then
        return 1  # Invalid datetime
    fi
    
    # Parse datetime (YYYY-MM-DD_hhmmss)
    local date_part="${datetime_string%%_*}"
    local time_part="${datetime_string#*_}"
    
    if [ -z "$date_part" ] || [ -z "$time_part" ]; then
        return 1  # Invalid format
    fi
    
    # Convert to epoch seconds
    local cache_epoch
    if [[ "$OSTYPE" == "darwin"* ]]; then
        # macOS date command
        cache_epoch=$(date -j -f "%Y-%m-%d_%H%M%S" "$datetime_string" +%s 2>/dev/null || echo "0")
    else
        # Linux date command
        cache_epoch=$(date -d "${date_part} ${time_part:0:2}:${time_part:2:2}:${time_part:4:2}" +%s 2>/dev/null || echo "0")
    fi
    
    if [ "$cache_epoch" = "0" ]; then
        return 1  # Failed to parse
    fi
    
    # Get current epoch
    local current_epoch
    current_epoch=$(date +%s 2>/dev/null || echo "0")
    
    if [ "$current_epoch" = "0" ]; then
        return 1  # Failed to get current time
    fi
    
    # Check if cache is within TTL
    local age=$((current_epoch - cache_epoch))
    
    if [ $age -lt 0 ]; then
        return 1  # Cache from future (invalid)
    fi
    
    if [ $age -gt "$CACHE_TTL_SECONDS" ]; then
        return 1  # Cache expired
    fi
    
    return 0  # Cache valid
}

# Write cache value
# Parameters:
#   $1: env_var_name
#   $2: environment
#   $3: deployment_type
#   $4: aws_region
#   $5: test_env (e.g., "aws" or "local")
#   $6: value (use "NULL" if failed to retrieve)
#   $7: problem (reason for failure, empty if successful)
write_cache_value() {
    local env_var_name="$1"
    local environment="$2"
    local deployment_type="$3"
    local aws_region="$4"
    local test_env="${5:-aws}"  # Default to 'aws' for backward compatibility
    local value="${6:-NULL}"
    local problem="${7:-}"
    
    # Ensure cache directory exists
    if ! ensure_cache_dir; then
        if command -v log_warning >/dev/null 2>&1; then
            log_warning "Could not create cache directory, skipping cache write"
        fi
        return 1
    fi
    
    # Migrate cache file if needed (one-time migration)
    migrate_cache_file
    
    # Get current datetime (YYYY-MM-DD_hhmmss)
    local datetime_string
    datetime_string=$(date +"%Y-%m-%d_%H%M%S" 2>/dev/null || echo "")
    
    if [ -z "$datetime_string" ]; then
        if command -v log_warning >/dev/null 2>&1; then
            log_warning "Could not get current datetime, skipping cache write"
        fi
        return 1
    fi
    
    # Create cache line
    # Format: env_var_name|environment|deployment_type|aws_region|test_env|datetime_value_obtained|value|problem
    local cache_line="${env_var_name}|${environment}|${deployment_type}|${aws_region}|${test_env}|${datetime_string}|${value}|${problem}"
    
    # Remove old entries for this key (keep only latest)
    local temp_file
    temp_file=$(mktemp 2>/dev/null || echo "${CACHE_FILE}.tmp")
    
    if [ -f "$CACHE_FILE" ]; then
        # Remove old entries matching this key (include test_env in pattern)
        grep -v "^${env_var_name}|${environment}|${deployment_type}|${aws_region}|${test_env}|" "$CACHE_FILE" > "$temp_file" 2>/dev/null || true
    else
        # Create new file with header
        echo "env_var_name|environment|deployment_type|aws_region|test_env|datetime_value_obtained|value|problem" > "$temp_file"
    fi
    
    # Append new entry
    echo "$cache_line" >> "$temp_file"
    
    # Atomic write: move temp file to cache file
    if mv "$temp_file" "$CACHE_FILE" 2>/dev/null; then
        return 0
    else
        if command -v log_warning >/dev/null 2>&1; then
            log_warning "Could not write to cache file: $CACHE_FILE"
        fi
        rm -f "$temp_file" 2>/dev/null || true
        return 1
    fi
}

# Load all cached values for a given environment/deployment/region/test_env
# Parameters:
#   $1: environment
#   $2: deployment_type
#   $3: aws_region
#   $4: test_env (e.g., "aws" or "local")
# Sets: ALB_DNS, CLOUDFRONT_DOMAIN, ECS_CLUSTER_ID, ECS_SERVICE_NAME (if found in cache)
load_cached_values() {
    local environment="$1"
    local deployment_type="$2"
    local aws_region="$3"
    local test_env="${4:-aws}"  # Default to 'aws' for backward compatibility
    
    local vars=("ALB_DNS" "CLOUDFRONT_DOMAIN" "ECS_CLUSTER_ID" "ECS_SERVICE_NAME")
    local loaded_count=0
    
    for var in "${vars[@]}"; do
        if read_cache_value "$var" "$environment" "$deployment_type" "$aws_region" "$test_env"; then
            # Export the variable
            export "$var=$CACHE_VALUE"
            loaded_count=$((loaded_count + 1))
            
            if command -v log_info >/dev/null 2>&1; then
                log_info "Loaded cached value for $var: ${CACHE_VALUE:0:50}..."
            fi
        fi
    done
    
    if [ $loaded_count -gt 0 ] && command -v log_info >/dev/null 2>&1; then
        log_info "Loaded $loaded_count cached value(s) from cache"
    fi
    
    return 0
}

