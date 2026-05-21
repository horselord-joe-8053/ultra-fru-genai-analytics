"""Unit tests for module_test_verification response validators."""

import importlib.util
import sys
import types
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[2]
_PY_DIR = REPO_ROOT / "module_test_verification" / "python"


def _load_validator_modules():
    python_pkg = types.ModuleType("python")
    sys.modules["python"] = python_pkg

    utils_spec = importlib.util.spec_from_file_location(
        "python.common_utils", _PY_DIR / "common_utils.py"
    )
    utils_mod = importlib.util.module_from_spec(utils_spec)
    sys.modules["python.common_utils"] = utils_mod
    assert utils_spec.loader is not None
    utils_spec.loader.exec_module(utils_mod)

    val_spec = importlib.util.spec_from_file_location(
        "python.common_test_queries_validators",
        _PY_DIR / "common_test_queries_validators.py",
    )
    val_mod = importlib.util.module_from_spec(val_spec)
    sys.modules["python.common_test_queries_validators"] = val_mod
    assert val_spec.loader is not None
    val_spec.loader.exec_module(val_mod)
    return utils_mod, val_mod


_utils, _validators = _load_validator_modules()


def test_get_numeric_tolerance_default(monkeypatch):
    monkeypatch.delenv("MAX_ALLOWED_NUMERIC_DEVIATION_FOR_TEST", raising=False)
    assert _validators._get_numeric_tolerance() == 0.01


def test_extract_numeric_value_decimal():
    assert _validators._extract_numeric_value("Average rating is 8.75 stars") == 8.75


def test_assert_contains_pass():
    _utils.assert_contains("hello world", "world", "sample")


def test_assert_contains_fail():
    with pytest.raises(AssertionError):
        _utils.assert_contains("hello", "missing", "sample")
