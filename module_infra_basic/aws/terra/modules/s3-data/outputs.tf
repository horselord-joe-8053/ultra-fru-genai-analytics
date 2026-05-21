output "bucket_id" {
  description = "S3 bucket ID for analytics data"
  value       = aws_s3_bucket.analytics_data.id
}

output "bucket_arn" {
  description = "S3 bucket ARN for analytics data"
  value       = aws_s3_bucket.analytics_data.arn
}

output "delta_table_path" {
  description = "S3 path for Delta tables (use this for DELTA_TABLE_PATH env var)"
  value       = "s3://${aws_s3_bucket.analytics_data.id}/delta"
}

output "raw_data_path" {
  description = "S3 path for raw data files (use this for raw CSV uploads)"
  value       = "s3://${aws_s3_bucket.analytics_data.id}/raw"
}

