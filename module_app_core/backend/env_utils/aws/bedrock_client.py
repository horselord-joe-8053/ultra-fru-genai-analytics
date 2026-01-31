"""
AWS Bedrock client for AWS production.
Implements LLMClient interface for AWS Bedrock usage.
Works in both ECS and EKS containers (uses IAM role or AWS credentials).

Applicable environment: [aws {ecs | eks}]
"""
from backend.llm.base_client import LLMClient
from backend.utils.env_helpers import get_required_env
import boto3
import os
import logging
import json
from typing import Dict, Any, Optional, Iterator
from botocore.exceptions import ClientError, BotoCoreError

logger = logging.getLogger(__name__)


class AWSBedrockClient(LLMClient):
    """AWS Bedrock client (AWS production)."""
    
    def __init__(self):
        region = get_required_env("AWS_REGION", "AWS region for Bedrock API")
        profile = os.environ.get("AWS_PROFILE", "")
        
        if profile:
            session = boto3.Session(profile_name=profile)
        else:
            session = boto3.Session()
        
        self.client = session.client("bedrock-runtime", region_name=region)
        self.inference_profile_id = os.environ.get("AWS_BEDROCK_INFERENCE_PROFILE_ID", "").strip()
        self.model_id = os.environ.get("AWS_BEDROCK_MODEL_ID", "").strip()
    
    def complete(
        self,
        system_prompt: str,
        user_message: str,
        model_id: Optional[str] = None,
        max_tokens: int = 2000
    ) -> Dict[str, Any]:
        """Generate completion using AWS Bedrock."""
        # Use inference profile ID as modelId if available (preferred for Claude 3.5)
        # If inference profile ID is set, use it as the modelId parameter
        inference_profile_id = self.inference_profile_id
        
        # Fallback to model ID if no inference profile
        if not inference_profile_id:
            if model_id is None:
                model_id = self.model_id
                if not model_id:
                    raise ValueError(
                        "Either AWS_BEDROCK_INFERENCE_PROFILE_ID or AWS_BEDROCK_MODEL_ID must be set"
                    )
        
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
        
        # Use inference profile ID as modelId if available
        if inference_profile_id:
            invoke_params["modelId"] = inference_profile_id
            logger.info(f"Using Bedrock inference profile (as modelId): {inference_profile_id}")
        else:
            invoke_params["modelId"] = model_id
            logger.info(f"Using Bedrock model ID: {model_id}")

        try:
            response = self.client.invoke_model(**invoke_params)
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
            raise ValueError("Invalid response from Bedrock")
        except Exception as e:
            logger.error(f"Error reading Bedrock response: {e}")
            raise ValueError("Failed to read Bedrock response")

        # Check for truncation
        stop_reason = resp_body.get("stop_reason")
        if stop_reason == "max_tokens":
            logger.warning(
                f"Bedrock response was truncated due to max_tokens limit ({max_tokens}). "
                f"Consider increasing max_tokens for longer responses."
            )

        # Extract token usage from response
        usage = resp_body.get("usage", {})
        input_tokens = usage.get("input_tokens", 0)
        output_tokens = usage.get("output_tokens", 0)
        total_tokens = input_tokens + output_tokens

        # Extract text from content blocks
        chunks = []
        content_blocks = resp_body.get("content", [])
        
        if not content_blocks:
            logger.warning("Empty content blocks in Bedrock response")
            return {"text": "", "tokens": {"input": 0, "output": 0, "total": 0}}
        
        for block in content_blocks:
            block_type = block.get("type")
            if block_type == "text":
                text = block.get("text", "")
                if text:
                    chunks.append(text)
        
        if not chunks:
            logger.warning("No text content found in Bedrock response blocks")
            return {"text": "", "tokens": {"input": input_tokens, "output": output_tokens, "total": total_tokens}}
        
        # Join all text chunks
        full_text = "".join(chunks)
        
        return {
            "text": full_text,
            "tokens": {
                "input": input_tokens,
                "output": output_tokens,
                "total": total_tokens
            }
        }
    
    def stream_complete(
        self,
        system_prompt: str,
        user_message: str,
        model_id: Optional[str] = None,
        max_tokens: int = 2000
    ) -> Iterator[Dict[str, Any]]:
        """Generate streaming completion using AWS Bedrock."""
        # Use inference profile ID as modelId if available
        inference_profile_id = self.inference_profile_id
        
        # Fallback to model ID if no inference profile
        if not inference_profile_id:
            if model_id is None:
                model_id = self.model_id
                if not model_id:
                    raise ValueError(
                        "Either AWS_BEDROCK_INFERENCE_PROFILE_ID or AWS_BEDROCK_MODEL_ID must be set"
                    )
        
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

        invoke_params = {
            "body": json.dumps(body),
            "accept": "application/json",
            "contentType": "application/json",
        }
        
        if inference_profile_id:
            invoke_params["modelId"] = inference_profile_id
        else:
            invoke_params["modelId"] = model_id

        try:
            response = self.client.invoke_model_with_response_stream(**invoke_params)
            
            for event in response["body"]:
                if "chunk" in event:
                    chunk = json.loads(event["chunk"]["bytes"])
                    delta = chunk.get("delta", {})
                    text = delta.get("text", "")
                    if text:
                        yield {
                            "text": text,
                            "tokens": {}  # Tokens provided at end of stream
                        }
        except ClientError as e:
            error_code = e.response.get("Error", {}).get("Code", "Unknown")
            error_message = e.response.get("Error", {}).get("Message", str(e))
            logger.error(f"Bedrock streaming API error ({error_code}): {error_message}")
            raise ValueError(f"Bedrock API error: {error_code} - {error_message}")
        except Exception as e:
            logger.error(f"Unexpected error in Bedrock streaming: {e}")
            raise ValueError(f"Failed to stream from Bedrock: {e}")

