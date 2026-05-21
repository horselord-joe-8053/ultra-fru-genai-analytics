"""Spark config helpers (no JVM)."""

import pytest

from spark_jobs.utils.spark_config import get_s3a_spark_config, get_spark_packages, to_spark_path


def test_get_s3a_spark_config_has_s3a_impl():
    conf = get_s3a_spark_config()
    assert any("spark.hadoop.fs.s3a.impl" in part for part in conf)


def test_to_spark_path_converts_scheme():
    assert to_spark_path("s3://bucket/path") == "s3a://bucket/path"
    assert to_spark_path("/local/path") == "/local/path"


def test_get_spark_packages_requires_env(monkeypatch):
    monkeypatch.delenv("DELTA_LAKE_PACKAGE", raising=False)
    with pytest.raises(ValueError):
        get_spark_packages(False)


def test_get_spark_packages_aws_adds_hadoop(monkeypatch):
    monkeypatch.setenv("DELTA_LAKE_PACKAGE", "io.delta:delta-spark_2.12:3.2.0")
    pkg = get_spark_packages(True)
    assert "hadoop-aws" in pkg
