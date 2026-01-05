"""
File system abstraction for multi-environment support.
Works with local, S3, EFS, and future storage backends.

Applicable environment: [local] [aws {ecs | eks}] [azure {aci | aks}] [gcp {cloud-run | gke}]
"""
from typing import Optional, List
import os


def detect_storage_type(path: str) -> str:
    """
    Detect storage type from path.
    
    Returns:
        's3' for S3 paths (s3://bucket/key)
        'efs' for EFS paths (/mnt/efs/...)
        'local' for local file system paths
    """
    if path.startswith('s3://'):
        return 's3'
    elif path.startswith('/mnt/efs/'):
        return 'efs'
    else:
        return 'local'


def exists(path: str) -> bool:
    """
    Check if path exists (works for S3, local, EFS).
    
    Args:
        path: File or directory path (can be s3://, /mnt/efs/, or local)
    
    Returns:
        bool: True if path exists, False otherwise
    """
    storage_type = detect_storage_type(path)
    
    if storage_type == 's3':
        from backend.env_utils.aws.s3_helpers import s3_exists
        return s3_exists(path)
    elif storage_type == 'efs':
        # EFS is mounted, so use local filesystem operations
        return os.path.exists(path)
    else:
        # Local file system - use os.path directly
        return os.path.exists(path)


def listdir(path: str) -> List[str]:
    """
    List directory contents (works for S3, local, EFS).
    
    Args:
        path: Directory path (can be s3://, /mnt/efs/, or local)
    
    Returns:
        List[str]: List of file/directory names
    """
    storage_type = detect_storage_type(path)
    
    if storage_type == 's3':
        from backend.env_utils.aws.s3_helpers import s3_listdir
        return s3_listdir(path)
    else:
        return os.listdir(path)


def isdir(path: str) -> bool:
    """
    Check if path is a directory (works for S3, local, EFS).
    
    Args:
        path: Path to check (can be s3://, /mnt/efs/, or local)
    
    Returns:
        bool: True if path is a directory, False otherwise
    """
    storage_type = detect_storage_type(path)
    
    if storage_type == 's3':
        # For S3, check if it's a directory (ends with / or has children)
        from backend.env_utils.aws.s3_helpers import s3_isdir
        return s3_isdir(path)
    else:
        return os.path.isdir(path)

