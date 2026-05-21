"""Health and version API routes."""


def test_health_returns_ok(flask_client):
    resp = flask_client.get("/health")
    assert resp.status_code == 200
    data = resp.get_json()
    assert data["status"] == "ok"
    assert "database" in data


def test_version_returns_tag(flask_client):
    resp = flask_client.get("/version")
    assert resp.status_code == 200
    assert resp.get_json()["version"] == "test-tag"


def test_version_missing_image_returns_500(monkeypatch, flask_client):
    import backend.api.app as app_module

    monkeypatch.delenv("CONTAINER_IMAGE", raising=False)
    resp = flask_client.get("/version")
    assert resp.status_code == 500
