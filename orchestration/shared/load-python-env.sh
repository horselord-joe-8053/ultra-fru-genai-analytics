#!/bin/bash
# Set PYTHON_CMD to project venv Python if venv exists, else system python3.
# Requires: REPO_ROOT (set by load-env.sh or caller).
# Usage: source this after REPO_ROOT is set. Then use "$PYTHON_CMD" instead of python3.
# Typically sourced by load-env.sh so scripts that source load-env.sh get PYTHON_CMD automatically.

VENV_PYTHON=""
if [ -n "${REPO_ROOT:-}" ]; then
    VENV_PYTHON="$REPO_ROOT/venv/bin/python3"
fi
if [ -n "$VENV_PYTHON" ] && [ -f "$VENV_PYTHON" ]; then
    export PYTHON_CMD="$VENV_PYTHON"
else
    export PYTHON_CMD="python3"
fi
