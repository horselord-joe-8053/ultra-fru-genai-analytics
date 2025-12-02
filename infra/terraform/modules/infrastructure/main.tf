# Infrastructure Layer
# Combines: VPC, Aurora, IAM, Secrets Manager

terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# VPC Module
module "vpc" {
  source = "../vpc"

  project_name      = var.project_name
  environment       = var.environment
  aws_region        = var.aws_region
  vpc_cidr          = var.vpc_cidr
  availability_zones = var.availability_zones

  enable_nat_gateway         = var.enable_nat_gateway
  enable_bedrock_vpc_endpoint = var.enable_bedrock_vpc_endpoint

  tags = var.tags
}

# Secrets Manager Module (must be created before IAM and Aurora)
module "secrets_manager" {
  source = "../secrets-manager"

  project_name     = var.project_name
  environment      = var.environment
  openai_api_key   = var.openai_api_key
  db_password      = var.db_password
  db_username      = var.db_username
  create_db_username_secret = var.create_db_username_secret

  tags = var.tags
}

# IAM Module (depends on Secrets Manager for ARNs)
module "iam" {
  source = "../iam"

  project_name            = var.project_name
  environment             = var.environment
  openai_secret_arn       = module.secrets_manager.openai_secret_arn
  db_password_secret_arn  = module.secrets_manager.db_password_secret_arn
  enable_rds_iam_auth     = var.enable_iam_auth
  rds_db_resource_arn     = var.enable_iam_auth ? "arn:aws:rds-db:${var.aws_region}:${data.aws_caller_identity.current.account_id}:dbuser:${var.project_name}-${var.environment}-aurora-cluster/${var.db_username}" : ""

  tags = var.tags
}

# Aurora Module (depends on VPC and IAM)
# Note: We need a placeholder security group for Aurora initially
# The actual ECS security group will be created in the application layer
# For now, we'll create a temporary security group that will be updated later
resource "aws_security_group" "ecs_placeholder" {
  name        = "${var.project_name}-${var.environment}-ecs-placeholder-sg"
  description = "Placeholder security group for ECS (will be replaced in application layer)"
  vpc_id      = module.vpc.vpc_id

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
      Name = "${var.project_name}-${var.environment}-ecs-placeholder-sg"
    }
  )
}

module "aurora" {
  source = "../aurora"

  project_name         = var.project_name
  environment          = var.environment
  vpc_id               = module.vpc.vpc_id
  private_subnet_ids   = module.vpc.private_subnet_ids
  ecs_security_group_id = aws_security_group.ecs_placeholder.id

  database_name    = var.aurora_database_name
  master_username   = var.db_username
  master_password   = var.db_password
  engine_version    = var.aurora_engine_version
  instance_class   = var.aurora_instance_class
  instance_count   = var.aurora_instance_count
  min_capacity     = var.aurora_min_capacity
  max_capacity     = var.aurora_max_capacity

  enable_iam_auth         = var.enable_iam_auth
  enable_enhanced_monitoring = var.enable_enhanced_monitoring
  backup_retention_period  = var.aurora_backup_retention_period
  preferred_backup_window  = var.aurora_preferred_backup_window
  kms_key_id              = var.aurora_kms_key_id
  deletion_protection     = var.deletion_protection

  tags = var.tags
}

# Data source for current AWS account
data "aws_caller_identity" "current" {}

