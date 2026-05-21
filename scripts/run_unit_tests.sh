#!/usr/bin/env bash
# Run FRU legacy unit tests with coverage (no live Postgres/Spark/cloud).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
python3 -m pip install -q -r requirements-dev.txt
python3 -m coverage run -m pytest "$@"
python3 -m coverage report --include='module_app_core/backend/*' --fail-under=42
python3 -m coverage xml -o coverage.xml
