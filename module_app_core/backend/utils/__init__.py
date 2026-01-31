"""
Backend utilities module.

Applicable environment: [local] [aws {ecs | eks}] [azure {aci | aks}] [gcp {cloud-run | gke}]
"""
from backend.utils.env_helpers import (
    get_required_env,
    get_optional_env,
    get_optional_bool_env,
    get_optional_int_env,
)
__all__ = [
    "get_required_env",
    "get_optional_env",
    "get_optional_bool_env",
    "get_optional_int_env",
]
