"""
Helper function to verify if a Delta table exists.
Works with S3, local filesystem, and EFS paths.

Applicable environment: [local] [aws {ecs | eks}] [azure {aci | aks}] [gcp {cloud-run | gke}]
"""
import os
import logging
from backend.utils.filesystem import exists
from backend.utils.env_helpers import get_optional_env

logger = logging.getLogger(__name__)


def verify_delta_table_exists(delta_path: str, repo_root: str = None, is_ecs_deployment: bool = False, is_eks_deployment: bool = False) -> bool:
    """
    Verify if a Delta table exists by checking for _delta_log directory.
    
    Supports:
    - S3 paths: s3://bucket-name/delta/fru_sales (for AWS deployments)
    - Local paths: data/delta/fru_sales (for local development)
    - Absolute paths: /app/data/delta/fru_sales (for Docker containers)
    
    Args:
        delta_path: Path to Delta table (can be absolute or relative)
        repo_root: Repository root directory (used for relative paths). 
                   If None, will be calculated from environment or default location.
        is_ecs_deployment: True if this is an ECS deployment (uses S3 for Delta tables)
        is_eks_deployment: True if this is an EKS deployment (uses S3 for Delta tables)
    
    Returns:
        bool: True if Delta table exists (has _delta_log directory), False otherwise
    """
    # Get repo_root if not provided
    if repo_root is None:
        repo_root = get_optional_env(
            "REPO_ROOT",
            os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(__file__))))
        )
    
    # Determine if this is an AWS deployment (S3-based)
    is_aws_deployment = is_ecs_deployment or is_eks_deployment
    
    # Construct full path: If delta_path is absolute (starts with s3:// or /), use as-is
    # Otherwise, join with repo_root
    if delta_path.startswith('s3://') or delta_path.startswith('s3a://') or delta_path.startswith('/'):
        delta_full_path = delta_path
    else:
        delta_full_path = os.path.join(repo_root, delta_path)
    
    # For Delta tables, check for _delta_log directory (this is what indicates a Delta table exists)
    # For S3 (AWS deployments): append /_delta_log to the path
    # For local: append /_delta_log to the path
    # Use deployment type (is_aws_deployment) instead of path-based detection for consistency
    if is_aws_deployment:
        delta_log_path = delta_full_path.rstrip('/') + '/_delta_log'
    else:
        delta_log_path = os.path.join(delta_full_path, '_delta_log')
    
    # Check if _delta_log directory exists
    table_exists = exists(delta_log_path)
    
    if not table_exists:
        logger.warning(
            f"Delta table not found at {delta_full_path} "
            f"(checked for _delta_log at {delta_log_path})"
        )
    
    return table_exists

