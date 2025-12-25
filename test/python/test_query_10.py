"""
End-to-end tests for the `/query` endpoint using 10 representative questions.

These tests are designed to be:
- **Black-box**: They only talk to the HTTP API (no direct DB access).
- **Fuzzy**: They assert on key phrases/numbers, not exact wording.
- **Documented**: Each test explains what it's checking and why.

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


def _tests_definitions() -> List[QueryTestCase]:
    """
    Define the 10 tests, reusing the queries we've been exercising manually.

    Test mapping:
      1. Average feedback rating                      (Test 2)
      2. Brand with highest average rating            (Test 3)
      3. Count negative feedbacks                     (Test 4)
      4. Percentage of positive feedback              (Test 5)
      5. Negative feedback about noise                (Test 6)
      6. Count feedbacks with rating > 7              (Test 7)
      7. Average rating for positive feedbacks        (Test 8)
      8. Negative feedback about temperature control  (Test 9)
      9. Data-integrity style qualitative check       (related to Test 1)
     10. Low-rating feedbacks – top 3 problems        (new complex query)
    """

    tests: List[QueryTestCase] = []

    # 1. Average feedback rating (numeric)
    tests.append(
        QueryTestCase(
            name="Average feedback rating",
            query="What is the average feedback rating?",
            validator=lambda resp: _validate_avg_feedback_rating(resp),
        )
    )

    # 2. Brand with highest average rating (Samsung ~ 9.0)
    tests.append(
        QueryTestCase(
            name="Brand with highest average rating",
            query="Which brand has the highest average customer rating, and what is that average?",
            validator=lambda resp: _validate_brand_highest_avg(resp),
        )
    )

    # 3. Count negative feedbacks (~50)
    tests.append(
        QueryTestCase(
            name="Count negative feedbacks",
            query="How many negative feedbacks are there?",
            validator=lambda resp: _validate_count_negative(resp),
        )
    )

    # 4. Percentage of positive feedbacks (~50%)
    tests.append(
        QueryTestCase(
            name="Percentage positive feedback",
            query="What percentage of feedback is positive?",
            validator=lambda resp: _validate_percentage_positive(resp),
        )
    )

    # 5. Noise-related complaints (semantic search)
    tests.append(
        QueryTestCase(
            name="Negative feedback about noise",
            query="What do customers with negative feedback say about noise?",
            validator=lambda resp: _validate_noise_feedback(resp),
        )
    )

    # 6. Count feedbacks with rating above 7 (~100)
    tests.append(
        QueryTestCase(
            name="Count feedbacks rating above 7",
            query="How many feedbacks have a rating above 7?",
            validator=lambda resp: _validate_count_above_seven(resp),
        )
    )

    # 7. Average rating for positive feedbacks (~9.0)
    tests.append(
        QueryTestCase(
            name="Average rating for positive feedbacks",
            query="What is the average rating for positive feedbacks?",
            validator=lambda resp: _validate_avg_positive(resp),
        )
    )

    # 8. Temperature control complaints (semantic search)
    tests.append(
        QueryTestCase(
            name="Negative feedback about temperature control",
            query="What do customers with negative feedback say about temperature control?",
            validator=lambda resp: _validate_temperature_feedback(resp),
        )
    )

    # 9. Qualitative data-integrity style check:
    #    Ask for a summary of rating distribution to ensure the agent can
    #    reason about Negative/Neutral/Positive buckets.
    tests.append(
        QueryTestCase(
            name="Rating distribution summary",
            query="Summarize how many feedbacks are Negative, Neutral, and Positive.",
            validator=lambda resp: _validate_rating_distribution(resp),
        )
    )

    # 10. Complex query: top 3 problems for low-rating feedbacks
    tests.append(
        QueryTestCase(
            name="Top 3 problems for low-rating feedbacks",
            query="For the low rating customer feedbacks, what are the top 3 problems?",
            validator=lambda resp: _validate_top3_low_rating_problems(resp),
        )
    )

    return tests


# ---------------------------------------------------------------------------
# Individual validators
# ---------------------------------------------------------------------------


def _validate_avg_feedback_rating(resp: Dict) -> None:
    label = "Average feedback rating"
    answer = _validate_has_answer_and_iterations(resp, label)
    # Fuzzy check: should mention "average" and a numeric rating.
    assert_contains(answer, "average", label)
    has_digit = any(ch.isdigit() for ch in answer)
    if not has_digit:
        raise AssertionError(f"[{label}] Expected a numeric rating in the answer.")


def _validate_brand_highest_avg(resp: Dict) -> None:
    label = "Brand with highest average rating"
    answer = _validate_has_answer_and_iterations(resp, label)
    # From our data and previous tests, Samsung with ~9.0 should be the winner.
    assert_contains(answer, "Samsung", label)
    # Don't insist on exact formatting, just check that 9 or 9.0/9.00 appears.
    if "9.0" not in answer and "9.00" not in answer and "9 out of 10" not in answer:
        raise AssertionError(
            f"[{label}] Expected average rating around 9.0 for Samsung; "
            f"got answer: {answer[:300]!r}"
        )


def _validate_count_negative(resp: Dict) -> None:
    label = "Count negative feedbacks"
    answer = _validate_has_answer_and_iterations(resp, label)
    # Exact count from data: 50 negative feedbacks.
    assert_contains(answer, "50", label)
    assert_contains(answer, "negative", label)


def _validate_percentage_positive(resp: Dict) -> None:
    label = "Percentage positive feedback"
    answer = _validate_has_answer_and_iterations(resp, label)
    # We expect roughly 50% positive feedback.
    if "50.00%" not in answer and "50%" not in answer and "50.0%" not in answer:
        raise AssertionError(
            f"[{label}] Expected percentage around 50%%; "
            f"got answer: {answer[:300]!r}"
        )
    assert_contains(answer, "positive", label)


def _validate_noise_feedback(resp: Dict) -> None:
    label = "Negative feedback about noise"
    answer = _validate_has_answer_and_iterations(resp, label)
    # Fuzzy checks for known phrases and themes.
    assert_contains(answer, "noise", label)
    # These phrases come from our synthetic data / previous logs.
    any_phrase = any(
        phrase in answer.lower()
        for phrase in [
            "constant humming noise",
            "freight train",
            "very annoying",
        ]
    )
    if not any_phrase:
        raise AssertionError(
            f"[{label}] Expected at least one known noise-related phrase; "
            f"got answer: {answer[:400]!r}"
        )


def _validate_count_above_seven(resp: Dict) -> None:
    label = "Count feedbacks rating above 7"
    answer = _validate_has_answer_and_iterations(resp, label)
    # Exact count from data: 100 feedbacks with rating > 7.
    assert_contains(answer, "100", label)
    # Ensure it's really about "rating above 7".
    assert_contains(answer, "rating", label)


def _validate_avg_positive(resp: Dict) -> None:
    label = "Average rating for positive feedbacks"
    answer = _validate_has_answer_and_iterations(resp, label)
    assert_contains(answer, "positive", label)
    # From the data integrity check: Positive avg ~ 9.0
    if "9.0" not in answer and "9.00" not in answer and "9 out of 10" not in answer:
        raise AssertionError(
            f"[{label}] Expected average rating for positive feedbacks around 9.0; "
            f"got answer: {answer[:300]!r}"
        )


def _validate_temperature_feedback(resp: Dict) -> None:
    label = "Negative feedback about temperature control"
    answer = _validate_has_answer_and_iterations(resp, label)
    assert_contains(answer, "temperature", label)
    any_phrase = any(
        phrase in answer.lower()
        for phrase in [
            "inconsistent",
            "fluctuates",
            "temperature control",
            "freezer",
        ]
    )
    if not any_phrase:
        raise AssertionError(
            f"[{label}] Expected temperature-related complaints; "
            f"got answer: {answer[:400]!r}"
        )


def _validate_rating_distribution(resp: Dict) -> None:
    label = "Rating distribution summary"
    answer = _validate_has_answer_and_iterations(resp, label)
    # We don't insist on exact counts here, just that the agent
    # talks explicitly about all three buckets.
    assert_contains(answer, "negative", label)
    assert_contains(answer, "neutral", label)
    assert_contains(answer, "positive", label)


def _validate_top3_low_rating_problems(resp: Dict) -> None:
    label = "Top 3 problems for low-rating feedbacks"
    answer = _validate_has_answer_and_iterations(resp, label)
    # From manual runs, we expect themes like:
    # - Door issues
    # - Temperature control
    # - Ice maker / water / freezer problems
    assert_contains(answer, "top 3", label)
    assert_contains(answer, "door", label)
    assert_contains(answer, "temperature", label)

    any_third = any(
        phrase in answer.lower()
        for phrase in ["ice", "water", "freezer", "component", "functional"]
    )
    if not any_third:
        raise AssertionError(
            f"[{label}] Expected a third problem category (ice/water/freezer/component); "
            f"got answer: {answer[:400]!r}"
        )


# ---------------------------------------------------------------------------
# Main runner
# ---------------------------------------------------------------------------


def run_single_test(
    test_number: int,
    base_url: Optional[str] = None,
    log_file: Optional[str] = None,
    timeout: Optional[int] = None,
) -> bool:
    """Run a single test by number (1-indexed).

    Args:
        test_number: Test number (1-10)
        base_url: Optional explicit API base URL
        log_file: Optional path to log file (for appending output)
        timeout: Optional timeout in seconds (for systems without timeout command)

    Returns:
        True if test passed, False otherwise
    """
    tests = _tests_definitions()
    
    if test_number < 1 or test_number > len(tests):
        raise ValueError(f"Test number must be between 1 and {len(tests)}, got {test_number}")
    
    test = tests[test_number - 1]  # Convert to 0-indexed
    
    def _print(msg: str = "") -> None:
        """Print to both stdout and log file if provided."""
        print(msg)
        if log_file:
            with open(log_file, "a", encoding="utf-8") as f:
                f.write(msg + "\n")
    
    try:
        _print(f"Test {test_number}: {test.name}")
        _print(f"Query: {test.query}")
        
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
                resp = run_query(test.query, base_url=base_url, timeout=timeout)
                actual_response = resp.get("answer", "")
                test.validator(resp)
            finally:
                signal.alarm(0)  # Cancel alarm
                signal.signal(signal.SIGALRM, old_handler)  # Restore handler
        else:
            resp = run_query(test.query, base_url=base_url)
            actual_response = resp.get("answer", "")
            test.validator(resp)
        
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
            for i, line in enumerate(lines):
                if line.startswith("EXPECTED: "):
                    expected = line.replace("EXPECTED: ", "")
                elif line.startswith("ACTUAL_FULL: "):
                    actual_full = line.replace("ACTUAL_FULL: ", "")
            
            _print(f"Expected (substring): {expected}")
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


def run_all_tests(
    base_url: Optional[str] = None,
    test_number: Optional[int] = None,
    log_file: Optional[str] = None,
    timeout: Optional[int] = None,
) -> None:
    """Run query tests and print a concise report.

    Args:
        base_url: Optional explicit API base URL, typically passed from
                  the CLI via --test-api-base-url. If None, the helper
                  will fall back to environment variables and defaults.
        test_number: Optional test number (1-10) to run only that test.
                     If None, runs all tests.
        log_file: Optional path to log file (for appending output).
    """
    if test_number is not None:
        # Run single test
        run_single_test(test_number, base_url=base_url, log_file=log_file, timeout=timeout)
        return
    
    # Run all tests
    print_header("Running 10 query tests against /query endpoint")
    tests = _tests_definitions()

    for idx, test in enumerate(tests, start=1):
        print_subheader(f"Test {idx}: {test.name}")
        print(f"Query: {test.query}")
        resp = run_query(test.query, base_url=base_url)
        test.validator(resp)
        print("Result: OK")


def _main() -> None:
    parser = argparse.ArgumentParser(
        description="Run 10 end-to-end /query tests against the API.",
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
        "--test-number",
        dest="test_number",
        type=int,
        metavar="N",
        help="Run only test number N (1-10). If omitted, runs all tests.",
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

    # Wrap run_all_tests via the generic CLI entry helper so we get consistent
    # exit codes and error reporting.
    def _runner() -> None:
        run_all_tests(
            base_url=args.test_api_base_url,
            test_number=args.test_number,
            log_file=args.log_file,
            timeout=args.timeout,
        )

    main_cli_entry(_runner)


if __name__ == "__main__":
    # Allow this module to be run directly:
    #   python -m test.python.test_query_10 --test-api-base-url ...
    # or:
    #   python test/python/test_query_10.py --test-api-base-url ...
    _main()



