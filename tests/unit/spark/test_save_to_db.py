"""save_analytics_to_db with mocked psycopg2."""

from unittest.mock import MagicMock, patch

from spark_jobs.utils.save_to_db import save_analytics_to_db


@patch("spark_jobs.utils.save_to_db.psycopg2.connect")
def test_save_analytics_to_db_success(mock_connect, monkeypatch):
    conn = MagicMock()
    mock_connect.return_value = conn

    ok = save_analytics_to_db(
        sales_by_brand=[{"brand": "LG"}],
        store_performance=[],
        feedback_analysis=[],
        top_models=[],
        price_stats={},
        total_records=1,
        total_revenue=100.0,
        db_config={
            "host": "localhost",
            "port": 5432,
            "user": "u",
            "password": "p",
            "dbname": "d",
        },
    )
    assert ok is True
    conn.commit.assert_called_once()
