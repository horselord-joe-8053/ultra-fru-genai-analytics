"""
Centralized Spark configuration.
Single source of truth for S3A config and Spark packages.
"""
import os
from typing import List


def get_s3a_spark_config() -> List[str]:
    """
    Returns S3A configuration flags for Spark.
    These are required for Spark to access S3 via S3A filesystem.
    """
    return [
        "--conf", "spark.hadoop.fs.s3a.impl=org.apache.hadoop.fs.s3a.S3AFileSystem",
        "--conf", "spark.hadoop.fs.s3a.aws.credentials.provider=org.apache.hadoop.fs.s3a.auth.IAMInstanceCredentialsProvider",
        "--conf", "spark.hadoop.fs.s3a.connection.timeout=60000",
        "--conf", "spark.hadoop.fs.s3a.connection.establish.timeout=5000",
        "--conf", "spark.hadoop.fs.s3a.connection.maximum=15",
        "--conf", "spark.hadoop.fs.s3a.attempts.maximum=3",
        "--conf", "spark.hadoop.fs.s3a.retry.interval=1000",
        "--conf", "spark.hadoop.fs.s3a.threads.max=10",
        "--conf", "spark.hadoop.fs.s3a.threads.core=5",
        "--conf", "spark.hadoop.fs.s3a.threads.keepalivetime=60",
        "--conf", "spark.hadoop.fs.s3a.multipart.uploads.expiration=86400",
        "--conf", "spark.hadoop.fs.s3a.multipart.purge.age=86400",
        "--conf", "spark.hadoop.fs.s3a.fast.upload=true",
        "--conf", "spark.hadoop.fs.s3a.block.size=134217728",
    ]


def get_spark_packages(is_aws_deployment: bool) -> str:
    """
    Returns Spark packages string.
    
    Args:
        is_aws_deployment: True if this is an AWS deployment (ECS/EKS)
    
    Returns:
        str: Comma-separated list of Maven coordinates for Spark packages
    """
    base = os.getenv("DELTA_LAKE_PACKAGE")
    if not base:
        raise ValueError("DELTA_LAKE_PACKAGE environment variable is required")
    
    if is_aws_deployment:
        return f"{base},org.apache.hadoop:hadoop-aws:3.3.6,com.amazonaws:aws-java-sdk-bundle:1.12.470"
    return base


def to_spark_path(path: str) -> str:
    """
    Convert s3:// to s3a:// for Spark compatibility.
    Spark uses s3a:// filesystem, not s3://
    
    Args:
        path: Path that may start with s3://
    
    Returns:
        str: Path with s3:// converted to s3a:// if needed
    """
    return path.replace("s3://", "s3a://", 1) if path.startswith("s3://") else path

