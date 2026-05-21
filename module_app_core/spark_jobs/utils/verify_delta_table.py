"""
Helper function to verify if a Delta table exists.
Works with S3, local filesystem, and EFS paths.

Applicable environment: [local] [aws {ecs | eks}] [azure {aci | aks}] [gcp {cloud-run | gke}]
"""
import os
import sys
import logging
from typing import Tuple
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
    
    # Determine container type
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


def verify_delta_table_exists_cli(
    delta_path: str,
    repo_root: str = None,
    is_ecs_deployment: bool = False,
    is_eks_deployment: bool = False,
    log_level: str = "INFO"
) -> Tuple[bool, str, int]:
    """
    CLI-friendly wrapper for verify_delta_table_exists with enhanced error handling.
    
    This function is designed to be called from shell scripts and provides:
    - Proper exit codes (0 = exists, 1 = not exists, 2 = error)
    - Enhanced logging with configurable log level
    - Detailed error messages for debugging
    - Graceful handling of missing dependencies (boto3, etc.)
    
    Args:
        delta_path: Path to Delta table (can be absolute or relative)
        repo_root: Repository root directory (used for relative paths)
        is_ecs_deployment: True if this is an ECS deployment (uses S3 for Delta tables)
        is_eks_deployment: True if this is an EKS deployment (uses S3 for Delta tables)
        log_level: Logging level (DEBUG, INFO, WARNING, ERROR)
    
    Returns:
        Tuple[bool, str, int]:
            - bool: True if table exists, False otherwise
            - str: Status message for logging
            - int: Exit code (0 = exists, 1 = not exists, 2 = error)
    """
    # Configure logging level
    numeric_level = getattr(logging, log_level.upper(), logging.INFO)
    logging.basicConfig(level=numeric_level, format='%(levelname)s: %(message)s')
    
    try:
        # Attempt verification
        table_exists = verify_delta_table_exists(
            delta_path=delta_path,
            repo_root=repo_root,
            is_ecs_deployment=is_ecs_deployment,
            is_eks_deployment=is_eks_deployment
        )
        
        if table_exists:
            message = f"Delta table exists at {delta_path}"
            logger.info(message)
            return True, message, 0
        else:
            message = f"Delta table not found at {delta_path}"
            logger.warning(message)
            return False, message, 1
            
    except ImportError as e:
        # Missing dependencies (e.g., boto3) - indicate fallback should be used
        error_msg = f"Missing required dependency: {e}. Fall back to AWS CLI for verification."
        logger.debug(error_msg)
        return False, error_msg, 2
        
    except Exception as e:
        # Other errors - log details for debugging
        error_msg = f"Error verifying Delta table at {delta_path}: {type(e).__name__}: {e}"
        logger.error(error_msg, exc_info=True)
        return False, error_msg, 2


if __name__ == "__main__":
    """
    CLI entry point for shell scripts.
    
    Usage:
        python -m spark_jobs.utils.verify_delta_table <delta_path> [repo_root] [is_ecs] [is_eks] [log_level]
    
    Exit codes:
        0: Delta table exists
        1: Delta table does not exist
        2: Error (missing dependencies or other error)
    """
    if len(sys.argv) < 2:
        print("Usage: python -m spark_jobs.utils.verify_delta_table <delta_path> [repo_root] [is_ecs] [is_eks] [log_level]", file=sys.stderr)
        sys.exit(2)
    
    delta_path = sys.argv[1]
    repo_root = sys.argv[2] if len(sys.argv) > 2 else None
    is_ecs = sys.argv[3].lower() == 'true' if len(sys.argv) > 3 else False
    is_eks = sys.argv[4].lower() == 'true' if len(sys.argv) > 4 else False
    log_level = sys.argv[5] if len(sys.argv) > 5 else "INFO"
    
    _, message, exit_code = verify_delta_table_exists_cli(
        delta_path=delta_path,
        repo_root=repo_root,
        is_ecs_deployment=is_ecs,
        is_eks_deployment=is_eks,
        log_level=log_level
    )
    
    # Print message to stderr so it doesn't interfere with exit code
    print(message, file=sys.stderr)
    sys.exit(exit_code)

