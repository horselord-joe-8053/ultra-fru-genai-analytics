"""Unit tests for backend.utils.filesystem."""

from unittest.mock import patch

from backend.utils import filesystem as fs


def test_detect_storage_type():
    assert fs.detect_storage_type("s3://bucket/key") == "s3"
    assert fs.detect_storage_type("s3a://bucket/key") == "s3"
    assert fs.detect_storage_type("/mnt/efs/data") == "efs"
    assert fs.detect_storage_type("/tmp/local") == "local"


def test_exists_local(tmp_path):
    p = tmp_path / "file.txt"
    p.write_text("x")
    assert fs.exists(str(p)) is True
    assert fs.exists(str(tmp_path / "missing.txt")) is False


def test_exists_s3_delegates(monkeypatch):
    with patch("backend.env_utils.aws.s3_helpers.s3_exists", return_value=True) as mock_s3:
        assert fs.exists("s3a://b/k") is True
        mock_s3.assert_called_once_with("s3://b/k")


def test_listdir_local(tmp_path):
    (tmp_path / "a.txt").write_text("")
    names = fs.listdir(str(tmp_path))
    assert "a.txt" in names
