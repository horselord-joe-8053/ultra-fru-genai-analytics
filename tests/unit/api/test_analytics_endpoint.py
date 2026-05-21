"""GET /analytics with mocked database row."""


def test_analytics_empty_table(flask_client, monkeypatch, mock_db_connection):
    cursor = mock_db_connection.cursor.return_value.__enter__.return_value
    cursor.fetchone.return_value = None

    resp = flask_client.get("/analytics")
    assert resp.status_code == 200
    data = resp.get_json()
    assert "error" in data


def test_analytics_returns_payload(flask_client, monkeypatch, mock_db_connection):
    cursor = mock_db_connection.cursor.return_value.__enter__.return_value
    cursor.fetchone.return_value = {
        "sales_by_brand": [{"brand": "LG", "qty": 1}],
        "store_performance": [],
        "feedback_analysis": [],
        "top_models": [],
        "price_stats": {},
        "id": 1,
        "created_at": None,
        "total_records": 10,
        "total_revenue": 1000.0,
    }

    resp = flask_client.get("/analytics")
    assert resp.status_code == 200
    assert resp.get_json()["total_records"] == 10
