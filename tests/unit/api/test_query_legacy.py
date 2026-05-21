"""Legacy /query path with mocked vector search and LLM."""

from unittest.mock import patch

@patch("backend.api.app.claude_complete")
@patch("backend.api.app.pgvector_search_feedback")
def test_query_legacy_happy_path(mock_search, mock_claude, flask_client):
    mock_search.return_value = [{"id": "1", "brand": "LG", "customer_feedback": "ok"}]
    mock_claude.return_value = {"text": "Sales look strong.", "tokens": {"input": 1, "output": 2, "total": 3}}

    resp = flask_client.post("/query", json={"query": "How is LG feedback?"})
    assert resp.status_code == 200
    body = resp.get_json()
    assert body["answer"] == "Sales look strong."
    assert body.get("method") != "agentic"


def test_query_rejects_empty_body(flask_client):
    resp = flask_client.post("/query", json={"query": ""})
    assert resp.status_code == 400
