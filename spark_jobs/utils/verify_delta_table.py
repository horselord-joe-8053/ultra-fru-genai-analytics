"""
Helper function to verify if a Delta table exists.
Works with S3, local filesystem, and EFS paths.

Applicable environment: [local] [aws {ecs | eks}] [azure {aci | aks}] [gcp {cloud-run | gke}]
"""
import os
import logging
from spark_jobs.utils.filesystem import exists
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
    logger.debug(
        f"verify_delta_table_exists() called with: "
        f"delta_path={delta_path}, repo_root={repo_root}, "
        f"is_ecs_deployment={is_ecs_deployment}, is_eks_deployment={is_eks_deployment}"
    )
    
    # Get repo_root if not provided (calculate from file location)
    if repo_root is None:
        # spark_jobs/utils/verify_delta_table.py -> spark_jobs/utils -> spark_jobs -> repo_root
        computed_repo_root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
        repo_root = get_optional_env("REPO_ROOT", computed_repo_root)
    
    # Determine deployment type
    is_aws_deployment = is_ecs_deployment or is_eks_deployment
    
    # Resolve full path (absolute paths used as-is, relative paths joined with repo_root)
    if delta_path.startswith(('s3://', 's3a://', '/')):
        delta_full_path = delta_path
    else:
        delta_full_path = os.path.join(repo_root, delta_path)
    
    # Check for _delta_log directory (indicates Delta table exists)
    # S3 paths need trailing slash for directory detection
    if is_aws_deployment:
        delta_log_path = delta_full_path.rstrip('/') + '/_delta_log/'
    else:
        delta_log_path = os.path.join(delta_full_path, '_delta_log')
    
    logger.info(f"Checking for Delta table _delta_log at: {delta_log_path}")
    
    # Check if _delta_log directory exists
    table_exists = exists(delta_log_path)
    
    if table_exists:
        logger.info(f"✓ Delta table found at {delta_full_path} (verified _delta_log at {delta_log_path})")
    else:
        logger.warning(
            f"✗ Delta table not found at {delta_full_path} "
            f"(checked for _delta_log at {delta_log_path})"
        )
    
    return table_exists

