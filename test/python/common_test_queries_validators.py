"""
Validators for common test queries.

This module contains all the validation functions used by the test queries
in common_test_queries.py.
"""

from typing import Dict

from .common_utils import assert_contains


def _validate_has_answer_and_iterations(resp: Dict, label: str, test_code: str = None) -> str:
    """
    Basic sanity checks shared by all tests:
    - `answer` exists and is non-empty
    - `iterations` is between 1 and 5 (3 × 5 setup on server side)
    - `data_available` is True (if present) - ensures data was successfully retrieved
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
    
    # Check data availability (if metadata is present)
    data_available = resp.get("data_available")
    
    # Treat None as False (no data available) - defensive check
    # If metadata is missing, we need to check tool_calls to determine if data was retrieved
    if data_available is None:
        # Check tool_calls to see if any SQL or semantic search succeeded
        tool_calls = resp.get("tool_calls", [])
        has_successful_sql = any(
            tc.get("tool") == "execute_sql" and 
            tc.get("output", {}).get("success", False) and
            tc.get("output", {}).get("row_count", 0) > 0
            for tc in tool_calls
        )
        has_successful_semantic = any(
            tc.get("tool") == "semantic_search" and 
            tc.get("output", {}).get("success", False) and
            tc.get("output", {}).get("row_count", 0) > 0
            for tc in tool_calls
        )
        data_available = has_successful_sql or has_successful_semantic
    
    # If data_available is False (or None treated as False), check for hallucinations
    if not data_available:
        # Check for tool-calling format in answer (indicates improper synthesis)
        import re
        has_tool_call_format = bool(re.search(r'<generate_sql>|<execute_sql>|<semantic_search>', answer))
        if has_tool_call_format:
            raise AssertionError(
                f"[{label}] CRITICAL: Answer contains tool-calling format (not properly synthesized). "
                f"No data was successfully retrieved. "
                f"Answer: {answer[:300]}"
            )
        
        # Check for numeric values (hallucination if no data)
        has_numeric_value = bool(re.search(r'\d+\.?\d+', answer))  # Matches "5.50", "6.62", etc.
        if has_numeric_value:
            raise AssertionError(
                f"[{label}] CRITICAL: Answer contains numeric values when no data was retrieved. "
                f"This is a hallucination. "
                f"Answer: {answer[:300]}"
            )
        
        raise AssertionError(
            f"[{label}] CRITICAL: No data was successfully retrieved from the database. "
            f"The agent failed to execute any successful queries. "
            f"Answer: {answer[:200]}"
        )
    
    # Check for hallucination indicators when data_available is False (defensive)
    if data_available is False:
        answer_lower = answer.lower()
        hallucination_indicators = [
            "based on query results",
            "according to the data",
            "the query results show",
            "from the database",
            "the data indicates",
            "based on the information",
            "the database shows",
            "query results indicate",
            "from the query",
            "the results show",
        ]
        
        # Check for numeric values (likely hallucinated if no data)
        import re
        has_numbers = bool(re.search(r'\d+\.?\d*', answer))
        has_calculated_values = bool(re.search(r'\d+\.\d+', answer))  # Decimals suggest calculations
        
        if any(indicator in answer_lower for indicator in hallucination_indicators):
            raise AssertionError(
                f"[{label}] CRITICAL: Answer claims to have data when none was retrieved. "
                f"This is a hallucination. Answer: {answer[:300]}"
            )
        
        if has_numbers and has_calculated_values:
            raise AssertionError(
                f"[{label}] CRITICAL: Answer contains numeric values when no data was retrieved. "
                f"This is likely a hallucination. Answer: {answer[:300]}"
            )
    
    return answer


def _validate_avg_feedback_rating(resp: Dict, test_code: str = "AVG") -> None:
    label = "Average feedback rating"
    answer = _validate_has_answer_and_iterations(resp, label, test_code)
    
    # CRITICAL: Verify that SQL execution succeeded for quantitative queries
    # This query requires SQL execution to calculate AVG
    primary_result_type = resp.get("primary_result_type")
    primary_result_row_count = resp.get("primary_result_row_count", 0)
    
    # Check tool_calls to verify SQL actually succeeded
    tool_calls = resp.get("tool_calls", [])
    sql_success = any(
        tc.get("tool") == "execute_sql" and 
        tc.get("output", {}).get("success", False) and
        tc.get("output", {}).get("row_count", 0) > 0
        for tc in tool_calls
    )
    
    # If SQL failed (no successful execution with rows), this is a critical error for quantitative queries
    # Trust sql_success over metadata if it's True (metadata might be missing but SQL actually worked)
    if not sql_success:
        # Check for numeric values in answer (hallucination if SQL failed)
        import re
        has_numeric_value = bool(re.search(r'\d+\.?\d+', answer))  # Matches "5.50", "6.62", etc.
        has_tool_call_format = bool(re.search(r'<generate_sql>|<execute_sql>', answer))
        
        if has_numeric_value:
            raise AssertionError(
                f"[{label}] CRITICAL: Answer contains numeric values but SQL execution failed. "
                f"This is a hallucination. sql_success={sql_success}. "
                f"Answer: {answer[:300]}"
            )
        
        if has_tool_call_format:
            raise AssertionError(
                f"[{label}] CRITICAL: Answer contains tool-calling format (not properly synthesized). "
                f"SQL execution failed. "
                f"Answer: {answer[:300]}"
            )
        
        # Check if answer claims to have data (data-implying phrases)
        answer_lower = answer.lower()
        if any(phrase in answer_lower for phrase in [
            "based on query results", "according to the data", "the query results show",
            "from the database", "the data indicates", "based on the information",
            "the database shows", "query results indicate", "from the query", "the results show"
        ]):
            raise AssertionError(
                f"[{label}] CRITICAL: Answer claims to have data but SQL execution failed. "
                f"sql_success={sql_success}. "
                f"Answer: {answer[:300]}"
            )
    
    # Fuzzy check: should mention "average" and a numeric rating.
    assert_contains(answer, "average", label)
    has_digit = any(ch.isdigit() for ch in answer)
    if not has_digit:
        raise AssertionError(f"[{label}] Expected a numeric rating in the answer.")


def _validate_brand_highest_avg(resp: Dict, test_code: str = "BRD") -> None:
    label = "Brand with highest average rating"
    answer = _validate_has_answer_and_iterations(resp, label, test_code)
    # From our data and previous tests, Samsung with ~9.0 should be the winner.
    assert_contains(answer, "Samsung", label)
    # Don't insist on exact formatting, just check that 9 or 9.0/9.00 appears.
    if "9.0" not in answer and "9.00" not in answer and "9 out of 10" not in answer:
        raise AssertionError(
            f"[{label}] Expected average rating around 9.0 for Samsung; "
            f"got answer: {answer[:300]!r}"
        )


def _validate_count_negative(resp: Dict, test_code: str = "CNT") -> None:
    label = "Count negative feedbacks"
    answer = _validate_has_answer_and_iterations(resp, label, test_code)
    # Exact count from data: 50 negative feedbacks.
    assert_contains(answer, "50", label)
    assert_contains(answer, "negative", label)


def _validate_percentage_positive(resp: Dict, test_code: str = "PCT") -> None:
    label = "Percentage positive feedback"
    answer = _validate_has_answer_and_iterations(resp, label, test_code)
    # We expect roughly 50% positive feedback.
    if "50.00%" not in answer and "50%" not in answer and "50.0%" not in answer:
        raise AssertionError(
            f"[{label}] Expected percentage around 50%%; "
            f"got answer: {answer[:300]!r}"
        )
    assert_contains(answer, "positive", label)


def _validate_noise_feedback(resp: Dict, test_code: str = "NOI") -> None:
    label = "Negative feedback about noise"
    answer = _validate_has_answer_and_iterations(resp, label, test_code)
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


def _validate_count_above_seven(resp: Dict, test_code: str = "R07") -> None:
    label = "Count feedbacks rating above 7"
    answer = _validate_has_answer_and_iterations(resp, label, test_code)
    # Exact count from data: 100 feedbacks with rating > 7.
    assert_contains(answer, "100", label)
    # Ensure it's really about "rating above 7".
    assert_contains(answer, "rating", label)


def _validate_avg_positive(resp: Dict, test_code: str = "AVP") -> None:
    label = "Average rating for positive feedbacks"
    answer = _validate_has_answer_and_iterations(resp, label, test_code)
    assert_contains(answer, "positive", label)
    # From the data integrity check: Positive avg ~ 9.0
    if "9.0" not in answer and "9.00" not in answer and "9 out of 10" not in answer:
        raise AssertionError(
            f"[{label}] Expected average rating for positive feedbacks around 9.0; "
            f"got answer: {answer[:300]!r}"
        )


def _validate_temperature_feedback(resp: Dict, test_code: str = "TMP") -> None:
    label = "Negative feedback about temperature control"
    answer = _validate_has_answer_and_iterations(resp, label, test_code)
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


def _validate_rating_distribution(resp: Dict, test_code: str = "RDS") -> None:
    label = "Rating distribution summary"
    answer = _validate_has_answer_and_iterations(resp, label, test_code)
    # We don't insist on exact counts here, just that the agent
    # talks explicitly about all three buckets.
    assert_contains(answer, "negative", label)
    assert_contains(answer, "neutral", label)
    assert_contains(answer, "positive", label)


def _validate_top3_low_rating_problems(resp: Dict, test_code: str = "TOP") -> None:
    label = "Top 3 problems for low-rating feedbacks"
    answer = _validate_has_answer_and_iterations(resp, label, test_code)
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

