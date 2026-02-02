# Infrastructure Layer (ephemeral: VPC, Aurora, IAM, S3).
# Secrets Manager lives in the infrastructure-longterm layer; we read secret ARNs via remote_state.
# Main teardown destroys this layer only; longterm is never destroyed (Option B).

# Long-term layer state: secret ARNs. Do not destroy that layer in main teardown (docs/learned/TERRA_LEARNED.md Option B).
data "terraform_remote_state" "longterm" {
  backend = "s3"
  config = {
    bucket  = var.tf_state_bucket
    key     = "${var.environment}/infrastructure-longterm/terraform.tfstate"
    region  = var.aws_region
    encrypt = true
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

# IAM Module (secret ARNs from longterm layer)
module "iam" {
  source = "../iam"

  project_name                 = var.project_name
  environment                  = var.environment
  openai_secret_arn            = data.terraform_remote_state.longterm.outputs.openai_secret_arn
  openai_secret_plain_arn      = data.terraform_remote_state.longterm.outputs.openai_secret_plain_arn
  db_password_secret_arn       = data.terraform_remote_state.longterm.outputs.db_password_secret_arn
  db_password_plain_secret_arn = data.terraform_remote_state.longterm.outputs.db_password_plain_secret_arn
  db_username_secret_arn       = try(data.terraform_remote_state.longterm.outputs.db_username_secret_arn, "")
  enable_rds_iam_auth          = var.enable_iam_auth
  rds_db_resource_arn          = var.enable_iam_auth ? "arn:aws:rds-db:${var.aws_region}:${data.aws_caller_identity.current.account_id}:dbuser:${var.project_name}-${var.environment}-aurora-cluster/${var.db_username}" : ""

  # Bedrock permissions: allow inference profiles if configured
  bedrock_inference_profile_arns = var.bedrock_inference_profile_id != "" ? [
    "arn:aws:bedrock:${var.aws_region}:${data.aws_caller_identity.current.account_id}:inference-profile/${var.bedrock_inference_profile_id}"
  ] : null

  # S3 permissions: allow access to analytics data bucket
  s3_data_bucket_arn = module.s3_data.bucket_arn

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

# S3 Data Bucket Module (for Delta tables and raw data)
module "s3_data" {
  source = "../s3-data"

  project_name = var.project_name
  environment  = var.environment

  tags = var.tags
}

# Data source for current AWS account
data "aws_caller_identity" "current" {}

