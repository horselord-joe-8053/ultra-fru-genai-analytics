"""
Common utilities for API-based query tests.

These helpers are intentionally lightweight and only depend on the Python
standard library, so they can run in any environment (local or AWS) without
extra test dependencies.
"""

import json
import os
import sys
import time
import urllib.error
import urllib.request
from typing import Any, Dict, Optional, Tuple


class UnifiedLogger:
    """Centralized logger for test output.
    
    This logger ensures all output goes through a single mechanism,
    preventing duplicates and ordering issues.
    
    When log_file is provided:
    - All output writes directly to file (no stdout)
    - Prevents duplicates when shell script redirects stdout to log file
    
    When log_file is NOT provided:
    - All output goes to stdout (normal Python behavior)
    """
    
    def __init__(self, log_file: Optional[str] = None):
        """Initialize logger.
        
        Args:
            log_file: Optional path to log file. If provided, all output
                     will be written directly to this file. If not provided,
                     output goes to stdout.
        """
        self.log_file = log_file
    
    def write(self, msg: str = "") -> None:
        """Write a message using the unified mechanism.
        
        Strategy:
        - If log_file: write directly to file (immediate, no buffering)
        - If no log_file: print to stdout (normal Python behavior)
        
        This ensures:
        1. No duplicates (only one write path)
        2. Consistent ordering (all writes sequential)
        3. No buffering issues (direct file writes are immediate)
        """
        if self.log_file:
            # Direct file write (immediate, no buffering)
            # DO NOT print to stdout - shell script redirects it, causing duplicates
            with open(self.log_file, "a", encoding="utf-8") as f:
                f.write(msg + "\n")
        else:
            # Normal stdout output
            print(msg)
    
    def header(self, title: str) -> None:
        """Print a section header (80-char separator + title)."""
        self.write("=" * 80)
        self.write(title)
        self.write("=" * 80)
    
    def subheader(self, title: str) -> None:
        """Print a subsection header (80-char dash separator + title)."""
        self.write("")
        self.write("-" * 80)
        self.write(title)
        self.write("-" * 80)


def get_api_base_url(explicit: Optional[str] = None) -> str:
    """
    Return the base URL for the backend API.

    Priority:
    1. `explicit` argument (e.g. passed from CLI as --test-api-base-url)
    2. TEST_API_BASE_URL (explicit for tests, e.g. https://my-alb-or-cloudfront)
    3. BACKEND_API_URL   (if already set in env)
    4. http://localhost:5001 (sensible default for local docker-compose)
    """
    base = (
        (explicit or "").strip()
        or os.environ.get("TEST_API_BASE_URL", "").strip()
        or os.environ.get("BACKEND_API_URL", "").strip()
        or "http://localhost:5001"
    )
    # Strip trailing slash to make joining paths easier
    return base.rstrip("/")


def _http_post_json(url: str, payload: Dict[str, Any], timeout: int = 30) -> Tuple[int, Dict[str, Any]]:
    """
    Minimal JSON POST helper using urllib (no external dependencies).

    Returns: (status_code, json_body_dict)
    Raises: RuntimeError on network/parse errors.
    """
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        url=url,
        data=data,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            status = resp.getcode()
            body = resp.read()
    except urllib.error.HTTPError as e:
        # Try to read JSON body even on HTTP error, to surface useful error info.
        try:
            raw = e.read()
            text = raw.decode("utf-8", errors="replace")
            parsed = json.loads(text)
        except Exception:
            parsed = {"error": str(e)}
        return e.code, parsed
    except Exception as e:
        raise RuntimeError(f"HTTP request to {url} failed: {e}") from e

    try:
        text = body.decode("utf-8", errors="replace")
        parsed = json.loads(text)
    except Exception as e:
        raise RuntimeError(f"Failed to parse JSON response from {url}: {e}") from e

    return status, parsed


def run_query(
    query: str,
    max_retries: int = 3,
    backoff_seconds: float = 1.0,
    base_url: Optional[str] = None,
    timeout: Optional[int] = None,
) -> Dict[str, Any]:
    """
    Call the `/query` endpoint with the given natural language query.

    This helper wraps basic retry logic for transient issues (e.g. just-deployed
    ECS tasks becoming healthy).

    Args:
        query: Natural language query string
        max_retries: Maximum number of retry attempts
        backoff_seconds: Base backoff time in seconds (multiplied by attempt number)
        base_url: Optional explicit API base URL
        timeout: Optional timeout in seconds for each HTTP request

    Returns:
        Parsed JSON response as a dict.

    Raises:
        RuntimeError if the request fails or no successful response is obtained.
    """
    base_url = get_api_base_url(base_url)
    url = f"{base_url}/query"
    last_error: str = ""
    request_timeout = timeout or 30  # Default 30s per request

    for attempt in range(1, max_retries + 1):
        try:
            status, body = _http_post_json(url, {"query": query}, timeout=request_timeout)
            if status == 200:
                return body
            last_error = f"HTTP {status}: {body}"
        except Exception as e:  # noqa: BLE001
            last_error = str(e)

        if attempt < max_retries:
            time.sleep(backoff_seconds * attempt)

    raise RuntimeError(
        f"Failed to run query after {max_retries} attempts. Last error: {last_error}"
    )


def assert_contains(text: str, expected_substring: str, label: str) -> None:
    """
    Simple assertion helper: ensure `expected_substring` is present in `text`.

    Raises AssertionError with a clear message if the check fails.
    The error message is structured to be easily parseable for summary generation.
    """
    if expected_substring.lower() not in text.lower():
        # Format error message with clear markers for parsing
        error_msg = (
            f"EXPECTED_SUBSTRING_NOT_FOUND\n"
            f"LABEL: {label}\n"
            f"EXPECTED: {expected_substring}\n"
            f"ACTUAL_FULL: {text}\n"
            f"ACTUAL_FIRST_400: {text[:400]}"
        )
        raise AssertionError(error_msg)


def print_header(title: str, log_file: Optional[str] = None) -> None:
    """Pretty-print a section header for CLI output.
    
    Args:
        title: Header text
        log_file: Optional log file path. If provided, uses UnifiedLogger
                 for consistent output. If not provided, uses stdout (backward compatible).
    """
    if log_file:
        logger = UnifiedLogger(log_file)
        logger.header(title)
    else:
        # Original behavior for backward compatibility
        print("=" * 80)
        print(title)
        print("=" * 80)


def print_subheader(title: str, log_file: Optional[str] = None) -> None:
    """Pretty-print a subsection header for CLI output.
    
    Args:
        title: Subheader text
        log_file: Optional log file path. If provided, uses UnifiedLogger
                 for consistent output. If not provided, uses stdout (backward compatible).
    """
    if log_file:
        logger = UnifiedLogger(log_file)
        logger.subheader(title)
    else:
        # Original behavior for backward compatibility
        print("\n" + "-" * 80)
        print(title)
        print("-" * 80)


def main_cli_entry(test_func) -> None:
    """
    Convenience wrapper for running a test function as a script.

    - Prints a clear header.
    - Catches AssertionError and other exceptions.
    - Exits with non-zero status on failure so CI can detect failures.
    """
    try:
        test_func()
    except AssertionError as e:
        print("\nTEST FAILED (assertion):")
        print(e)
        sys.exit(1)
    except Exception as e:  # noqa: BLE001
        print("\nTEST FAILED (unexpected error):")
        print(repr(e))
        sys.exit(1)
    else:
        print("\nAll checks passed.")
        sys.exit(0)


