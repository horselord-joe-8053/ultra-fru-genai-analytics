"""
LLM client abstraction layer.
Provides environment-agnostic interface for LLM clients.

Applicable environment: [local] [aws {ecs | eks}] [azure {aci | aks}] [gcp {cloud-run | gke}]
"""
from backend.llm.client_factory import create_llm_client, claude_complete, get_bedrock_client

__all__ = [
    "create_llm_client",
    "claude_complete",
    "get_bedrock_client",
]

