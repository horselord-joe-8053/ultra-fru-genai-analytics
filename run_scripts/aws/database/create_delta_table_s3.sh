#!/bin/bash
# Create Delta table in S3 from CSV file
# This script uploads raw CSV to S3 and converts it to Delta Lake format in S3
# Usage: ./create_delta_table_s3.sh [csv_file] [s3_delta_path]
#
# Example:
#   ./create_delta_table_s3.sh data/raw/fridge_sales_with_rating.csv s3://fru-dev-analytics-data-123456789012/delta/fru_sales

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
source "$SCRIPT_DIR/../../common/logger.sh"
source "$SCRIPT_DIR/../../common/load-env.sh"

# Load environment variables
load_env_file || true

# Default values
DEFAULT_CSV_FILE="$REPO_ROOT/data/raw/fridge_sales_with_rating.csv"
DEFAULT_S3_DELTA_PATH="s3://fru-dev-analytics-data-$(aws sts get-caller-identity --profile admin --query Account --output text 2>/dev/null || echo 'ACCOUNT')/delta/fru_sales"

# Get parameters
CSV_FILE="${1:-$DEFAULT_CSV_FILE}"
S3_DELTA_PATH="${2:-$DEFAULT_S3_DELTA_PATH}"

# Extract bucket and path from S3 URI
if [[ ! "$S3_DELTA_PATH" =~ ^s3://([^/]+)/(.+)$ ]]; then
    log_error "Invalid S3 path format: $S3_DELTA_PATH"
    log_error "Expected format: s3://bucket-name/path/to/delta/table"
    exit 1
fi

S3_BUCKET="${BASH_REMATCH[1]}"
S3_PATH="${BASH_REMATCH[2]}"
S3_RAW_PATH="s3://$S3_BUCKET/raw"

log_step "Creating Delta table in S3"
log_info "CSV file: $CSV_FILE"
log_info "S3 Delta path: $S3_DELTA_PATH"
log_info "S3 Raw path: $S3_RAW_PATH"

# Check if CSV file exists
if [ ! -f "$CSV_FILE" ]; then
    log_error "CSV file not found: $CSV_FILE"
    exit 1
fi

# Check AWS credentials
if ! aws sts get-caller-identity --profile admin >/dev/null 2>&1; then
    log_error "AWS credentials not configured. Please set AWS_PROFILE or run 'aws configure'"
    exit 1
fi

# Step 1: Upload CSV to S3 raw data path
log_step "Step 1/2: Uploading CSV to S3 raw data path"
CSV_FILENAME=$(basename "$CSV_FILE")
S3_CSV_PATH="$S3_RAW_PATH/$CSV_FILENAME"

log_info "Uploading $CSV_FILE to $S3_CSV_PATH"
aws s3 cp "$CSV_FILE" "$S3_CSV_PATH" --profile admin || {
    log_error "Failed to upload CSV to S3"
    exit 1
}
log_success "CSV uploaded to S3: $S3_CSV_PATH"

# Step 2: Convert CSV to Delta format in S3 using Spark
log_step "Step 2/2: Converting CSV to Delta format in S3"
log_info "This will run a Spark job to convert CSV to Delta Lake format"

# Require Delta Lake package from environment (.env is source of truth, no defaults)
if ! require_delta_lake_package; then
    exit 1
fi

# Try Docker container first (has Spark 4.0.1 with compatible Delta Lake)
if docker ps >/dev/null 2>&1 && docker ps --filter "name=fru_api" --format "{{.Names}}" | grep -q "fru_api"; then
    log_info "Using Spark in Docker container (fru_api) to create Delta table in S3"
    
    # Check if container has Spark installed
    if docker exec fru_api test -f /opt/spark/bin/spark-submit 2>/dev/null; then
        # Use s3a:// protocol for Spark (Hadoop S3 filesystem)
        S3A_CSV_PATH=$(echo "$S3_CSV_PATH" | sed 's|^s3://|s3a://|')
        S3A_DELTA_PATH=$(echo "$S3_DELTA_PATH" | sed 's|^s3://|s3a://|')
        
        log_info "Using s3a:// protocol for Spark (S3A filesystem)"
        log_info "  CSV path: $S3A_CSV_PATH"
        log_info "  Delta path: $S3A_DELTA_PATH"
        
        # Run Spark job in Docker container
        # The container should have AWS credentials configured via IAM role or environment
        docker exec -w /app -e AWS_PROFILE=admin -e DELTA_LAKE_PACKAGE="$DELTA_LAKE_PACKAGE" fru_api \
            /opt/spark/bin/spark-submit \
            --packages "$DELTA_LAKE_PACKAGE" \
            --conf "spark.hadoop.fs.s3a.impl=org.apache.hadoop.fs.s3a.S3AFileSystem" \
            --conf "spark.hadoop.fs.s3a.aws.credentials.provider=com.amazonaws.auth.DefaultAWSCredentialsProviderChain" \
            /app/spark_jobs/ingest_delta.py \
            "$S3A_CSV_PATH" \
            "$S3A_DELTA_PATH" || {
            log_warning "Failed to create Delta table using Docker Spark"
            log_info "Falling back to local processing..."
            # Fall through to local processing
        } && {
            log_success "Delta table created in S3: $S3_DELTA_PATH"
            exit 0
        }
    fi
fi

# Fallback: Use local Spark (download, process, upload)
if command -v spark-submit >/dev/null 2>&1; then
    log_info "Using local Spark to create Delta table (downloading from S3, processing locally, uploading back)"
    
    # For local Spark, download CSV from S3, process locally, then upload Delta table
    # This avoids S3 filesystem dependency issues with local Spark
    TEMP_DIR=$(mktemp -d)
    LOCAL_CSV="$TEMP_DIR/$(basename "$S3_CSV_PATH")"
    LOCAL_DELTA="$TEMP_DIR/delta_fru_sales"
    
    log_info "Downloading CSV from S3 to local temp directory..."
    aws s3 cp "$S3_CSV_PATH" "$LOCAL_CSV" --profile admin || {
        log_error "Failed to download CSV from S3"
        rm -rf "$TEMP_DIR"
        exit 1
    }
    
    log_info "Converting CSV to Delta format locally..."
    log_info "Using Delta Lake package: $DELTA_LAKE_PACKAGE"
    
    if spark-submit \
        --packages "$DELTA_LAKE_PACKAGE" \
        "$REPO_ROOT/spark_jobs/ingest_delta.py" \
        "$LOCAL_CSV" \
        "$LOCAL_DELTA"; then
        log_success "Delta table created successfully"
    else
        log_error "Failed to create Delta table using local Spark"
        log_info "Check that DELTA_LAKE_PACKAGE in .env is compatible with your Spark version"
        log_info "Standard combination: io.delta:delta-spark_2.13:4.0.0 (Spark 4.0.1 + Delta Lake 4.0.0 + Scala 2.13)"
        rm -rf "$TEMP_DIR"
        exit 1
    fi
    
    log_info "Uploading Delta table to S3..."
    aws s3 sync "$LOCAL_DELTA" "$S3_DELTA_PATH" --profile admin --delete || {
        log_error "Failed to upload Delta table to S3"
        rm -rf "$TEMP_DIR"
        exit 1
    }
    
    # Cleanup
    rm -rf "$TEMP_DIR"
    
    log_success "Delta table created in S3: $S3_DELTA_PATH"
else
    log_error "Neither Docker container (fru_api) nor local spark-submit is available"
    log_info "Please start Docker services or install Spark locally"
    log_info ""
    log_info "To start Docker services:"
    log_info "  ./run_scripts/local/start-services.sh"
    log_info ""
    log_info "Alternatively, you can run this conversion from an ECS task or EC2 instance with Spark installed"
    log_info "Or use AWS Glue or EMR to run the Spark job"
    exit 1
fi

log_success "Delta table creation complete!"
log_info "Delta table path: $S3_DELTA_PATH"
log_info "Use this path for DELTA_TABLE_PATH environment variable in ECS task definition"

