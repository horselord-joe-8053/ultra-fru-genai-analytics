"""
Abstract base class for LLM clients.
All LLM implementations must implement this interface.
This is an abstract interface, platform-agnostic and works in any environment.

Applicable environment: [local] [aws {ecs | eks}] [azure {aci | aks}] [gcp {cloud-run | gke}]
"""
from abc import ABC, abstractmethod
from typing import Dict, Any, Optional, Iterator


class LLMClient(ABC):
    """Abstract base class for LLM clients."""
    
    @abstractmethod
    def complete(
        self,
        system_prompt: str,
        user_message: str,
        model_id: Optional[str] = None,
        max_tokens: int = 2000
    ) -> Dict[str, Any]:
        """
        Generate a completion using the LLM.
        
        Args:
            system_prompt: System prompt for the LLM
            user_message: User message content
            model_id: Optional model ID
            max_tokens: Maximum tokens in response
        
        Returns:
            Dict with keys: 'text' (str), 'tokens' (dict with input/output/total)
        """
        pass
    
    @abstractmethod
    def stream_complete(
        self,
        system_prompt: str,
        user_message: str,
        model_id: Optional[str] = None,
        max_tokens: int = 2000
    ) -> Iterator[Dict[str, Any]]:
        """
        Generate a streaming completion (yields chunks).
        
        Args:
            system_prompt: System prompt for the LLM
            user_message: User message content
            model_id: Optional model ID
            max_tokens: Maximum tokens in response
        
        Yields:
            Dict with 'text' chunk and optional 'tokens'
        """
        pass

