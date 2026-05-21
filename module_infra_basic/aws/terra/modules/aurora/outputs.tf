output "cluster_id" {
  description = "Aurora cluster identifier"
  value       = aws_rds_cluster.aurora.cluster_identifier
}

output "cluster_endpoint" {
  description = "Aurora cluster endpoint"
  value       = aws_rds_cluster.aurora.endpoint
}

output "cluster_reader_endpoint" {
  description = "Aurora cluster reader endpoint"
  value       = aws_rds_cluster.aurora.reader_endpoint
}

output "cluster_port" {
  description = "Aurora cluster port"
  value       = aws_rds_cluster.aurora.port
}

output "database_name" {
  description = "Database name"
  value       = aws_rds_cluster.aurora.database_name
}

output "master_username" {
  description = "Master username"
  value       = aws_rds_cluster.aurora.master_username
  sensitive   = true
}

output "security_group_id" {
  description = "Security group ID for Aurora"
  value       = aws_security_group.aurora.id
}

output "cluster_arn" {
  description = "ARN of the Aurora DB cluster (for RDS Data API)"
  value       = aws_rds_cluster.aurora.arn
}

output "iam_auth_enabled" {
  description = "Whether IAM database authentication is enabled"
  value       = aws_rds_cluster.aurora.iam_database_authentication_enabled
}

