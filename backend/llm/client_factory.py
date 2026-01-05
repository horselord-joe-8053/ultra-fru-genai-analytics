"""
Factory for creating LLM clients based on environment.
This is the Factory Pattern implementation.
Works in any environment - detects and creates appropriate client.

Applicable environment: [local] [aws {ecs | eks}] [azure {aci | aks}] [gcp {cloud-run | gke}]
"""
from backend.llm.base_client import LLMClient
from typing import Optional, Dict, Any
import os
import logging

# Import Dict from typing for type hints

logger = logging.getLogger(__name__)


def create_llm_client() -> LLMClient:
    """
    Factory function that creates the appropriate LLM client based on environment.
    
    This encapsulates the decision logic of which concrete implementation to use.
    The caller doesn't need to know which specific implementation is returned.
    
    Priority:
    1. CLAUDE_API_KEY set → Local Claude API client
    2. AWS_REGION + Bedrock config → AWS Bedrock client
    3. Future: Azure/GCP config → respective clients
    
    Returns:
        LLMClient: Concrete implementation (LocalClaudeClient, AWSBedrockClient, etc.)
    
    Raises:
        ValueError: If no suitable LLM client can be created
    """
    # Priority 1: Check for local Claude API
    claude_api_key = os.environ.get("CLAUDE_API_KEY", "").strip()
    if claude_api_key:
        try:
            from backend.env_utils.local.claude_client import LocalClaudeClient
            logger.info("Creating Local Claude API client")
            return LocalClaudeClient()
        except ImportError as e:
            logger.warning(f"Claude API client not available: {e}")
        except Exception as e:
            logger.error(f"Failed to create Local Claude client: {e}")
            raise
    
    # Priority 2: Check for AWS Bedrock
    aws_region = os.environ.get("AWS_REGION", "").strip()
    bedrock_profile_id = os.environ.get("AWS_BEDROCK_INFERENCE_PROFILE_ID", "").strip()
    bedrock_model_id = os.environ.get("AWS_BEDROCK_MODEL_ID", "").strip()
    
    if aws_region and (bedrock_profile_id or bedrock_model_id):
        try:
            from backend.env_utils.aws.bedrock_client import AWSBedrockClient
            logger.info("Creating AWS Bedrock client")
            return AWSBedrockClient()
        except ImportError as e:
            logger.warning(f"Bedrock client not available: {e}")
        except Exception as e:
            logger.error(f"Failed to create AWS Bedrock client: {e}")
            raise
    
    # Priority 3: Future - Azure Cognitive Services
    # Priority 4: Future - GCP Vertex AI
    
    # If no suitable client found, raise error
    raise ValueError(
        "No LLM client available. Set one of:\n"
        "  - CLAUDE_API_KEY (for local Claude API)\n"
        "  - AWS_REGION + AWS_BEDROCK_INFERENCE_PROFILE_ID or AWS_BEDROCK_MODEL_ID (for AWS Bedrock)"
    )


# Convenience function for backward compatibility
def claude_complete(
    system_prompt: str, 
    user_message: str, 
    model_id: Optional[str] = None, 
    max_tokens: int = 2000
) -> Dict[str, Any]:
    """
    Convenience function for backward compatibility.
    Creates LLM client using factory and calls complete().
    
    This maintains the same API as the old claude_complete() function,
    but now uses the Factory pattern internally.
    """
    client = create_llm_client()
    return client.complete(system_prompt, user_message, model_id, max_tokens)


# Convenience function for getting bedrock client (for agent initialization)
def get_bedrock_client():
    """
    Get AWS Bedrock client (for backward compatibility with agent code).
    
    Returns:
        boto3.client: Bedrock runtime client
    """
    from backend.utils.env_helpers import get_required_env
    import boto3
    
    region = get_required_env("AWS_REGION", "AWS region for Bedrock API")
    profile = os.environ.get("AWS_PROFILE", "")
    
    if profile:
        session = boto3.Session(profile_name=profile)
    else:
        session = boto3.Session()
    
    return session.client("bedrock-runtime", region_name=region)

