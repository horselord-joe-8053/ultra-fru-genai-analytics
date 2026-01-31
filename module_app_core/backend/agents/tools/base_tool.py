"""
Base tool interface for agent tools.

Applicable environment: [local] [aws {ecs | eks}] [azure {aci | aks}] [gcp {cloud-run | gke}]
"""
from abc import ABC, abstractmethod
from typing import Dict, Any, Optional, Tuple
import time


class BaseTool(ABC):
    """Base class for all agent tools."""
    
    def __init__(self, name: str, description: str):
        self.name = name
        self.description = description
    
    @abstractmethod
    def execute(self, **kwargs) -> Dict[str, Any]:
        """
        Execute the tool.
        
        Returns:
            Dict with:
                - success: bool
                - result: Any (tool-specific)
                - error: Optional[str]
                - execution_time_ms: float
        """
        pass
    
    def validate_input(self, **kwargs) -> Tuple[bool, Optional[str]]:
        """
        Validate tool input.
        
        Returns:
            (is_valid, error_message)
        """
        return True, None
    
    def get_info(self) -> Dict[str, Any]:
        """Get tool information."""
        return {
            "name": self.name,
            "description": self.description
        }

