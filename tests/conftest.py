"""Shared pytest fixtures for FRU legacy unit tests."""

from __future__ import annotations

import os
import sys
from pathlib import Path
from typing import Any, Dict, List
from unittest.mock import MagicMock

import pytest

REPO_ROOT = Path(__file__).resolve().parents[1]
MODULE_CORE = REPO_ROOT / "module_app_core"
if str(MODULE_CORE) not in sys.path:
    sys.path.insert(0, str(MODULE_CORE))


def _minimal_test_env() -> Dict[str, str]:
    return {
        "LOG_LEVEL": "WARNING",
        "ALLOWED_ORIGINS": "http://localhost:5173",
        "USE_AGENT_QUERY": "false",
        "PGHOST": "localhost",
        "PGPORT": "5432",
        "PGUSER": "test",
        "PGPASSWORD": "test",
        "PGDATABASE": "test",
        "OPENAI_API_KEY": "sk-test-key",
        "OPENAI_EMBED_MODEL": "text-embedding-3-small",
        "AWS_REGION": "us-east-1",
        "AWS_BEDROCK_MODEL_ID": "anthropic.claude-3-haiku-20240307-v1:0",
        "CONTAINER_IMAGE": "fru-api:test-tag",
        "DELTA_LAKE_PACKAGE": "io.delta:delta-spark_2.12:3.2.0",
        "CLAUDE_API_KEY": "",
    }


def _apply_test_env() -> None:
    for key, value in _minimal_test_env().items():
        os.environ.setdefault(key, value)


_apply_test_env()


def pytest_configure(config: pytest.Config) -> None:
    _apply_test_env()


@pytest.fixture(autouse=True)
def test_env(monkeypatch: pytest.MonkeyPatch) -> None:
    for key, value in _minimal_test_env().items():
        monkeypatch.setenv(key, value)


@pytest.fixture
def mock_db_cursor() -> MagicMock:
    cursor = MagicMock()
    cursor.description = [("id",), ("brand",)]
    cursor.fetchall.return_value = [{"id": "1", "brand": "LG"}]
    cursor.__enter__ = MagicMock(return_value=cursor)
    cursor.__exit__ = MagicMock(return_value=False)
    return cursor


@pytest.fixture
def mock_db_connection(mock_db_cursor: MagicMock) -> MagicMock:
    conn = MagicMock()
    conn.cursor.return_value = mock_db_cursor
    return conn


@pytest.fixture
def mock_db_pool(mock_db_connection: MagicMock) -> MagicMock:
    pool = MagicMock()
    pool.getconn.return_value = mock_db_connection
    return pool


@pytest.fixture
def flask_client(monkeypatch: pytest.MonkeyPatch, mock_db_connection: MagicMock):
    """Flask test client with DB pool patched (no real Postgres)."""
    import backend.api.app as app_module

    monkeypatch.setattr(app_module, "_connection_pool", MagicMock())
    monkeypatch.setattr(app_module, "get_db_conn", lambda: mock_db_connection)
    monkeypatch.setattr(app_module, "return_db_conn", lambda _conn: None)
    monkeypatch.setattr(app_module, "query_agent", None)

    app_module.app.config["TESTING"] = True
    with app_module.app.test_client() as client:
        yield client
