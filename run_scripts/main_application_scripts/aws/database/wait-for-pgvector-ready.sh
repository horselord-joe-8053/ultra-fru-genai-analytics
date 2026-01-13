#!/bin/bash
# Wait for pgvector extension to be fully ready
# This function checks not just if the extension exists, but if it's actually usable
# Usage: wait_for_pgvector_ready <cluster_arn> <secret_arn> <db_name> [max_wait_seconds] [check_interval_seconds]

set -euo pipefail

wait_for_pgvector_ready() {
    local cluster_arn="$1"
    local secret_arn="$2"
    local db_name="$3"
    local max_wait="${4:-60}"  # Default: 60 seconds max wait
    local check_interval="${5:-2}"  # Default: check every 2 seconds
    local aws_profile="${AWS_PROFILE:-admin}"
    local aws_region="${AWS_REGION:-us-east-1}"
    
    local start_time=$(date +%s)
    local attempt=0
    
    log_info "Waiting for pgvector extension to be fully ready..."
    log_info "  Max wait time: ${max_wait}s, Check interval: ${check_interval}s"
    
    while true; do
        attempt=$((attempt + 1))
        local elapsed=$(($(date +%s) - start_time))
        
        if [ $elapsed -ge $max_wait ]; then
            log_error "Timeout: pgvector extension did not become ready within ${max_wait} seconds"
            return 1
        fi
        
        # Check 1: Extension exists in pg_extension
        log_info "  Attempt ${attempt}: Checking if pgvector extension exists..."
        local extension_exists=false
        local check_result
        
        if check_result=$(aws rds-data execute-statement \
            --resource-arn "$cluster_arn" \
            --secret-arn "$secret_arn" \
            --database "$db_name" \
            --sql "SELECT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'vector');" \
            --profile "$aws_profile" \
            --region "$aws_region" \
            --output text \
            --query 'records[0][0].booleanValue' 2>&1); then
            if [ "$check_result" = "True" ] || [ "$check_result" = "true" ] || [ "$check_result" = "1" ]; then
                extension_exists=true
                log_info "    ✓ Extension exists in pg_extension"
            else
                log_info "    ✗ Extension not found in pg_extension (waiting...)"
                sleep "$check_interval"
                continue
            fi
        else
            log_warning "    ⚠ Could not check extension existence: $(echo "$check_result" | head -c 100)"
            sleep "$check_interval"
            continue
        fi
        
        # Check 2: VECTOR type is available in pg_type
        log_info "  Attempt ${attempt}: Checking if VECTOR type is available..."
        local vector_type_exists=false
        
        if check_result=$(aws rds-data execute-statement \
            --resource-arn "$cluster_arn" \
            --secret-arn "$secret_arn" \
            --database "$db_name" \
            --sql "SELECT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'vector');" \
            --profile "$aws_profile" \
            --region "$aws_region" \
            --output text \
            --query 'records[0][0].booleanValue' 2>&1); then
            if [ "$check_result" = "True" ] || [ "$check_result" = "true" ] || [ "$check_result" = "1" ]; then
                vector_type_exists=true
                log_info "    ✓ VECTOR type is available"
            else
                log_info "    ✗ VECTOR type not found (waiting...)"
                sleep "$check_interval"
                continue
            fi
        else
            log_warning "    ⚠ Could not check VECTOR type: $(echo "$check_result" | head -c 100)"
            sleep "$check_interval"
            continue
        fi
        
        # Check 3: Can actually create a table with VECTOR column (most reliable test)
        log_info "  Attempt ${attempt}: Testing VECTOR column creation..."
        local test_table_name="__pgvector_readiness_test_$(date +%s)_$$"
        
        # Try to create a test table with VECTOR column
        if aws rds-data execute-statement \
            --resource-arn "$cluster_arn" \
            --secret-arn "$secret_arn" \
            --database "$db_name" \
            --sql "CREATE TABLE IF NOT EXISTS ${test_table_name} (id INT, vec VECTOR(1536));" \
            --profile "$aws_profile" \
            --region "$aws_region" >/dev/null 2>&1; then
            log_info "    ✓ Successfully created test table with VECTOR column"
            
            # Verify the column was actually created with VECTOR type
            if verify_result=$(aws rds-data execute-statement \
                --resource-arn "$cluster_arn" \
                --secret-arn "$secret_arn" \
                --database "$db_name" \
                --sql "SELECT data_type FROM information_schema.columns WHERE table_name = '${test_table_name}' AND column_name = 'vec';" \
                --profile "$aws_profile" \
                --region "$aws_region" \
                --output text \
                --query 'records[0][0].stringValue' 2>&1); then
                
                # Clean up test table
                aws rds-data execute-statement \
                    --resource-arn "$cluster_arn" \
                    --secret-arn "$secret_arn" \
                    --database "$db_name" \
                    --sql "DROP TABLE IF EXISTS ${test_table_name};" \
                    --profile "$aws_profile" \
                    --region "$aws_region" >/dev/null 2>&1 || true
                
                if echo "$verify_result" | grep -qi "vector\|USER-DEFINED"; then
                    log_success "✓ pgvector extension is fully ready! (took ${elapsed}s)"
                    return 0
                else
                    log_warning "    ⚠ Test table created but column type is '${verify_result}' (not VECTOR)"
                    log_warning "    This suggests extension exists but VECTOR type isn't fully available"
                    sleep "$check_interval"
                    continue
                fi
            else
                # Clean up test table even if verification failed
                aws rds-data execute-statement \
                    --resource-arn "$cluster_arn" \
                    --secret-arn "$secret_arn" \
                    --database "$db_name" \
                    --sql "DROP TABLE IF EXISTS ${test_table_name};" \
                    --profile "$aws_profile" \
                    --region "$aws_region" >/dev/null 2>&1 || true
                
                log_warning "    ⚠ Could not verify test table column type"
                sleep "$check_interval"
                continue
            fi
        else
            log_info "    ✗ Failed to create test table with VECTOR column (waiting...)"
            sleep "$check_interval"
            continue
        fi
    done
}

# If executed directly (for testing)
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    # Source logger if available
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
    if [ -f "$REPO_ROOT/run_scripts/shared/logger.sh" ]; then
        source "$REPO_ROOT/run_scripts/shared/logger.sh"
    else
        # Fallback logging functions
        log_info() { echo "[INFO] $*"; }
        log_success() { echo "[SUCCESS] $*"; }
        log_warning() { echo "[WARNING] $*"; }
        log_error() { echo "[ERROR] $*"; }
    fi
    
    if [ $# -lt 3 ]; then
        echo "Usage: $0 <cluster_arn> <secret_arn> <db_name> [max_wait_seconds] [check_interval_seconds]"
        exit 1
    fi
    
    wait_for_pgvector_ready "$@"
fi

