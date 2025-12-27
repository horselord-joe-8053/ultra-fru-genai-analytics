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
        expected_answer: Optional[str] = None,
    ) -> None:
        self.name = name
        self.query = query
        self.validator = validator
        self.expected_answer = expected_answer or "Answer should contain expected substring(s) as defined by validator"


def _extract_deriving_process(resp: Dict, question: str) -> str:
    """
    Extract the deriving process summary including SQL queries executed.
    
    Args:
        resp: API response dictionary
        question: Original question asked
        
    Returns:
        Formatted string describing the process and SQL queries
    """
    method = resp.get("method", "simple")
    mode = resp.get("mode", "simple")
    
    # Check if agent mode was used
    tool_calls = resp.get("tool_calls", [])
    debug_info = resp.get("debug_info", {})
    
    # If debug_info has tool_calls, prefer those (they may have more complete data)
    if debug_info and "tool_calls" in debug_info:
        tool_calls = debug_info.get("tool_calls", tool_calls)
    
    if method == "agentic" or tool_calls:
        # Agent-based processing - show progressive steps
        process_parts = []
        step_num = 1
        
        # Helper function to extract SQL from tool output/input
        def extract_sql_from_tool(tool_call, current_idx):
            """Extract SQL from a tool call, handling various sources.
            
            Args:
                tool_call: The tool call dictionary
                current_idx: Current index in tool_calls (for looking backwards)
            """
            tool_input = tool_call.get("input", {})
            tool_output = tool_call.get("output", {})
            
            sql = None
            
            # 1. Try output["sql"] (most reliable - actual executed SQL)
            if isinstance(tool_output, dict):
                sql = tool_output.get("sql") or tool_output.get("sql_query")
            
            # 2. If output SQL not found or is placeholder, look backwards for generate_sql
            if not sql or (isinstance(sql, str) and (
                sql.lower().startswith(("the sql", "(the sql", "[the sql", "i will use")) or
                len(sql.strip()) < 20
            )):
                if current_idx > 0:
                    for prev_call in reversed(tool_calls[:current_idx]):
                        if prev_call.get("tool") == "generate_sql":
                            prev_output = prev_call.get("output", {})
                            if isinstance(prev_output, dict):
                                sql = prev_output.get("sql") or prev_output.get("sql_query")
                                if sql:
                                    break
            
            # 3. Last resort: try input, but only if it doesn't look like placeholder text
            if not sql or (isinstance(sql, str) and (
                sql.lower().startswith(("the sql", "(the sql", "[the sql", "i will use")) or
                len(sql.strip()) < 20
            )):
                if isinstance(tool_input, dict):
                    input_sql = tool_input.get("sql_query") or tool_input.get("sql")
                    if input_sql and isinstance(input_sql, str) and len(input_sql.strip()) > 20:
                        input_sql_lower = input_sql.lower().strip()
                        if not input_sql_lower.startswith(("the sql", "(the sql", "[the sql", "i will use")):
                            sql = input_sql
            
            # Validate SQL
            if sql and isinstance(sql, str) and sql.strip() and len(sql.strip()) > 20:
                sql_clean = sql.strip()
                sql_lower = sql_clean.lower()
                if not sql_lower.startswith(("the sql", "(the sql", "[the sql", "i will use")):
                    if any(keyword in sql_lower for keyword in ["select", "from", "where", "insert", "update", "delete"]):
                        return sql_clean
            
            return None
        
        # Iterate through tool calls in order to show progressive steps
        # Use enumerate to get index directly (avoids O(n) search per tool call)
        for current_idx, tool_call in enumerate(tool_calls):
            tool_name = tool_call.get("tool", "")
            tool_input = tool_call.get("input", {})
            tool_output = tool_call.get("output", {})
            success = tool_output.get("success", False) if isinstance(tool_output, dict) else False
            
            if tool_name == "generate_sql":
                # Step: Generate SQL
                sql = extract_sql_from_tool(tool_call, current_idx)
                if sql:
                    process_parts.append(f"{step_num}. Generate SQL (using tool \"generate_sql\"):")
                    process_parts.append("   -- SQL: --")
                    # Format SQL for readability (indent each line)
                    sql_lines = sql.split("\n")
                    for line in sql_lines:
                        process_parts.append(f"   {line}")
                    step_num += 1
                elif success:
                    # SQL generation succeeded but SQL not extractable
                    process_parts.append(f"{step_num}. Generate SQL (using tool \"generate_sql\"): SQL generated successfully")
                    step_num += 1
                else:
                    # SQL generation failed
                    error = tool_output.get("error", "Unknown error") if isinstance(tool_output, dict) else "Unknown error"
                    process_parts.append(f"{step_num}. Generate SQL (using tool \"generate_sql\"): Failed - {error}")
                    step_num += 1
                    
            elif tool_name == "execute_sql":
                # Step: Execute SQL
                sql = extract_sql_from_tool(tool_call, current_idx)
                if sql:
                    process_parts.append(f"{step_num}. Execute SQL (using tool \"execute_sql\"):")
                    process_parts.append("   -- SQL: --")
                    # Format SQL for readability (indent each line)
                    sql_lines = sql.split("\n")
                    for line in sql_lines:
                        process_parts.append(f"   {line}")
                    
                    # Show execution results if available
                    if isinstance(tool_output, dict):
                        row_count = tool_output.get("row_count", 0)
                        if success and row_count is not None:
                            process_parts.append(f"   -- Result: Retrieved {row_count} row{'s' if row_count != 1 else ''}")
                        elif not success:
                            error = tool_output.get("error", "Unknown error")
                            process_parts.append(f"   -- Result: Failed - {error}")
                    step_num += 1
                elif success:
                    # SQL execution succeeded but SQL not extractable
                    row_count = tool_output.get("row_count", 0) if isinstance(tool_output, dict) else 0
                    process_parts.append(f"{step_num}. Execute SQL (using tool \"execute_sql\"): Executed successfully, retrieved {row_count} row{'s' if row_count != 1 else ''}")
                    step_num += 1
                else:
                    # SQL execution failed
                    error = tool_output.get("error", "Unknown error") if isinstance(tool_output, dict) else "Unknown error"
                    process_parts.append(f"{step_num}. Execute SQL (using tool \"execute_sql\"): Failed - {error}")
                    step_num += 1
                    
            elif tool_name == "semantic_search":
                # Step: Semantic Search
                query_text = tool_input.get("query_text") or tool_input.get("query") or tool_input.get("question", "")
                process_parts.append(f"{step_num}. Semantic Search (using tool \"semantic_search\"):")
                process_parts.append("   -- SQL Query: --")
                # Construct the SQL query template
                base_sql = (
                    "SELECT id, brand, fridge_model, price, sales_date, store_name, "
                    "customer_feedback, feedback_rating, feedback_sentiment_category "
                    "FROM fru_sales_embeddings "
                    "ORDER BY embedding <-> $query_vector::vector "
                    "LIMIT 50;"
                )
                process_parts.append(f"   {base_sql}")
                if query_text:
                    process_parts.append(f"   Search query: '{query_text}'")
                
                # Show search results if available
                if isinstance(tool_output, dict):
                    row_count = tool_output.get("row_count", 0)
                    if success and row_count is not None:
                        process_parts.append(f"   -- Result: Retrieved {row_count} row{'s' if row_count != 1 else ''}")
                    elif not success:
                        error = tool_output.get("error", "Unknown error")
                        process_parts.append(f"   -- Result: Failed - {error}")
                step_num += 1
        
        # Always end with LLM Analysis
        if step_num > 1:  # Only add if there were tool calls
            process_parts.append(f"{step_num}. LLM Analysis: Analyzed retrieved data using Claude to synthesize the final answer.")
        else:
            # No tool calls but agent was used
            process_parts.append(f"{step_num}. Agent-based processing: Used multiple tools to gather information.")
            step_num += 1
            process_parts.append(f"{step_num}. LLM Analysis: Analyzed retrieved data using Claude to synthesize the final answer.")
        
        return "\n".join(process_parts)
    
    else:
        # Simple processing mode (pgvector + LLM)
        process_parts = [
            "1. Semantic Search: Used pgvector to find semantically similar feedback records.",
            "   -- SQL Query: --",
            "   SELECT id, brand, fridge_model, price, sales_date, store_name,",
            "          customer_feedback, feedback_rating, feedback_sentiment_category",
            "   FROM fru_sales_embeddings",
            "   ORDER BY embedding <-> $query_vector::vector",
            "   LIMIT 50;",
            f"   Search query: '{question}'",
            "",
            "2. LLM Analysis: Analyzed the 50 most semantically similar feedback records using Claude.",
            "   The LLM filtered records with feedback_rating <= 3 and extracted the top 3 problems",
            "   mentioned in those low-rating customer feedbacks."
        ]
        return "\n".join(process_parts)


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
            expected_answer="Answer should mention 'average' and include a numeric rating (e.g., around 6.62 out of 10)",
        ),
        "BRD": QueryTestCase(
            name="Brand with highest average rating",
            query="Which brand has the highest average customer rating, and what is that average?",
            validator=_validate_brand_highest_avg,
            expected_answer="Answer should mention 'Samsung' as the brand with highest average rating around 9.0 out of 10",
        ),
        "CNT": QueryTestCase(
            name="Count negative feedbacks",
            query="How many negative feedbacks are there?",
            validator=_validate_count_negative,
            expected_answer="Answer should mention '50' negative feedbacks",
        ),
        "PCT": QueryTestCase(
            name="Percentage positive feedback",
            query="What percentage of feedback is positive?",
            validator=_validate_percentage_positive,
            expected_answer="Answer should mention around 50% positive feedback",
        ),
        "NOI": QueryTestCase(
            name="Negative feedback about noise",
            query="What do customers with negative feedback say about noise?",
            validator=_validate_noise_feedback,
            expected_answer="Answer should mention 'noise' and include phrases like 'constant humming noise', 'freight train', or 'very annoying'",
        ),
        "R07": QueryTestCase(
            name="Count feedbacks rating above 7",
            query="How many feedbacks have a rating above 7?",
            validator=_validate_count_above_seven,
            expected_answer="Answer should mention a count of feedbacks with rating above 7",
        ),
        "AVP": QueryTestCase(
            name="Average rating for positive feedbacks",
            query="What is the average rating for positive feedbacks?",
            validator=_validate_avg_positive,
            expected_answer="Answer should mention the average rating for positive feedbacks (typically around 8-9 out of 10)",
        ),
        "TMP": QueryTestCase(
            name="Negative feedback about temperature control",
            query="What do customers with negative feedback say about temperature control?",
            validator=_validate_temperature_feedback,
            expected_answer="Answer should mention 'temperature' and include phrases related to temperature control issues",
        ),
        "RDS": QueryTestCase(
            name="Rating distribution summary",
            query="Summarize how many feedbacks are Negative, Neutral, and Positive.",
            validator=_validate_rating_distribution,
            expected_answer="Answer should summarize the distribution of Negative, Neutral, and Positive feedbacks",
        ),
        "TOP": QueryTestCase(
            name="Top 3 problems for low-rating feedbacks",
            query="For the low rating customer feedbacks, what are the top 3 problems?",
            validator=_validate_top3_low_rating_problems,
            expected_answer="Answer should list the top 3 problems mentioned in low-rating customer feedbacks",
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
    
    # Capture response for error handling
    resp = None
    actual_response = None
    
    try:
        _print(f"Test {test_code}: {test_case.name}")
        _print(f"Query: {test_case.query}")
        
        # Apply timeout if specified (for systems without timeout command)
        if timeout is not None:
            import signal
            
            def timeout_handler(signum, frame):
                raise TimeoutError(f"Test exceeded timeout of {timeout} seconds")
            
            # Set up signal-based timeout (Unix only)
            old_handler = signal.signal(signal.SIGALRM, timeout_handler)
            signal.alarm(timeout)
            try:
                import time
                api_start = time.time()
                resp = run_query(test_case.query, base_url=base_url, timeout=timeout)
                api_time = time.time() - api_start
                actual_response = resp.get("answer", "")
                test_case.validator(resp)
            finally:
                signal.alarm(0)  # Cancel alarm
                signal.signal(signal.SIGALRM, old_handler)  # Restore handler
        else:
            import time
            api_start = time.time()
            resp = run_query(test_case.query, base_url=base_url)
            api_time = time.time() - api_start
            actual_response = resp.get("answer", "")
            test_case.validator(resp)
        
        # Time the extraction process
        extraction_start = time.time()
        deriving_process = _extract_deriving_process(resp, test_case.query)
        extraction_time = time.time() - extraction_start
        
        _print("Result: OK")
        # Format with separator lines instead of bold
        _print("----- Expected Answer: ----")
        _print(test_case.expected_answer)
        _print("----- Actual Answer: -------")
        _print(actual_response)
        
        # Log timing breakdown (if available)
        if 'api_time' in locals() and 'extraction_time' in locals():
            _print("----- Timing Breakdown: -----")
            _print(f"API Call Time: {api_time:.3f}s")
            _print(f"Result Extraction Time: {extraction_time:.3f}s")
            _print(f"Total Processing Time: {api_time + extraction_time:.3f}s")
        
        # Log deriving process
        if deriving_process:
            _print("----- Deriving Process: -----")
            _print(deriving_process)
        
        # Log token usage if available
        token_usage = resp.get("token_usage", {})
        if token_usage:
            input_tokens = token_usage.get("input_tokens", 0)
            output_tokens = token_usage.get("output_tokens", 0)
            total_tokens = token_usage.get("total_tokens", 0)
            if total_tokens > 0:
                _print("----- Token Usage: -------")
                _print(f"Input tokens: {input_tokens}")
                _print(f"Output tokens: {output_tokens}")
                _print(f"Total tokens: {total_tokens}")
        
        _print("----------------------------")
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
                _print("----- Expected Answer: ----")
                _print(expected)
            if actual_full:
                _print("----- Actual Answer: -------")
                _print(actual_full)
                # Extract deriving process if we have the response
                if resp:
                    deriving_process = _extract_deriving_process(resp, test_case.query)
                    if deriving_process:
                        _print("----- Deriving Process: -----")
                        _print(deriving_process)
                _print("----------------------------")
        else:
            # Fallback for other assertion errors
            _print(f"Error: {error_str}")
            if actual_response:
                _print("----- Expected Answer: ----")
                _print(test_case.expected_answer)
                _print("----- Actual Answer: -------")
                _print(actual_response)
                # Extract deriving process if we have the response
                if resp:
                    deriving_process = _extract_deriving_process(resp, test_case.query)
                    if deriving_process:
                        _print("----- Deriving Process: -----")
                        _print(deriving_process)
                _print("----------------------------")
        
        _print("=" * 80)
        raise
    except Exception as e:
        _print(f"Result: FAILED - {e}")
        if actual_response:
            _print("----- Expected Answer: ----")
            _print(test_case.expected_answer)
            _print("----- Actual Answer: -------")
            _print(actual_response)
            # Extract deriving process if we have the response
            if resp:
                deriving_process = _extract_deriving_process(resp, test_case.query)
                if deriving_process:
                    _print("----- Deriving Process: -----")
                    _print(deriving_process)
            _print("----------------------------")
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

