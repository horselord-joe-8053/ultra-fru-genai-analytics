"""
AWS S3-specific file operations.
Provides S3-compatible file system operations.
Works in both ECS and EKS containers (uses IAM role or AWS credentials).

Applicable environment: [aws {ecs | eks}]
"""
import boto3
from urllib.parse import urlparse
from typing import List, Optional


def s3_exists(s3_path: str) -> bool:
    """
    Check if S3 path exists.
    
    Args:
        s3_path: S3 path in format s3://bucket/key
    
    Returns:
        bool: True if path exists, False otherwise
    """
    parsed = urlparse(s3_path)
    bucket = parsed.netloc
    key = parsed.path.lstrip('/')
    
    s3_client = boto3.client('s3')
    try:
        # For directories (keys ending with /), list objects
        if key.endswith('/') or key == '':
            response = s3_client.list_objects_v2(
                Bucket=bucket,
                Prefix=key,
                MaxKeys=1
            )
            return response.get('KeyCount', 0) > 0
        else:
            # For files, use head_object
            s3_client.head_object(Bucket=bucket, Key=key)
            return True
    except s3_client.exceptions.NoSuchKey:
        return False
    except s3_client.exceptions.ClientError as e:
        if e.response['Error']['Code'] == '404':
            return False
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

