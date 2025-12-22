import os
import json
import logging
import boto3
from botocore.exceptions import ClientError, BotoCoreError
from backend.utils.env_helpers import get_required_env

logger = logging.getLogger(__name__)


def get_claude_client():
    """Return Claude API client if CLAUDE_API_KEY is set (for local dev).
    
    This allows local development to mimic AWS Bedrock LLM calls using Claude API.
    Returns None if CLAUDE_API_KEY is not set or if anthropic package is not installed.
    """
    claude_api_key = os.environ.get("CLAUDE_API_KEY", "").strip()
    if claude_api_key:
        try:
            from anthropic import Anthropic
            return Anthropic(api_key=claude_api_key)
        except ImportError:
            logger.warning("anthropic package not installed. Install with: pip install anthropic")
            return None
    return None


def get_bedrock_client():
    """Return a Bedrock Runtime client using AWS profile or IAM role.
    
    - If AWS_PROFILE is explicitly set, uses that profile (for local development)
    - If AWS_PROFILE is not set or empty, uses IAM role (for ECS/EKS production)
    - In production (ECS/EKS), ECS task execution role provides Bedrock access via IAM
    """
    region = get_required_env("AWS_REGION", "AWS region for Bedrock API")
    profile = os.environ.get("AWS_PROFILE", "")  # Empty string if not set (use IAM role)
    
    try:
        # Only use profile if explicitly set (for local development)
        # In production (ECS/EKS), AWS_PROFILE should not be set, so boto3 uses IAM role
        if profile:
            session = boto3.Session(profile_name=profile)
        else:
            # No profile specified, use default credentials (IAM role in production)
            # ECS tasks use the task execution role for authentication
            session = boto3.Session()
        return session.client("bedrock-runtime", region_name=region)
    except Exception as e:
        logger.error(f"Failed to create Bedrock client: {e}")
        raise ValueError(f"Failed to initialize Bedrock client: {e}")


def claude_complete(system_prompt, user_message, model_id=None, max_tokens=800):
    """
    Call Claude via API (local dev) or Bedrock (AWS production).
    
    Priority:
    1. CLAUDE_API_KEY (local dev) - uses Anthropic API directly
    2. AWS Bedrock (production) - uses inference profile or model ID
    
    Priority order for Bedrock model/inference profile selection:
    1. AWS_BEDROCK_INFERENCE_PROFILE_ID
    2. model_id parameter (if provided)
    3. AWS_BEDROCK_MODEL_ID
    
    Args:
        system_prompt: System prompt for Claude
        user_message: User message content
        model_id: Optional model ID (defaults to env var)
        max_tokens: Maximum tokens in response
    
    Returns:
        str: Generated text response
    
    Raises:
        ValueError: If API call fails
    """
    # Try Claude API first (for local dev)
    claude_client = get_claude_client()
    if claude_client:
        logger.info("Using Claude API (local development)")
        try:
            response = claude_client.messages.create(
                model="claude-3-5-haiku-20241022",  # Match Bedrock model
                max_tokens=max_tokens,
                system=system_prompt,
                messages=[{"role": "user", "content": user_message}]
            )
            return response.content[0].text
        except Exception as e:
            logger.error(f"Claude API error: {e}")
            raise ValueError(f"Claude API error: {e}")
    
    # Fallback to Bedrock (for AWS deployment)
    # Try to get inference profile ID (preferred for Claude 3.5 and newer models)
    # Strip whitespace to handle any accidental spaces in environment variable
    inference_profile_id = os.environ.get("AWS_BEDROCK_INFERENCE_PROFILE_ID", "").strip()
    
    # Debug logging to help diagnose issues
    if inference_profile_id:
        logger.debug(f"AWS_BEDROCK_INFERENCE_PROFILE_ID is set: '{inference_profile_id}'")
    else:
        logger.debug("AWS_BEDROCK_INFERENCE_PROFILE_ID is not set or empty")
    
    # Fallback to model ID if no inference profile
    if not inference_profile_id:
        if model_id is None:
            model_id = os.environ.get("AWS_BEDROCK_MODEL_ID", "").strip()
            if not model_id:
                # Fail-fast if neither inference profile nor model ID is set
                raise ValueError(
                    "Either CLAUDE_API_KEY (for local dev), AWS_BEDROCK_INFERENCE_PROFILE_ID, or AWS_BEDROCK_MODEL_ID must be set"
                )

    try:
        client = get_bedrock_client()
    except Exception as e:
        logger.error(f"Bedrock client initialization failed: {e}")
        raise ValueError("Failed to initialize Bedrock client")

    body = {
        "anthropic_version": "bedrock-2023-05-31",
        "max_tokens": max_tokens,
        "system": system_prompt,
        "messages": [
            {
                "role": "user",
                "content": [
                    {"type": "text", "text": user_message}
                ],
            }
        ],
    }

    # Build invoke_model parameters
    invoke_params = {
        "body": json.dumps(body),
        "accept": "application/json",
        "contentType": "application/json",
    }
    
    # Use inference profile ID as modelId if available (inference profiles are referenced via modelId)
    # If inference profile ID is set, use it as the modelId parameter
    if inference_profile_id:
        invoke_params["modelId"] = inference_profile_id
        logger.info(f"Using Bedrock inference profile (as modelId): {inference_profile_id} in region: {get_required_env('AWS_REGION')}")
    else:
        invoke_params["modelId"] = model_id
        logger.info(f"Using Bedrock model ID: {model_id} in region: {get_required_env('AWS_REGION')}")

    try:
        response = client.invoke_model(**invoke_params)
    except ClientError as e:
        error_code = e.response.get("Error", {}).get("Code", "Unknown")
        error_message = e.response.get("Error", {}).get("Message", str(e))
        logger.error(f"Bedrock API error ({error_code}): {error_message}")
        raise ValueError(f"Bedrock API error: {error_code} - {error_message}")
    except BotoCoreError as e:
        logger.error(f"Boto3 error: {e}")
        raise ValueError(f"AWS service error: {e}")
    except Exception as e:
        logger.error(f"Unexpected error calling Bedrock: {e}")
        raise ValueError(f"Failed to call Bedrock: {e}")

    try:
        resp_body = json.loads(response["body"].read())
    except json.JSONDecodeError as e:
        logger.error(f"Failed to parse Bedrock response: {e}")
        raise ValueError("Invalid response from Bedrock")
    except Exception as e:
        logger.error(f"Error reading Bedrock response: {e}")
        raise ValueError("Failed to read Bedrock response")

    chunks = []
    for block in resp_body.get("content", []):
        if block.get("type") == "text":
            chunks.append(block.get("text", ""))
    
    if not chunks:
        logger.warning("Empty response from Bedrock")
        return ""
    
    return "".join(chunks)