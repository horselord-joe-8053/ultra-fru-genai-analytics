"""SSE /query/stream with agent disabled."""

def test_query_stream_missing_query(flask_client):
    resp = flask_client.get("/query/stream")
    assert resp.status_code == 400


def test_query_stream_agent_disabled_emits_error(flask_client):
    resp = flask_client.get("/query/stream?query=hello")
    assert resp.status_code == 200
    body = resp.get_data(as_text=True)
    assert "event:" in body or "error" in body.lower()
