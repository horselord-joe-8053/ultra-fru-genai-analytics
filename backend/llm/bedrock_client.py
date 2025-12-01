import os
import json
import boto3


def get_bedrock_client():
    # Return a Bedrock Runtime client using AWS_REGION or us-east-1.
    region = os.environ.get("AWS_REGION", "us-east-1")
    return boto3.client("bedrock-runtime", region_name=region)


def claude_complete(system_prompt, user_message, model_id=None, max_tokens=800):
    # Call an Anthropic Claude model on Bedrock and return the text reply.
    if model_id is None:
        model_id = os.environ.get(
            "BEDROCK_MODEL_ID",
            "anthropic.claude-3-haiku-20240229-v1:0",
        )

    client = get_bedrock_client()

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

    response = client.invoke_model(
        modelId=model_id,
        body=json.dumps(body),
        accept="application/json",
        contentType="application/json",
    )

    resp_body = json.loads(response["body"].read())
    chunks = []
    for block in resp_body.get("content", []):
        if block.get("type") == "text":
            chunks.append(block.get("text", ""))
    return "".join(chunks)