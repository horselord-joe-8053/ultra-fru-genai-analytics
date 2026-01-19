# EKS Outputs
output "cluster_id" {
  description = "EKS cluster ID"
  value       = module.eks.cluster_id
}

output "cluster_name" {
  description = "EKS cluster name"
  value       = module.eks.cluster_name
}

output "cluster_arn" {
  description = "EKS cluster ARN"
  value       = module.eks.cluster_arn
}

output "cluster_endpoint" {
  description = "EKS cluster API endpoint"
  value       = module.eks.cluster_endpoint
}

output "cluster_version" {
  description = "Kubernetes version"
  value       = module.eks.cluster_version
}

output "cluster_security_group_id" {
  description = "EKS cluster security group ID"
  value       = module.eks.cluster_security_group_id
}

output "node_security_group_id" {
  description = "EKS node security group ID (if using managed nodes)"
  value       = module.eks.node_security_group_id
}

output "cluster_oidc_issuer_url" {
  description = "OIDC issuer URL for IRSA (IAM Roles for Service Accounts)"
  value       = module.eks.cluster_oidc_issuer_url
}

output "cluster_oidc_provider_arn" {
  description = "OIDC provider ARN for IRSA"
  value       = module.eks.cluster_oidc_provider_arn
}

output "node_group_arn" {
  description = "Node group ARN (if using managed nodes)"
  value       = module.eks.node_group_arn
}

output "fargate_profile_arns" {
  description = "Fargate profile ARNs (if using Fargate)"
  value       = module.eks.fargate_profile_arns
}

output "kubeconfig_command" {
  description = "Command to update kubeconfig for this cluster"
  value       = module.eks.kubeconfig_command
}

output "kms_key_id" {
  description = "KMS key ID used for secrets encryption"
  value       = module.eks.kms_key_id
}

# Frontend Outputs
output "cloudfront_domain_name" {
  description = "CloudFront domain name"
  value       = module.frontend.cloudfront_domain_name
}

output "s3_bucket_id" {
  description = "S3 bucket ID for frontend"
  value       = module.frontend.s3_bucket_id
}

