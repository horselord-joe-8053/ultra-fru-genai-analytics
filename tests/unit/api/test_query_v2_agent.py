"""Agent /query-v2 endpoint and feature flag behavior."""

from unittest.mock import MagicMock, patch

def test_query_v2_disabled_returns_404(flask_client):
    resp = flask_client.post("/query-v2", json={"query": "count sales"})
    assert resp.status_code == 404
    assert "disabled" in resp.get_json()["error"].lower()


def test_query_v2_with_agent(flask_client, monkeypatch):
    import backend.api.app as app_module

    monkeypatch.setattr(app_module, "USE_AGENT_QUERY", True)
    mock_agent = MagicMock()
    mock_agent.process_query.return_value = {
        "answer": "42 stores",
        "method": "agentic",
        "iterations": 1,
        "execution_time_ms": 10.0,
    }
    monkeypatch.setattr(app_module, "query_agent", mock_agent)

    resp = flask_client.post("/query-v2", json={"query": "How many stores?"})
    assert resp.status_code == 200
    assert resp.get_json()["answer"] == "42 stores"
