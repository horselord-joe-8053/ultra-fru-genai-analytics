"""
Claude API client for local development.
Implements LLMClient interface for local Claude API usage.

Applicable environment: [local]
"""
from backend.llm.base_client import LLMClient
from anthropic import Anthropic
import os
import logging
from typing import Dict, Any, Optional, Iterator

logger = logging.getLogger(__name__)


class LocalClaudeClient(LLMClient):
    """Claude API client (local development)."""
    
    def __init__(self):
        api_key = os.environ.get("CLAUDE_API_KEY", "").strip()
        if not api_key:
            raise ValueError("CLAUDE_API_KEY must be set for local Claude API")
        self.client = Anthropic(api_key=api_key)
        self.model = "claude-3-5-haiku-20241022"  # Match Bedrock model
    
    def complete(
        self,
        system_prompt: str,
        user_message: str,
        model_id: Optional[str] = None,
        max_tokens: int = 2000
    ) -> Dict[str, Any]:
        """Generate completion using Claude API."""
        model = model_id or self.model
        response = self.client.messages.create(
            model=model,
            max_tokens=max_tokens,
            system=system_prompt,
            messages=[{"role": "user", "content": user_message}]
        )
        
        usage = response.usage
        return {
            "text": response.content[0].text,
            "tokens": {
                "input": usage.input_tokens,
                "output": usage.output_tokens,
                "total": usage.input_tokens + usage.output_tokens
            }
        }
    
    def stream_complete(
        self,
        system_prompt: str,
        user_message: str,
        model_id: Optional[str] = None,
        max_tokens: int = 2000
    ) -> Iterator[Dict[str, Any]]:
        """Generate streaming completion using Claude API."""
        model = model_id or self.model
        with self.client.messages.stream(
            model=model,
            max_tokens=max_tokens,
            system=system_prompt,
            messages=[{"role": "user", "content": user_message}]
        ) as stream:
            for text_delta in stream.text_stream:
                yield {
                    "text": text_delta,
                    "tokens": {}  # Tokens provided at end of stream
                }

