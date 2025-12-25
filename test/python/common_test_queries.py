"""
Common test queries for the `/query` endpoint.

This module provides a flexible dictionary-based approach to test queries,
allowing selective execution of specific queries by their three-character codes.

Configuration:
- Set `TEST_API_BASE_URL` (preferred) or `BACKEND_API_URL` to point at the API.
  Examples:
    - Local docker-compose:   TEST_API_BASE_URL=http://localhost:5001
    - AWS ALB / CloudFront:   TEST_API_BASE_URL=https://<your-domain>
"""

from __future__ import annotations

import argparse
from typing import Callable, Dict, List, Optional

from .common_utils import (
    UnifiedLogger,
    assert_contains,
    main_cli_entry,
    print_header,
    print_subheader,
    run_query,
)


class QueryTestCase:
    """Simple container for a query test definition."""

    def __init__(
        self,
        name: str,
        query: str,
        validator: Callable[[Dict], None],
    ) -> None:
        self.name = name
        self.query = query
        self.validator = validator


def _validate_has_answer_and_iterations(resp: Dict, label: str) -> str:
    """
    Basic sanity checks shared by all tests:
    - `answer` exists and is non-empty
    - `iterations` is between 1 and 5 (3 × 5 setup on server side)
    """
    if "answer" not in resp:
        raise AssertionError(f"[{label}] Response missing 'answer' field: {resp}")
    answer = str(resp.get("answer") or "").strip()
    if not answer:
        raise AssertionError(f"[{label}] Empty answer field.")

    iterations = resp.get("iterations")
    if not isinstance(iterations, int) or not (1 <= iterations <= 5):
        raise AssertionError(
            f"[{label}] iterations should be integer in [1,5], "
            f"got: {iterations!r}"
        )
    return answer


# ---------------------------------------------------------------------------
# Test Query Definitions (Dictionary with three-char codes)
# ---------------------------------------------------------------------------

def get_test_queries() -> Dict[str, QueryTestCase]:
    """
    Return a dictionary of test queries keyed by three-character codes.
    
    Returns:
        Dictionary mapping three-char codes to QueryTestCase objects.
    """
    from .common_test_queries_validators import (
        _validate_avg_feedback_rating,
        _validate_avg_positive,
        _validate_brand_highest_avg,
        _validate_count_above_seven,
        _validate_count_negative,
        _validate_noise_feedback,
        _validate_percentage_positive,
        _validate_rating_distribution,
        _validate_temperature_feedback,
        _validate_top3_low_rating_problems,
    )
    
    return {
        "AVG": QueryTestCase(
            name="Average feedback rating",
            query="What is the average feedback rating?",
            validator=_validate_avg_feedback_rating,
        ),
        "BRD": QueryTestCase(
            name="Brand with highest average rating",
            query="Which brand has the highest average customer rating, and what is that average?",
            validator=_validate_brand_highest_avg,
        ),
        "CNT": QueryTestCase(
            name="Count negative feedbacks",
            query="How many negative feedbacks are there?",
            validator=_validate_count_negative,
        ),
        "PCT": QueryTestCase(
            name="Percentage positive feedback",
            query="What percentage of feedback is positive?",
            validator=_validate_percentage_positive,
        ),
        "NOI": QueryTestCase(
            name="Negative feedback about noise",
            query="What do customers with negative feedback say about noise?",
            validator=_validate_noise_feedback,
        ),
        "R07": QueryTestCase(
            name="Count feedbacks rating above 7",
            query="How many feedbacks have a rating above 7?",
            validator=_validate_count_above_seven,
        ),
        "AVP": QueryTestCase(
            name="Average rating for positive feedbacks",
            query="What is the average rating for positive feedbacks?",
            validator=_validate_avg_positive,
        ),
        "TMP": QueryTestCase(
            name="Negative feedback about temperature control",
            query="What do customers with negative feedback say about temperature control?",
            validator=_validate_temperature_feedback,
        ),
        "RDS": QueryTestCase(
            name="Rating distribution summary",
            query="Summarize how many feedbacks are Negative, Neutral, and Positive.",
            validator=_validate_rating_distribution,
        ),
        "TOP": QueryTestCase(
            name="Top 3 problems for low-rating feedbacks",
            query="For the low rating customer feedbacks, what are the top 3 problems?",
            validator=_validate_top3_low_rating_problems,
        ),
    }


# ---------------------------------------------------------------------------
# Test Execution Functions
# ---------------------------------------------------------------------------

def run_single_test(
    test_code: str,
    test_case: QueryTestCase,
    base_url: Optional[str] = None,
    log_file: Optional[str] = None,
    timeout: Optional[int] = None,
) -> bool:
    """Run a single test by code.

    Args:
        test_code: Three-character test code
        test_case: QueryTestCase to execute
        base_url: Optional explicit API base URL
        log_file: Optional path to log file (for appending output)
        timeout: Optional timeout in seconds (for systems without timeout command)

    Returns:
        True if test passed, False otherwise
    """
    def _print(msg: str = "") -> None:
        """Print to stdout and/or log file.
        
        When log_file is provided, we write directly to it and avoid printing to stdout
        to prevent duplicate output (since the shell script also redirects stdout to the log file).
        When no log_file is provided, we print to stdout normally.
        """
        if log_file:
            # Write directly to log file only (don't print to stdout to avoid duplicates)
            with open(log_file, "a", encoding="utf-8") as f:
                f.write(msg + "\n")
        else:
            # Print to stdout when no log file is provided
            print(msg)
    
    try:
        _print(f"Test {test_code}: {test_case.name}")
        _print(f"Query: {test_case.query}")
        
        # Capture the actual response for logging
        actual_response = None
        
        # Apply timeout if specified (for systems without timeout command)
        if timeout is not None:
            import signal
            
            def timeout_handler(signum, frame):
                raise TimeoutError(f"Test exceeded timeout of {timeout} seconds")
            
            # Set up signal-based timeout (Unix only)
            old_handler = signal.signal(signal.SIGALRM, timeout_handler)
            signal.alarm(timeout)
            try:
                resp = run_query(test_case.query, base_url=base_url, timeout=timeout)
                actual_response = resp.get("answer", "")
                test_case.validator(resp)
            finally:
                signal.alarm(0)  # Cancel alarm
                signal.signal(signal.SIGALRM, old_handler)  # Restore handler
        else:
            resp = run_query(test_case.query, base_url=base_url)
            actual_response = resp.get("answer", "")
            test_case.validator(resp)
        
        _print("Result: OK")
        _print(f"Actual Answer: {actual_response}")
        return True
    except AssertionError as e:
        # Parse assertion error to extract Expected and Actual
        error_str = str(e)
        _print("Result: FAILED")
        _print("=" * 80)
        _print("TEST FAILURE DETAILS:")
        _print("=" * 80)
        
        if "EXPECTED_SUBSTRING_NOT_FOUND" in error_str:
            # Parse structured error message
            lines = error_str.split("\n")
            expected = ""
            actual_full = ""
            for line in lines:
                if line.startswith("EXPECTED: "):
                    expected = line.replace("EXPECTED: ", "").strip()
                elif line.startswith("ACTUAL_FULL: "):
                    actual_full = line.replace("ACTUAL_FULL: ", "").strip()
            
            if expected:
                _print(f"Expected (substring): {expected}")
            if actual_full:
                _print(f"Actual (full answer): {actual_full}")
        else:
            # Fallback for other assertion errors
            _print(f"Error: {error_str}")
            if actual_response:
                _print(f"Actual Answer: {actual_response}")
        
        _print("=" * 80)
        raise
    except Exception as e:
        _print(f"Result: FAILED - {e}")
        if actual_response:
            _print(f"Actual Answer: {actual_response}")
        raise


def run_tests(
    query_codes: List[str],
    base_url: Optional[str] = None,
    log_file: Optional[str] = None,
    timeout: Optional[int] = None,
) -> None:
    """Run tests specified by their three-character codes.

    Args:
        query_codes: List of three-character codes (e.g., ["AVG", "BRD", "TOP"])
        base_url: Optional explicit API base URL
        log_file: Optional path to log file (for appending output)
        timeout: Optional timeout in seconds (for systems without timeout command)
    """
    test_queries = get_test_queries()
    
    # Validate all codes exist
    invalid_codes = [code for code in query_codes if code not in test_queries]
    if invalid_codes:
        raise ValueError(
            f"Invalid test codes: {invalid_codes}. "
            f"Valid codes: {list(test_queries.keys())}"
        )
    
    # Initialize unified logger
    logger = UnifiedLogger(log_file)
    
    # Skip headers when log_file is provided (called from shell script which already provides headers)
    # Only print headers when running standalone (no log_file)
    if not log_file:
        # Use logger methods instead of print_header/print_subheader
        logger.header(f"Running {len(query_codes)} query test(s) against /query endpoint")
    
    for idx, code in enumerate(query_codes, start=1):
        test_case = test_queries[code]
        # Skip subheader when log_file is provided (shell script already provides context)
        if not log_file:
            logger.subheader(f"Test {idx}/{len(query_codes)}: {code} - {test_case.name}")
        # run_single_test() will print query and result using its own logger instance
        run_single_test(code, test_case, base_url=base_url, log_file=log_file, timeout=timeout)


def _main() -> None:
    parser = argparse.ArgumentParser(
        description="Run query tests against the API using three-character codes.",
    )
    parser.add_argument(
        "--test-api-base-url",
        dest="test_api_base_url",
        metavar="URL",
        help=(
            "Explicit base URL for the backend API, e.g. "
            "https://my-cloudfront-domain or http://localhost:5001. "
            "If omitted, the tests will fall back to TEST_API_BASE_URL, "
            "BACKEND_API_URL, or http://localhost:5001."
        ),
    )
    parser.add_argument(
        "--query-list",
        dest="query_list",
        metavar="CODES",
        nargs="+",
        help=(
            "List of three-character test codes to run (e.g., AVG BRD TOP). "
            "If omitted, runs all available tests. "
            f"Valid codes: {', '.join(sorted(get_test_queries().keys()))}"
        ),
    )
    parser.add_argument(
        "--log-file",
        dest="log_file",
        metavar="PATH",
        help="Path to log file for appending test output.",
    )
    parser.add_argument(
        "--timeout",
        dest="timeout",
        type=int,
        metavar="SECONDS",
        help="Timeout in seconds for the test (if no system timeout command available).",
    )
    args = parser.parse_args()
    
    # Determine which queries to run
    test_queries = get_test_queries()
    if args.query_list:
        query_codes = args.query_list
    else:
        # Run all queries in sorted order
        query_codes = sorted(test_queries.keys())
    
    # Wrap run_tests via the generic CLI entry helper so we get consistent
    # exit codes and error reporting.
    def _runner() -> None:
        run_tests(
            query_codes=query_codes,
            base_url=args.test_api_base_url,
            log_file=args.log_file,
            timeout=args.timeout,
        )
    
    main_cli_entry(_runner)


if __name__ == "__main__":
    # Allow this module to be run directly:
    #   python -m test.python.common_test_queries --query-list AVG BRD TOP
    # or:
    #   python test/python/common_test_queries.py --query-list AVG BRD TOP
    _main()

