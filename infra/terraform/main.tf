terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

variable "aws_region" {
  type        = string
  description = "AWS region"
  default     = "us-east-1"
}

variable "fru_bucket_name" {
  type        = string
  description = "S3 bucket name for FRU data"
}

resource "aws_s3_bucket" "fru_data" {
  bucket = var.fru_bucket_name

  tags = {
    Project = "FRU-GenAI"
  }
}

# Skeleton RDS PostgreSQL instance for pgvector (details omitted / to be customised)
variable "db_username" {
  type        = string
  default     = "fru_user"
}

variable "db_password" {
  type        = string
  default     = "ChangeMe123!"
}

resource "aws_db_instance" "fru_pg" {
  allocated_storage    = 20
  engine               = "postgres"
  engine_version       = "16.3"
  instance_class       = "db.t3.micro"
  db_name              = "fru_db"
  username             = var.db_username
  password             = var.db_password
  skip_final_snapshot  = true
  publicly_accessible  = false
}
