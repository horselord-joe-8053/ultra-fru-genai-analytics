"""
AWS S3-specific file operations.
Provides S3-compatible file system operations.
Works in both ECS and EKS containers (uses IAM role or AWS credentials).

Applicable environment: [aws {ecs | eks}]
"""
import boto3
from urllib.parse import urlparse
from typing import List, Optional
import logging

logger = logging.getLogger(__name__)


def s3_exists(s3_path: str) -> bool:
    """
    Check if S3 path exists.
    
    Args:
        s3_path: S3 path in format s3://bucket/key (s3a:// is normalized to s3:// by caller)
    
    Returns:
        bool: True if path exists, False otherwise
    """
    logger.debug(f"s3_exists() called with path: {s3_path}")
    
    parsed = urlparse(s3_path)
    bucket = parsed.netloc
    key = parsed.path.lstrip('/')
    
    logger.debug(f"Parsed S3 path - bucket: {bucket}, key: {key}")
    
    if not bucket:
        logger.error(f"Invalid S3 path: {s3_path} (missing bucket)")
        return False
    
    s3_client = boto3.client('s3')
    try:
        # For directories (keys ending with /), list objects
        if key.endswith('/') or key == '':
            logger.debug(f"Checking if S3 directory exists: s3://{bucket}/{key}")
            response = s3_client.list_objects_v2(
                Bucket=bucket,
                Prefix=key,
                MaxKeys=1
            )
            key_count = response.get('KeyCount', 0)
            exists = key_count > 0
            logger.debug(f"S3 directory check result: {exists} (KeyCount={key_count}) for s3://{bucket}/{key}")
            return exists
        else:
            # For files, use head_object
            logger.debug(f"Checking if S3 file exists: s3://{bucket}/{key}")
            s3_client.head_object(Bucket=bucket, Key=key)
            logger.debug(f"S3 file exists: s3://{bucket}/{key}")
            return True
    except s3_client.exceptions.NoSuchKey:
        logger.debug(f"S3 path does not exist (NoSuchKey): s3://{bucket}/{key}")
        return False
    except s3_client.exceptions.ClientError as e:
        error_code = e.response.get('Error', {}).get('Code', 'Unknown')
        if error_code == '404' or error_code == 'NoSuchKey':
            logger.debug(f"S3 path does not exist (404/NoSuchKey): s3://{bucket}/{key}")
            return False
        else:
            logger.error(f"S3 ClientError checking path s3://{bucket}/{key}: {error_code} - {e}")
            raise
    except Exception as e:
        logger.error(f"Unexpected error checking S3 path s3://{bucket}/{key}: {type(e).__name__}: {e}")
        raise


def s3_listdir(s3_path: str) -> List[str]:
    """
    List S3 directory contents.
    
    Args:
        s3_path: S3 directory path in format s3://bucket/prefix/
    
    Returns:
        List[str]: List of object keys (directory names)
    """
    parsed = urlparse(s3_path)
    bucket = parsed.netloc
    prefix = parsed.path.lstrip('/')
    
    # Ensure prefix ends with /
    if prefix and not prefix.endswith('/'):
        prefix += '/'
    
    s3_client = boto3.client('s3')
    response = s3_client.list_objects_v2(
        Bucket=bucket,
        Prefix=prefix,
        Delimiter='/'
    )
    
    # Get directories (common prefixes)
    directories = []
    if 'CommonPrefixes' in response:
        for prefix_obj in response['CommonPrefixes']:
            # Extract directory name from prefix
            dir_name = prefix_obj['Prefix'][len(prefix):].rstrip('/')
            if dir_name:
                directories.append(dir_name)
    
    # Get files (keys)
    files = []
    if 'Contents' in response:
        for obj in response['Contents']:
            # Skip the directory marker itself
            if obj['Key'] != prefix:
                file_name = obj['Key'][len(prefix):]
                if file_name:
                    files.append(file_name)
    
    return directories + files


def s3_isdir(s3_path: str) -> bool:
    """
    Check if S3 path is a directory.
    
    Args:
        s3_path: S3 path in format s3://bucket/key
    
    Returns:
        bool: True if path is a directory, False otherwise
    """
    parsed = urlparse(s3_path)
    key = parsed.path.lstrip('/')
    
    # Check if it ends with / or if it exists as a directory (has children)
    if key.endswith('/') or key == '':
        return True
    
    # Check if it has children (is a directory prefix)
    return s3_exists(s3_path + '/')

