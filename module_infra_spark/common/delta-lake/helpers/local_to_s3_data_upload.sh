#!/bin/bash
# Upload local CSV file to S3 for Delta Lake ingestion (AWS deployments)
# Supports change detection and force upload via --preempt flag
#
# Usage: 
#   source local_to_s3_data_upload.sh
#   upload_csv_to_s3 <local_path> <s3_path> [--force]
#
# Functions:
#   - check_s3_file_exists: Check if file exists in S3
#   - get_local_file_info: Get local file size and hash
#   - get_s3_file_info: Get S3 file size
#   - compare_files: Compare local and S3 files (by size)
#   - upload_csv_to_s3: Main function to upload CSV with change detection

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# From helpers/ -> delta-lake/ -> common/ -> spark_delta-lake_scripts/ -> run_scripts/ -> root (5 levels up)
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../../../../.." && pwd)}"
source "$REPO_ROOT/lib/logger.sh"

AWS_PROFILE="${AWS_PROFILE:-admin}"
AWS_REGION="${AWS_REGION:-us-east-1}"

# ============================================================================
# Check if S3 file exists
# ============================================================================
# Usage: check_s3_file_exists <s3_path>
# Returns: 0 if exists, 1 if not
check_s3_file_exists() {
    local s3_path="$1"
    local aws_profile="${2:-$AWS_PROFILE}"
    local aws_region="${3:-$AWS_REGION}"
    
    if aws s3 ls "$s3_path" --profile "$aws_profile" --region "$aws_region" >/dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

# ============================================================================
# Get local file information (size and hash)
# ============================================================================
# Usage: get_local_file_info <local_path>
# Outputs: <size>|<hash> (pipe-separated)
get_local_file_info() {
    local local_path="$1"
    
    # Get file size
    local file_size
    file_size=$(stat -f%z "$local_path" 2>/dev/null || stat -c%s "$local_path" 2>/dev/null || echo "0")
    
    # Get file hash (SHA256)
    local file_hash="unknown"
    if command -v sha256sum >/dev/null 2>&1; then
        file_hash=$(sha256sum "$local_path" | cut -d' ' -f1)
    elif command -v shasum >/dev/null 2>&1; then
        file_hash=$(shasum -a 256 "$local_path" | cut -d' ' -f1)
    fi
    
    echo "${file_size}|${file_hash}"
}

# ============================================================================
# Get S3 file information (size)
# ============================================================================
# Usage: get_s3_file_info <s3_path>
# Outputs: <size> (or "0" if not found)
get_s3_file_info() {
    local s3_path="$1"
    local aws_profile="${2:-$AWS_PROFILE}"
    local aws_region="${3:-$AWS_REGION}"
    
    # Extract S3 path components
    local s3_bucket
    local s3_key
    s3_bucket=$(echo "$s3_path" | sed 's|s3://||' | cut -d'/' -f1)
    s3_key=$(echo "$s3_path" | sed "s|s3://${s3_bucket}/||")
    
    # Get S3 object size
    local s3_size
    s3_size=$(aws s3api head-object \
        --bucket "$s3_bucket" \
        --key "$s3_key" \
        --profile "$aws_profile" \
        --region "$aws_region" \
        --query 'ContentLength' \
        --output text 2>/dev/null || echo "0")
    
    echo "$s3_size"
}

# ============================================================================
# Compare local and S3 files (by size)
# ============================================================================
# Usage: compare_files <local_path> <s3_path> [force]
# Returns: 0 if files are same (or force=true), 1 if different
compare_files() {
    local local_path="$1"
    local s3_path="$2"
    local force="${3:-false}"
    
    # If force is true, always return 1 (needs upload)
    if [ "$force" = "true" ]; then
        return 1
    fi
    
    # Get local file info
    local local_info
    local_info=$(get_local_file_info "$local_path")
    local local_size
    local local_hash
    local_size=$(echo "$local_info" | cut -d'|' -f1)
    local_hash=$(echo "$local_info" | cut -d'|' -f2)
    
    # Check if S3 file exists
    if ! check_s3_file_exists "$s3_path"; then
        # S3 file doesn't exist, needs upload
        return 1
    fi
    
    # Get S3 file size
    local s3_size
    s3_size=$(get_s3_file_info "$s3_path")
    
    # Compare file sizes
    if [ "$s3_size" = "$local_size" ] && [ "$s3_size" != "0" ]; then
        # Files appear to be the same (size matches)
        log_info "Files match (size: ${local_size} bytes)"
        log_info "  Local: ${local_size} bytes (hash: ${local_hash:0:16}...)"
        log_info "  S3:    ${s3_size} bytes"
        return 0
    else
        # Files differ (size mismatch)
        log_info "Files differ (size mismatch or outdated)"
        log_info "  Local: ${local_size} bytes (hash: ${local_hash:0:16}...)"
        log_info "  S3:    ${s3_size} bytes"
        return 1
    fi
}

# ============================================================================
# Upload CSV to S3 (with change detection)
# ============================================================================
# Usage: upload_csv_to_s3 <local_path> <s3_path> [--force] [--dry-run]
# Returns: 0 on success, 1 on failure
upload_csv_to_s3() {
    local local_csv_path="$1"
    local s3_csv_path="$2"
    local force_upload="${3:-false}"
    local dry_run="${4:-false}"
    local aws_profile="${AWS_PROFILE:-admin}"
    local aws_region="${AWS_REGION:-us-east-1}"
    
    # Check if local CSV exists
    if [ ! -f "$local_csv_path" ]; then
        log_warning "Local CSV file not found: $local_csv_path"
        log_info "Assuming CSV is already in S3 or will be uploaded manually"
        return 0
    fi
    
    log_info "Preparing to upload CSV to S3..."
    log_info "  Source: $local_csv_path"
    log_info "  Destination: $s3_csv_path"
    
    # Get local file info
    local local_info
    local_info=$(get_local_file_info "$local_csv_path")
    local local_size
    local local_hash
    local_size=$(echo "$local_info" | cut -d'|' -f1)
    local_hash=$(echo "$local_info" | cut -d'|' -f2)
    
    # Check if upload is needed (unless forced)
    if [ "$force_upload" != "true" ]; then
        log_info "Checking if CSV needs to be uploaded to S3..."
        if compare_files "$local_csv_path" "$s3_csv_path" false; then
            log_info "CSV file in S3 is up to date (skipping upload)"
            log_info "Use --preempt flag to force upload"
            # Export CSV_WAS_UPLOADED=false to indicate no upload happened
            export CSV_WAS_UPLOADED="false"
            return 0
        fi
    else
        log_warning "Force upload requested (--preempt flag)"
    fi
    
    # Upload needed
    local s3_file_exists=false
    if check_s3_file_exists "$s3_csv_path"; then
        s3_file_exists=true
        if [ "$force_upload" = "true" ]; then
            log_info "Overwriting existing S3 file (force mode)"
        else
            log_info "CSV file in S3 is outdated (uploading latest version)"
        fi
    else
        log_info "CSV file not found in S3 (uploading)"
    fi
    
    if [ "$dry_run" = "true" ]; then
        log_info "  [DRY-RUN] Would upload: $local_csv_path -> $s3_csv_path"
        log_info "  [DRY-RUN] File size: ${local_size} bytes"
        log_info "  [DRY-RUN] File hash: ${local_hash:0:16}..."
        # Export CSV_WAS_UPLOADED=false for dry-run (no actual upload)
        export CSV_WAS_UPLOADED="false"
    else
        log_info "Uploading CSV to S3..."
        
        # aws s3 cp will create the path automatically
        if aws s3 cp "$local_csv_path" "$s3_csv_path" \
            --profile "$aws_profile" \
            --region "$aws_region" \
            --metadata "source=local,hash=${local_hash},size=${local_size}" \
            2>&1; then
            log_success "  ✓ CSV uploaded successfully to S3"
            log_info "  File size: ${local_size} bytes"
            log_info "  File hash: ${local_hash:0:16}..."
            # Export CSV_WAS_UPLOADED=true to indicate upload happened
            export CSV_WAS_UPLOADED="true"
        else
            log_error "Failed to upload CSV to S3"
            # Export CSV_WAS_UPLOADED=false on failure
            export CSV_WAS_UPLOADED="false"
            return 1
        fi
    fi
    
    return 0
}

# Export functions for use by other scripts
export -f check_s3_file_exists
export -f get_local_file_info
export -f get_s3_file_info
export -f compare_files
export -f upload_csv_to_s3

