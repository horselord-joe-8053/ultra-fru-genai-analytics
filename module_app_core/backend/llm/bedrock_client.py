"""
AWS Bedrock client (LEGACY - DEPRECATED).
This file is kept for backward compatibility during migration.
New code should use backend.llm.client_factory or backend.env_utils.aws.bedrock_client.

This file will be removed in a future version after migration is complete.
For new code, use:
- backend.llm.client_factory.create_llm_client() (Factory Pattern)
- backend.llm.client_factory.claude_complete() (backward compatibility wrapper)
- backend.env_utils.aws.bedrock_client.AWSBedrockClient (direct access)

Applicable environment: [aws {ecs | eks}]
"""
import os
import json
import logging
import boto3
import warnings
from botocore.exceptions import ClientError, BotoCoreError
from backend.utils.env_helpers import get_required_env

logger = logging.getLogger(__name__)

# Deprecation warning for imports
warnings.warn(
    "backend.llm.bedrock_client is deprecated. "
    "Use backend.llm.client_factory or backend.env_utils.aws.bedrock_client instead.",
    DeprecationWarning,
    stacklevel=2
)


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


def claude_complete(system_prompt, user_message, model_id=None, max_tokens=2000):
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
            # Extract token usage from Claude API response
            input_tokens = getattr(response, 'usage', {}).input_tokens if hasattr(response, 'usage') else 0
            output_tokens = getattr(response, 'usage', {}).output_tokens if hasattr(response, 'usage') else 0
            total_tokens = input_tokens + output_tokens
            
            if total_tokens > 0:
                logger.debug(f"Token usage (Claude API): input={input_tokens}, output={output_tokens}, total={total_tokens}")
            
            return {
                "text": response.content[0].text,
                "tokens": {
                    "input": input_tokens,
                    "output": output_tokens,
                    "total": total_tokens
                }
            }
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
        # Read and decode the response body
        response_body = response["body"].read()
        if isinstance(response_body, bytes):
            response_body = response_body.decode('utf-8')
        resp_body = json.loads(response_body)
    except json.JSONDecodeError as e:
        logger.error(f"Failed to parse Bedrock response: {e}")
        logger.error(f"Response body (first 500 chars): {response_body[:500] if 'response_body' in locals() else 'N/A'}")
        raise ValueError("Invalid response from Bedrock")
    except Exception as e:
        logger.error(f"Error reading Bedrock response: {e}")
        raise ValueError("Failed to read Bedrock response")

    # Check for truncation (stop_reason indicates why generation stopped)
    stop_reason = resp_body.get("stop_reason")
    if stop_reason == "max_tokens":
        logger.warning(
            f"Bedrock response was truncated due to max_tokens limit ({max_tokens}). "
            f"Consider increasing max_tokens for longer responses."
        )
    elif stop_reason:
        logger.debug(f"Bedrock response stop_reason: {stop_reason}")

    # Extract token usage from response (if available)
    usage = resp_body.get("usage", {})
    input_tokens = usage.get("input_tokens", 0)
    output_tokens = usage.get("output_tokens", 0)
    total_tokens = input_tokens + output_tokens
    
    if total_tokens > 0:
        logger.debug(f"Token usage: input={input_tokens}, output={output_tokens}, total={total_tokens}")
    else:
        logger.debug("Token usage not available in Bedrock response")

    # Extract text from content blocks
    chunks = []
    content_blocks = resp_body.get("content", [])
    
    if not content_blocks:
        logger.warning("Empty content blocks in Bedrock response")
        logger.debug(f"Full response body: {json.dumps(resp_body, indent=2)}")
        return {"text": "", "tokens": {"input": 0, "output": 0, "total": 0}}
    
    for block in content_blocks:
        block_type = block.get("type")
        if block_type == "text":
            text = block.get("text", "")
            if text:
                chunks.append(text)
        else:
            logger.debug(f"Skipping non-text block type: {block_type}")
    
    if not chunks:
        logger.warning("No text content found in Bedrock response blocks")
        logger.debug(f"Content blocks: {content_blocks}")
        return {"text": "", "tokens": {"input": input_tokens, "output": output_tokens, "total": total_tokens}}
    
    # Join all text chunks
    full_text = "".join(chunks)
    
    # Validate the response isn't obviously corrupted
    if len(full_text.strip()) < 10:
        logger.warning(f"Bedrock response is suspiciously short ({len(full_text)} chars): {full_text[:100]}")
    
    # Return both text and token usage
    return {
        "text": full_text,
        "tokens": {
            "input": input_tokens,
            "output": output_tokens,
            "total": total_tokens
        }
    }