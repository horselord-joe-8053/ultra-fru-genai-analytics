"""Unit tests for backend.utils.env_helpers."""

import os

import pytest

from backend.utils import env_helpers


def test_get_required_env_raises_when_missing(monkeypatch):
    monkeypatch.delenv("FRU_MISSING_VAR", raising=False)
    with pytest.raises(ValueError, match="FRU_MISSING_VAR"):
        env_helpers.get_required_env("FRU_MISSING_VAR", "test description")


def test_get_required_env_returns_value(monkeypatch):
    monkeypatch.setenv("FRU_PRESENT_VAR", "hello")
    assert env_helpers.get_required_env("FRU_PRESENT_VAR") == "hello"


def test_get_optional_bool_env_truthy(monkeypatch):
    for val in ("true", "1", "yes", "on"):
        monkeypatch.setenv("FRU_BOOL", val)
        assert env_helpers.get_optional_bool_env("FRU_BOOL", False) is True


def test_get_optional_bool_env_falsey(monkeypatch):
    monkeypatch.setenv("FRU_BOOL", "false")
    assert env_helpers.get_optional_bool_env("FRU_BOOL", True) is False


def test_get_optional_int_env_default(monkeypatch):
    monkeypatch.delenv("FRU_INT_MISSING", raising=False)
    assert env_helpers.get_optional_int_env("FRU_INT_MISSING", 5432) == 5432


def test_get_optional_int_env_invalid_uses_default(monkeypatch):
    monkeypatch.setenv("FRU_INT_BAD", "not-a-number")
    assert env_helpers.get_optional_int_env("FRU_INT_BAD", 99) == 99
