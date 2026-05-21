"""LLM client factory env branching."""

from unittest.mock import MagicMock, patch

import pytest

from backend.llm import client_factory


def test_create_llm_client_prefers_claude_api_key(monkeypatch):
    monkeypatch.setenv("CLAUDE_API_KEY", "sk-ant-test")
    with patch("backend.env_utils.local.claude_client.LocalClaudeClient") as mock_cls:
        mock_cls.return_value = MagicMock()
        client = client_factory.create_llm_client()
        assert client is mock_cls.return_value


def test_create_llm_client_uses_bedrock_when_configured(monkeypatch):
    monkeypatch.delenv("CLAUDE_API_KEY", raising=False)
    monkeypatch.setenv("AWS_REGION", "us-east-1")
    monkeypatch.setenv("AWS_BEDROCK_MODEL_ID", "anthropic.claude-3-haiku-20240307-v1:0")
    with patch("backend.env_utils.aws.bedrock_client.AWSBedrockClient") as mock_cls:
        mock_cls.return_value = MagicMock()
        client = client_factory.create_llm_client()
        assert client is mock_cls.return_value


def test_create_llm_client_raises_without_config(monkeypatch):
    monkeypatch.delenv("CLAUDE_API_KEY", raising=False)
    monkeypatch.delenv("AWS_BEDROCK_MODEL_ID", raising=False)
    monkeypatch.delenv("AWS_BEDROCK_INFERENCE_PROFILE_ID", raising=False)
    with pytest.raises(ValueError, match="No LLM client"):
        client_factory.create_llm_client()


@patch("backend.llm.client_factory.create_llm_client")
def test_claude_complete_delegates(mock_create):
    mock_client = MagicMock()
    mock_client.complete.return_value = {"text": "ok", "tokens": {}}
    mock_create.return_value = mock_client
    out = client_factory.claude_complete("sys", "user")
    assert out["text"] == "ok"
