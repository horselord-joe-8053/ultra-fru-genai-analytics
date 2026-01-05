"""
Environment variable helpers with fail-fast validation.
Ensures .env is the single source of truth for configuration.

Applicable environment: [local] [aws {ecs | eks}] [azure {aci | aks}] [gcp {cloud-run | gke}]
"""
import os
from typing import Optional


def get_required_env(var_name: str, description: str = "") -> str:
    """
    Get a required environment variable with fail-fast validation.
    
    Args:
        var_name: Name of the environment variable
        description: Optional description for error message
    
    Returns:
        str: The environment variable value (guaranteed to be non-empty)
    
    Raises:
        ValueError: If the environment variable is not set or is empty
    
    Example:
        >>> db_host = get_required_env("PGHOST", "Database host")
    """
    value = os.environ.get(var_name, "")
    if not value:
        error_msg = f"Required environment variable '{var_name}' is not set or is empty."
        if description:
            error_msg += f" ({description})"
        error_msg += f" Please set it in your .env file."
        raise ValueError(error_msg)
    return value


def get_optional_env(var_name: str, default: str = "") -> str:
    """
    Get an optional environment variable with a default value.
    
    Use this only for truly optional configuration (e.g., feature flags with
    sensible defaults, optional paths that have fallback logic).
    
    Args:
        var_name: Name of the environment variable
        default: Default value if not set (defaults to empty string)
    
    Returns:
        str: The environment variable value or default
    
    Example:
        >>> log_level = get_optional_env("LOG_LEVEL", "INFO")
    """
    return os.environ.get(var_name, default)


def get_optional_bool_env(var_name: str, default: bool = False) -> bool:
    """
    Get an optional boolean environment variable.
    
    Args:
        var_name: Name of the environment variable
        default: Default value if not set
    
    Returns:
        bool: The boolean value (true if env var is "true", "1", "yes", etc.)
    
    Example:
        >>> use_agent = get_optional_bool_env("USE_AGENT_QUERY", False)
    """
    value = os.environ.get(var_name, "").lower()
    if value in ("true", "1", "yes", "on"):
        return True
    elif value in ("false", "0", "no", "off", ""):
        return False
    else:
        # Invalid value, use default
        return default


def get_required_int_env(var_name: str, description: str = "") -> int:
    """
    Get a required integer environment variable with fail-fast validation.
    
    Args:
        var_name: Name of the environment variable
        description: Optional description for error message
    
    Returns:
        int: The integer value (guaranteed to be valid)
    
    Raises:
        ValueError: If the environment variable is not set, is empty, or is not a valid integer
    
    Example:
        >>> interval = get_required_int_env("ANALYTICS_SCHEDULER_INTERVAL_SECONDS", "Analytics scheduler interval in seconds")
    """
    value = os.environ.get(var_name, "")
    if not value:
        error_msg = f"Required environment variable '{var_name}' is not set or is empty."
        if description:
            error_msg += f" ({description})"
        error_msg += f" Please set it in your .env file."
        raise ValueError(error_msg)
    
    try:
        return int(value)
    except ValueError:
        error_msg = f"Environment variable '{var_name}' must be a valid integer, got: '{value}'"
        if description:
            error_msg += f" ({description})"
        raise ValueError(error_msg)


def get_optional_int_env(var_name: str, default: int = 0) -> int:
    """
    Get an optional integer environment variable.
    
    Args:
        var_name: Name of the environment variable
        default: Default value if not set or invalid
    
    Returns:
        int: The integer value or default
    
    Example:
        >>> port = get_optional_int_env("PGPORT", 5432)
    """
    value = os.environ.get(var_name, "")
    if not value:
        return default
    try:
        return int(value)
    except ValueError:
        return default

