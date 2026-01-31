# EKS Cluster Module
# Creates: EKS cluster, node groups (or Fargate profiles), OIDC provider, security groups

# Data source for current AWS account
data "aws_caller_identity" "current" {}

# Security Group for EKS Cluster
resource "aws_security_group" "eks_cluster" {
  name        = "${var.project_name}-${var.environment}-eks-cluster-sg"
  description = "Security group for EKS cluster"
  vpc_id      = var.vpc_id

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(
    var.tags,
    {
      Name = "${var.project_name}-${var.environment}-eks-cluster-sg"
    }
  )
}

# Security Group Rule: Allow cluster to communicate with nodes
resource "aws_security_group_rule" "cluster_to_node" {
  type                     = "egress"
  from_port                = 1025
  to_port                  = 65535
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.eks_nodes.id
  security_group_id        = aws_security_group.eks_cluster.id
  description              = "Allow cluster to communicate with nodes"
}

# Security Group for EKS Nodes (if using managed node groups)
resource "aws_security_group" "eks_nodes" {
  name        = "${var.project_name}-${var.environment}-eks-nodes-sg"
  description = "Security group for EKS nodes"
  vpc_id      = var.vpc_id

  ingress {
    description     = "Allow inbound from cluster"
    from_port       = 1025
    to_port         = 65535
    protocol        = "tcp"
    security_groups = [aws_security_group.eks_cluster.id]
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(
    var.tags,
    {
      Name = "${var.project_name}-${var.environment}-eks-nodes-sg"
      "kubernetes.io/cluster/${var.project_name}-${var.environment}-cluster" = "owned"
    }
  )
}

# IAM Role for EKS Cluster
resource "aws_iam_role" "eks_cluster" {
  name = "${var.project_name}-${var.environment}-eks-cluster-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "eks.amazonaws.com"
        }
      }
    ]
  })

  tags = merge(
    var.tags,
    {
      Name = "${var.project_name}-${var.environment}-eks-cluster-role"
    }
  )
}

# Attach AWS managed policy for EKS cluster
resource "aws_iam_role_policy_attachment" "eks_cluster_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = aws_iam_role.eks_cluster.name
}

# IAM Role for EKS Node Group (if using managed nodes OR ingress node group)
resource "aws_iam_role" "eks_node_group" {
  count = var.enable_fargate && !var.enable_ingress_node_group ? 0 : 1
  name  = "${var.project_name}-${var.environment}-eks-node-group-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })

  tags = merge(
    var.tags,
    {
      Name = "${var.project_name}-${var.environment}-eks-node-group-role"
    }
  )
}

# Attach AWS managed policies for node group
resource "aws_iam_role_policy_attachment" "eks_worker_node_policy" {
  count      = var.enable_fargate && !var.enable_ingress_node_group ? 0 : 1
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role       = aws_iam_role.eks_node_group[0].name
}

resource "aws_iam_role_policy_attachment" "eks_cni_policy" {
  count      = var.enable_fargate && !var.enable_ingress_node_group ? 0 : 1
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = aws_iam_role.eks_node_group[0].name
}

resource "aws_iam_role_policy_attachment" "eks_container_registry_policy" {
  count      = var.enable_fargate && !var.enable_ingress_node_group ? 0 : 1
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  role       = aws_iam_role.eks_node_group[0].name
}

# IAM Role for Fargate Pod Execution (if using Fargate)
resource "aws_iam_role" "eks_fargate_pod_execution" {
  count = var.enable_fargate ? 1 : 0
  name  = "${var.project_name}-${var.environment}-eks-fargate-pod-execution-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "eks-fargate-pods.amazonaws.com"
        }
      }
    ]
  })

  tags = merge(
    var.tags,
    {
      Name = "${var.project_name}-${var.environment}-eks-fargate-pod-execution-role"
    }
  )
}

resource "aws_iam_role_policy_attachment" "eks_fargate_pod_execution_policy" {
  count      = var.enable_fargate ? 1 : 0
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSFargatePodExecutionRolePolicy"
  role       = aws_iam_role.eks_fargate_pod_execution[0].name
}

# KMS Key for Secrets Encryption (if enabled)
resource "aws_kms_key" "eks_secrets" {
  count       = var.enable_secrets_encryption && var.kms_key_id == null ? 1 : 0
  description = "KMS key for EKS secrets encryption"

  tags = merge(
    var.tags,
    {
      Name = "${var.project_name}-${var.environment}-eks-secrets-key"
    }
  )
}

resource "aws_kms_alias" "eks_secrets" {
  count         = var.enable_secrets_encryption && var.kms_key_id == null ? 1 : 0
  name          = "alias/${var.project_name}-${var.environment}-eks-secrets"
  target_key_id = aws_kms_key.eks_secrets[0].key_id
}

# EKS Cluster
resource "aws_eks_cluster" "main" {
  name     = "${var.project_name}-${var.environment}-cluster"
  role_arn = aws_iam_role.eks_cluster.arn
  version  = var.cluster_version

  vpc_config {
    subnet_ids              = concat(var.private_subnet_ids, var.public_subnet_ids)
    security_group_ids      = [aws_security_group.eks_cluster.id]
    endpoint_private_access = var.endpoint_private_access
    endpoint_public_access  = var.endpoint_public_access
    public_access_cidrs    = var.endpoint_public_access ? var.endpoint_public_access_cidrs : []
  }

  # Encryption configuration
  dynamic "encryption_config" {
    for_each = var.enable_secrets_encryption ? [1] : []
    content {
      provider {
        key_arn = var.kms_key_id != null ? var.kms_key_id : aws_kms_key.eks_secrets[0].arn
      }
      resources = ["secrets"]
    }
  }

  # Logging configuration
  enabled_cluster_log_types = var.enabled_cluster_log_types

  depends_on = [
    aws_iam_role_policy_attachment.eks_cluster_policy,
    aws_cloudwatch_log_group.eks_cluster
  ]

  tags = merge(
    var.tags,
    {
      Name = "${var.project_name}-${var.environment}-cluster"
    }
  )
}

# CloudWatch Log Group for EKS
resource "aws_cloudwatch_log_group" "eks_cluster" {
  name              = "/aws/eks/${var.project_name}-${var.environment}-cluster/cluster"
  retention_in_days = 7

  tags = merge(
    var.tags,
    {
      Name = "${var.project_name}-${var.environment}-eks-logs"
    }
  )
}

# OIDC Provider for IRSA (IAM Roles for Service Accounts)
data "tls_certificate" "eks" {
  url = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "eks" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks.certificates[0].sha1_fingerprint]
  url             = aws_eks_cluster.main.identity[0].oidc[0].issuer

  tags = merge(
    var.tags,
    {
      Name = "${var.project_name}-${var.environment}-eks-oidc"
    }
  )
}

# Managed Node Group (if not using Fargate OR if using ingress node group)
resource "aws_eks_node_group" "main" {
  count           = var.enable_fargate && !var.enable_ingress_node_group ? 0 : 1
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = var.enable_ingress_node_group ? "${var.project_name}-${var.environment}-ingress-node-group" : "${var.project_name}-${var.environment}-node-group"
  node_role_arn   = aws_iam_role.eks_node_group[0].arn
  subnet_ids      = var.private_subnet_ids

  instance_types = var.node_group_instance_types
  disk_size      = var.node_group_disk_size

  scaling_config {
    desired_size = var.node_group_desired_size
    min_size     = var.node_group_min_size
    max_size     = var.node_group_max_size
  }

  update_config {
    max_unavailable = 1
  }

  # Labels for ingress isolation (if ingress node group)
  # Note: Taints must be applied via kubectl after node group creation:
  # kubectl taint nodes -l role=ingress ingress-only=true:NoSchedule
  labels = var.enable_ingress_node_group ? {
    role = "ingress"
  } : {}

  # Ensure that IAM Role permissions are created before and deleted after EKS Node Group handling.
  # Otherwise, EKS will not be able to properly delete EC2 Instances and Elastic Network Interfaces.
  depends_on = [
    aws_iam_role_policy_attachment.eks_worker_node_policy,
    aws_iam_role_policy_attachment.eks_cni_policy,
    aws_iam_role_policy_attachment.eks_container_registry_policy,
  ]

  tags = merge(
    var.tags,
    {
      Name = var.enable_ingress_node_group ? "${var.project_name}-${var.environment}-ingress-node-group" : "${var.project_name}-${var.environment}-node-group"
    }
  )
}

# Fargate Profiles (if using Fargate)
resource "aws_eks_fargate_profile" "main" {
  for_each               = var.enable_fargate ? { for profile in var.fargate_profiles : profile.name => profile } : {}
  cluster_name           = aws_eks_cluster.main.name
  fargate_profile_name   = each.value.name
  pod_execution_role_arn = aws_iam_role.eks_fargate_pod_execution[0].arn
  subnet_ids             = var.private_subnet_ids

  dynamic "selector" {
    for_each = each.value.selectors
    content {
      namespace = selector.value.namespace
      labels    = selector.value.labels
    }
  }

  tags = merge(
    var.tags,
    {
      Name = "${var.project_name}-${var.environment}-fargate-${each.value.name}"
    }
  )
}

# Security Group Rule: Allow EKS pods to connect to Aurora
# Similar to ECS module, this allows pods to connect to Aurora on port 5432
# For Fargate pods, they use the AWS-managed cluster security group (vpc_config[0].cluster_security_group_id)
# For managed nodes, pods use node security group
resource "aws_security_group_rule" "aurora_from_eks" {
  count = var.aurora_security_group_id != null ? 1 : 0
  
  type                     = "ingress"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  # For Fargate, pods use the AWS-managed cluster security group (created by EKS)
  # This is different from aws_security_group.eks_cluster (which is for cluster-to-node communication)
  # The cluster's vpc_config.cluster_security_group_id is the one attached to Fargate pod ENIs
  source_security_group_id = var.enable_fargate ? aws_eks_cluster.main.vpc_config[0].cluster_security_group_id : aws_security_group.eks_nodes.id
  security_group_id        = var.aurora_security_group_id
  description              = "PostgreSQL from EKS pods (${var.enable_fargate ? "Fargate" : "Node Group"})"
}

# ============================================================================
# Frontend Module
# ============================================================================

module "frontend" {
  source = "../frontend"

  project_name = var.project_name
  environment  = var.environment
  container_type = var.container_type # Pass container_type to create separate frontend instances

  enable_versioning = var.enable_frontend_versioning
  cloudfront_price_class = var.cloudfront_price_class
  certificate_arn   = var.frontend_certificate_arn
  api_origin_id     = var.frontend_api_origin_id
  # Note: alb_dns_name is optional - for EKS, ALB DNS comes from Kubernetes Ingress
  # Can be set later if needed (e.g., via data source or manual update)
  alb_dns_name      = var.alb_dns_name

  tags = var.tags
}

