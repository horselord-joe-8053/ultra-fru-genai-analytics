"""
Local file system operations.
Wrapper around os.path.* for consistency with other environments.

Applicable environment: [local]
"""
import os
from typing import List


def exists(path: str) -> bool:
    """Check if local path exists"""
    return os.path.exists(path)


def listdir(path: str) -> List[str]:
    """List local directory contents"""
    return os.listdir(path)


def isdir(path: str) -> bool:
    """Check if local path is a directory"""
    return os.path.isdir(path)

