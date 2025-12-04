import os
import json
import logging
import boto3
from botocore.exceptions import ClientError, BotoCoreError

logger = logging.getLogger(__name__)


def get_bedrock_client():
    """Return a Bedrock Runtime client using AWS_REGION or us-east-1."""
    access_key = os.environ.get("AWS_ACCESS_KEY_ID")
    secret_key = os.environ.get("AWS_SECRET_ACCESS_KEY")
    region = os.environ.get("AWS_REGION", "us-east-1")
    try:
        return boto3.client("bedrock-runtime",
                            aws_access_key_id=access_key,
                            aws_secret_access_key=secret_key,
                            region_name=region)
    except Exception as e:
        logger.error(f"Failed to create Bedrock client: {e}")
        raise ValueError(f"Failed to initialize Bedrock client: {e}")


def claude_complete(system_prompt, user_message, model_id=None, max_tokens=800):
    """
    Call an Anthropic Claude model on Bedrock and return the text reply.
    
    Args:
        system_prompt: System prompt for Claude
        user_message: User message content
        model_id: Optional model ID (defaults to env var or Haiku)
        max_tokens: Maximum tokens in response
    
    Returns:
        str: Generated text response
    
    Raises:
        ValueError: If Bedrock API call fails
    """
    if model_id is None:
        model_id = os.environ.get(
            "BEDROCK_MODEL_ID",
            "anthropic.claude-3-haiku-20240307-v1:0",
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

    try:
        response = client.invoke_model(
            modelId=model_id,
            body=json.dumps(body),
            accept="application/json",
            contentType="application/json",
        )
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