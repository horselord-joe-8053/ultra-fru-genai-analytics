"""
Validators for common test queries.

This module contains all the validation functions used by the test queries
in common_test_queries.py.
"""

from typing import Dict

from .common_utils import assert_contains


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

