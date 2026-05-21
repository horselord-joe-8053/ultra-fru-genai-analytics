"""AWS Bedrock client wrapper."""

from unittest.mock import MagicMock, patch

from backend.env_utils.aws.bedrock_client import AWSBedrockClient


@patch("backend.env_utils.aws.bedrock_client.boto3.Session")
def test_aws_bedrock_complete_parses_response(mock_session_cls, monkeypatch):
    monkeypatch.setenv("AWS_REGION", "us-east-1")
    monkeypatch.setenv("AWS_BEDROCK_MODEL_ID", "model-v1")

    body = MagicMock()
    body.read.return_value = (
        b'{"content":[{"type":"text","text":"hello"}],'
        b'"usage":{"input_tokens":1,"output_tokens":2}}'
    )
    mock_session_cls.return_value.client.return_value.invoke_model.return_value = {
        "body": body
    }

    client = AWSBedrockClient()
    out = client.complete("sys", "user")
    assert out["text"] == "hello"
    assert out["tokens"]["total"] == 3
