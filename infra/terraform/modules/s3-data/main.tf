# S3 Bucket for Analytics Data (Delta tables and raw data)
# This bucket stores:
# - Raw CSV files: s3://bucket/raw/
# - Delta tables: s3://bucket/delta/

resource "aws_s3_bucket" "analytics_data" {
  bucket = "${var.project_name}-${var.environment}-analytics-data-${data.aws_caller_identity.current.account_id}"

  tags = merge(
    var.tags,
    {
      Name        = "${var.project_name}-${var.environment}-analytics-data"
      Description = "S3 bucket for analytics data (raw CSV and Delta tables)"
    }
  )
}

# S3 Bucket Versioning (enable for Delta table history)
resource "aws_s3_bucket_versioning" "analytics_data" {
  bucket = aws_s3_bucket.analytics_data.id

  versioning_configuration {
    status = "Enabled"
  }
}

# S3 Bucket Server-Side Encryption
resource "aws_s3_bucket_server_side_encryption_configuration" "analytics_data" {
  bucket = aws_s3_bucket.analytics_data.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# S3 Bucket Public Access Block (keep private)
resource "aws_s3_bucket_public_access_block" "analytics_data" {
  bucket = aws_s3_bucket.analytics_data.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Data source for AWS account ID
data "aws_caller_identity" "current" {}

