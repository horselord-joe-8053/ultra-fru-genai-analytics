output "cluster_id" {
  description = "EKS cluster ID"
  value       = aws_eks_cluster.main.id
}

output "cluster_name" {
  description = "EKS cluster name"
  value       = aws_eks_cluster.main.name
}

output "cluster_arn" {
  description = "EKS cluster ARN"
  value       = aws_eks_cluster.main.arn
}

output "cluster_endpoint" {
  description = "EKS cluster API endpoint"
  value       = aws_eks_cluster.main.endpoint
}

output "cluster_version" {
  description = "Kubernetes version"
  value       = aws_eks_cluster.main.version
}

output "cluster_security_group_id" {
  description = "EKS cluster security group ID"
  value       = aws_security_group.eks_cluster.id
}

output "node_security_group_id" {
  description = "EKS node security group ID (if using managed nodes)"
  value       = var.enable_fargate ? null : aws_security_group.eks_nodes.id
}

output "cluster_oidc_issuer_url" {
  description = "OIDC issuer URL for IRSA (IAM Roles for Service Accounts)"
  value       = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

output "cluster_oidc_provider_arn" {
  description = "OIDC provider ARN for IRSA"
  value       = aws_iam_openid_connect_provider.eks.arn
}

output "node_group_arn" {
  description = "Node group ARN (if using managed nodes)"
  value       = var.enable_fargate ? null : (length(aws_eks_node_group.main) > 0 ? aws_eks_node_group.main[0].arn : null)
}

output "fargate_profile_arns" {
  description = "Fargate profile ARNs (if using Fargate)"
  value       = var.enable_fargate ? { for k, v in aws_eks_fargate_profile.main : k => v.arn } : {}
}

output "kubeconfig_command" {
  description = "Command to update kubeconfig for this cluster"
  value       = "aws eks update-kubeconfig --region ${var.aws_region} --name ${aws_eks_cluster.main.name} --profile admin"
}

output "kms_key_id" {
  description = "KMS key ID used for secrets encryption"
  value       = var.enable_secrets_encryption ? (var.kms_key_id != null ? var.kms_key_id : aws_kms_key.eks_secrets[0].id) : null
}

