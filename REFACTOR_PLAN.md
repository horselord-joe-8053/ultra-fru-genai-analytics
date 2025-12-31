# Refactor Plan: Prevent Hallucination & Enhance Validation

## Problem Summary

1. **False Positive Test**: Test passed even though all SQL queries failed
2. **Hallucination**: LLM generated answer "Based on query results, the average feedback rating is 5.50" when no query succeeded
3. **Weak Validation**: Validator only checks for keywords, not data grounding
4. **Insufficient Anti-Hallucination**: Synthesis prompt doesn't strongly prevent guessing

## Refactor Plan

### Phase 1: Enhance Synthesis Prompt (Prevent Hallucination)

**File**: `backend/agents/prompts.py`

#### 1.1 Strengthen No-Data Case Handling

**Location**: `get_synthesis_prompt()` function (lines 182-185)

**Current**:
```python
else:
    sections.append(
        "Primary Result: NONE (no successful tool result with rows was found)."
    )
```

**Proposed**:
```python
else:
    sections.append("=" * 80)
    sections.append("⚠️⚠️⚠️ CRITICAL: NO DATA AVAILABLE - ABSOLUTE PROHIBITION ON GUESSING ⚠️⚠️⚠️")
    sections.append("=" * 80)
    sections.append("")
    sections.append("Primary Result: NONE")
    sections.append("")
    sections.append("ALL TOOL EXECUTIONS FAILED. No successful data retrieval occurred.")
    sections.append("ZERO rows were retrieved from the database.")
    sections.append("")
    sections.append("=" * 80)
    sections.append("MANDATORY RESPONSE (YOU MUST USE THIS EXACT OR EQUIVALENT LANGUAGE):")
    sections.append("=" * 80)
    sections.append('"I cannot answer this question because I was unable to retrieve the required data from the database.')
    sections.append('All attempts to query the database failed. Please try rephrasing your question or check if the data is available."')
    sections.append("")
    sections.append("=" * 80)
    sections.append("ABSOLUTE PROHIBITIONS - VIOLATING THESE IS A CRITICAL ERROR:")
    sections.append("=" * 80)
    sections.append("")
    sections.append("❌ DO NOT make up, invent, guess, estimate, approximate, or fabricate ANY numbers")
    sections.append("❌ DO NOT use phrases like:")
    sections.append("   - 'Based on query results'")
    sections.append("   - 'According to the data'")
    sections.append("   - 'The query results show'")
    sections.append("   - 'From the database'")
    sections.append("   - 'The data indicates'")
    sections.append("   - 'Based on the information'")
    sections.append("   - Any phrase that implies you have data")
    sections.append("")
    sections.append("❌ DO NOT provide ANY numeric values (ratings, counts, percentages, averages)")
    sections.append("❌ DO NOT provide ANY store names, brand names, or model names")
    sections.append("❌ DO NOT provide ANY analysis, insights, or conclusions")
    sections.append("❌ DO NOT use phrases like 'approximately', 'around', 'roughly', 'about'")
    sections.append("❌ DO NOT try to be helpful by providing a 'best guess'")
    sections.append("❌ DO NOT synthesize an answer from general knowledge")
    sections.append("")
    sections.append("✅ YOU MUST explicitly state that you cannot answer")
    sections.append("✅ YOU MUST explain that data retrieval failed")
    sections.append("✅ YOU MUST suggest rephrasing or checking data availability")
    sections.append("")
    sections.append("=" * 80)
    sections.append("REMEMBER: An honest 'I cannot answer' is ALWAYS better than a fabricated answer.")
    sections.append("Your credibility depends on NEVER guessing when you have no data.")
    sections.append("=" * 80)
```

#### 1.2 Add Stronger Anti-Hallucination Instructions

**Location**: `get_synthesis_prompt()` function (lines 196-235)

**Add after line 231**:
```python
    # CRITICAL: Anti-hallucination rules - ABSOLUTE PROHIBITIONS
    sections.append("")
    sections.append("=" * 80)
    sections.append("🚫 CRITICAL ANTI-HALLUCINATION RULES - ABSOLUTE PROHIBITIONS 🚫")
    sections.append("=" * 80)
    sections.append("")
    sections.append("These rules apply REGARDLESS of whether data is available:")
    sections.append("")
    sections.append("RULE 1: NEVER invent, guess, estimate, approximate, or fabricate:")
    sections.append("  - Numbers (ratings, counts, percentages, averages, sums)")
    sections.append("  - Names (stores, brands, models, customers)")
    sections.append("  - Facts, statistics, or any quantitative information")
    sections.append("  - Dates, prices, or any other data points")
    sections.append("")
    sections.append("RULE 2: NEVER use data-implying phrases UNLESS you have actual rows:")
    sections.append("  - 'Based on query results' → ONLY if rows exist above")
    sections.append("  - 'According to the data' → ONLY if rows exist above")
    sections.append("  - 'The query results show' → ONLY if rows exist above")
    sections.append("  - 'From the database' → ONLY if rows exist above")
    sections.append("  - 'The data indicates' → ONLY if rows exist above")
    sections.append("  - 'Based on the information' → ONLY if rows exist above")
    sections.append("")
    sections.append("RULE 3: If Primary Result is NONE (no rows above):")
    sections.append("  - You MUST explicitly state: 'I cannot answer...'")
    sections.append("  - You MUST explain: '...because I was unable to retrieve data'")
    sections.append("  - You MUST NOT provide any answer that implies you have data")
    sections.append("  - You MUST NOT try to be helpful by guessing")
    sections.append("")
    sections.append("RULE 4: Data Grounding Requirements:")
    sections.append("  - Every number in your answer MUST appear in the 'Rows' section above")
    sections.append("  - Every name in your answer MUST appear in the 'Rows' section above")
    sections.append("  - If calculating an average, the SQL result MUST show that average")
    sections.append("  - If counting items, the SQL result MUST show that count")
    sections.append("  - If no rows exist, you CANNOT provide any specific numbers or names")
    sections.append("")
    sections.append("RULE 5: Calculation Queries (AVG, SUM, COUNT, etc.):")
    sections.append("  - If SQL query failed → Say 'I cannot calculate...'")
    sections.append("  - If SQL returned 0 rows → Say 'No data available to calculate...'")
    sections.append("  - If SQL succeeded → Use the EXACT value from the row(s)")
    sections.append("  - NEVER calculate manually or estimate")
    sections.append("")
    sections.append("RULE 6: Qualitative Queries (feedback, complaints, themes):")
    sections.append("  - If semantic_search failed → Say 'I cannot answer...'")
    sections.append("  - If semantic_search returned 0 rows → Say 'No feedback found...'")
    sections.append("  - If semantic_search succeeded → Quote/paraphrase ONLY from rows above")
    sections.append("  - NEVER invent complaints or themes not in the rows")
    sections.append("")
    sections.append("RULE 7: Honesty Over Helpfulness:")
    sections.append("  - An honest 'I cannot answer' is ALWAYS better than a fabricated answer")
    sections.append("  - Your credibility depends on NEVER guessing when you have no data")
    sections.append("  - Users trust you to be accurate, not to be helpful with made-up data")
    sections.append("")
    sections.append("=" * 80)
    sections.append("VIOLATION CHECKLIST - Before submitting your answer, verify:")
    sections.append("=" * 80)
    sections.append("□ Did I check if Primary Result is NONE?")
    sections.append("□ If NONE, did I use the mandatory 'I cannot answer' language?")
    sections.append("□ Did I verify every number appears in the rows above?")
    sections.append("□ Did I verify every name appears in the rows above?")
    sections.append("□ Did I avoid ALL data-implying phrases if no rows exist?")
    sections.append("□ Did I avoid guessing, estimating, or approximating?")
    sections.append("□ Is my answer 100% grounded in the rows shown above?")
    sections.append("=" * 80)
```

#### 1.3 Enhance System Prompt with Anti-Hallucination Principles

**Location**: `get_agent_system_prompt()` function (around line 63)

**Add before the closing triple quotes**:
```python
    return f"""You are an intelligent analytics agent for fridge sales data.

[... existing content ...]

================================================================================
🚫 CRITICAL ANTI-HALLUCINATION PRINCIPLES - ABSOLUTE PROHIBITIONS 🚫
================================================================================

These principles apply to EVERY phase of your operation (planning, tool execution, synthesis):

PRINCIPLE 1: NEVER GUESS, ESTIMATE, APPROXIMATE, OR FABRICATE
  - NEVER invent numbers, names, facts, or any information
  - NEVER use phrases like "approximately", "around", "roughly", "about", "likely"
  - NEVER provide a "best guess" or "educated estimate"
  - NEVER synthesize an answer from general knowledge when you have no data
  - NEVER try to be helpful by making up information

PRINCIPLE 2: DATA GROUNDING IS MANDATORY
  - Every number in your answer MUST come from actual database query results
  - Every name (store, brand, model) MUST come from actual database query results
  - Every fact or statistic MUST come from actual database query results
  - If data is not in the query results, it CANNOT be in your answer

PRINCIPLE 3: HONESTY OVER HELPFULNESS
  - An honest "I cannot answer" is ALWAYS better than a fabricated answer
  - Your credibility depends on accuracy, not on being helpful with made-up data
  - Users trust you to be accurate - a wrong answer destroys that trust
  - A wrong answer is WORSE than no answer

PRINCIPLE 4: EXPLICIT FAILURE ACKNOWLEDGMENT
  - If tools fail, explicitly state: "I cannot answer because data retrieval failed"
  - If SQL fails, say: "I cannot calculate because the database query failed"
  - If semantic_search fails, say: "I cannot find feedback because the search failed"
  - Do NOT synthesize an answer from nothing when tools fail

PRINCIPLE 5: NO DATA-IMPLYING PHRASES WITHOUT DATA
  - NEVER use "Based on query results" unless you have actual rows
  - NEVER use "According to the data" unless you have actual rows
  - NEVER use "The query results show" unless you have actual rows
  - NEVER use "From the database" unless you have actual rows
  - If you have no data, use: "I cannot answer because I was unable to retrieve data"

REMEMBER: Your job is to provide ACCURATE answers based on REAL data, not to be helpful with made-up information.
================================================================================
"""
```

#### 1.4 Enhance Instructions for SQL Results

**Location**: `get_synthesis_prompt()` function (lines 203-212)

**Modify**:
```python
    if primary_sql_result:
        sections.append(
            "- State the numeric result or answer directly from the rows."
        )
        sections.append(
            "- The rows above contain the EXACT data from the database query."
        )
        sections.append(
            "- Extract the answer directly from the row values shown above."
        )
        sections.append(
            "- Do NOT invent new store names or numeric values that are not present in those rows."
        )
        sections.append(
            "- If row_count is 3, your answer should list exactly 3 stores with their sales values."
        )
        sections.append(
            "- If the SQL query returned an aggregate (like AVG), use that exact value from the rows."
        )
```

### Phase 2: Enhance Agent Logic (Fail Gracefully)

**File**: `backend/agents/query_agent.py`

#### 2.1 Add Data Availability Check Before Synthesis

**Location**: `process_query()` method (around line 365)

**Add after line 370**:
```python
                # Check if we have any successful data retrieval
                has_successful_data = (
                    (primary_sql_result and primary_sql_result.get("row_count", 0) > 0) or
                    (primary_semantic_result and primary_semantic_result.get("row_count", 0) > 0)
                )
                
                if not has_successful_data:
                    logger.warning(
                        "[SYNTHESIS] ⚠️ NO DATA RETRIEVED - All tool executions failed. "
                        "Cannot generate grounded answer."
                    )
                    # Still call synthesis but with explicit no-data flag
                    # The enhanced prompt will instruct LLM to say it cannot answer
```

#### 2.2 Add Metadata Flag for No-Data Cases

**Location**: `process_query()` method return statement (around line 459)

**Modify return**:
```python
            return {
                "answer": final_answer,
                "method": "agentic",
                "iterations": iteration,
                "tool_calls": logger.tool_calls,
                "execution_time_ms": execution_time,
                "debug_info": logger.get_debug_info(),
                "token_usage": {
                    "input_tokens": synthesis_tokens.get("input", 0),
                    "output_tokens": synthesis_tokens.get("output", 0),
                    "total_tokens": synthesis_tokens.get("total", 0)
                },
                # Add metadata about data availability
                "data_available": has_successful_data,  # NEW
                "primary_result_type": primary_result_type,  # NEW: "sql", "semantic", or None
                "primary_result_row_count": (
                    primary_sql_result.get("row_count", 0) if primary_sql_result
                    else (primary_semantic_result.get("row_count", 0) if primary_semantic_result else 0)
                )  # NEW
            }
```

### Phase 3: Enhance Validators (Check Data Grounding)

**File**: `test/python/common_test_queries_validators.py`

#### 3.1 Add Data Grounding Check Helper

**Add new function**:
```python
def _validate_data_grounding(resp: Dict, label: str) -> None:
    """
    Verify that the answer is grounded in actual data retrieval.
    
    Checks:
    - At least one tool call succeeded
    - If quantitative query, SQL must have succeeded with rows
    - If qualitative query, semantic_search must have succeeded with rows
    - Response metadata indicates data was available
    """
    tool_calls = resp.get("tool_calls", [])
    
    # Check if any tool call succeeded
    successful_tools = [
        tc for tc in tool_calls
        if tc.get("output", {}).get("success", False) and tc.get("output", {}).get("row_count", 0) > 0
    ]
    
    if not successful_tools:
        raise AssertionError(
            f"[{label}] No successful data retrieval. All tool calls failed or returned no rows. "
            f"Answer cannot be grounded in data. Tool calls: {len(tool_calls)} total, "
            f"{len(successful_tools)} successful with data."
        )
    
    # Check metadata if available (from enhanced agent response)
    data_available = resp.get("data_available")
    if data_available is False:
        raise AssertionError(
            f"[{label}] Response metadata indicates no data was available (data_available=false). "
            f"Answer is not grounded in actual data."
        )
    
    # Check for hallucination indicators in answer
    answer = str(resp.get("answer", "")).lower()
    hallucination_phrases = [
        "based on query results",
        "according to the data",
        "the query results show",
        "from the database",
    ]
    
    # If answer uses these phrases but no data was retrieved, it's likely hallucinated
    if not successful_tools and any(phrase in answer for phrase in hallucination_phrases):
        raise AssertionError(
            f"[{label}] Answer claims to be based on query results, but no queries succeeded. "
            f"This is likely a hallucination. Answer: {answer[:200]}"
        )
```

#### 3.2 Update All Validators to Use Data Grounding Check

**Modify each validator function** (e.g., `_validate_avg_feedback_rating`):

**Current**:
```python
def _validate_avg_feedback_rating(resp: Dict) -> None:
    label = "Average feedback rating"
    answer = _validate_has_answer_and_iterations(resp, label)
    # Fuzzy check: should mention "average" and a numeric rating.
    assert_contains(answer, "average", label)
    has_digit = any(ch.isdigit() for ch in answer)
    if not has_digit:
        raise AssertionError(f"[{label}] Expected a numeric rating in the answer.")
```

**Proposed**:
```python
def _validate_avg_feedback_rating(resp: Dict) -> None:
    label = "Average feedback rating"
    answer = _validate_has_answer_and_iterations(resp, label)
    
    # NEW: Check data grounding first
    _validate_data_grounding(resp, label)
    
    # Check that SQL succeeded (for quantitative queries)
    tool_calls = resp.get("tool_calls", [])
    sql_success = any(
        tc.get("tool") == "execute_sql" and 
        tc.get("output", {}).get("success", False) and
        tc.get("output", {}).get("row_count", 0) > 0
        for tc in tool_calls
    )
    
    if not sql_success:
        raise AssertionError(
            f"[{label}] No successful SQL execution found. "
            f"This is a quantitative query requiring SQL, but execute_sql failed or returned no rows."
        )
    
    # Fuzzy check: should mention "average" and a numeric rating.
    assert_contains(answer, "average", label)
    has_digit = any(ch.isdigit() for ch in answer)
    if not has_digit:
        raise AssertionError(f"[{label}] Expected a numeric rating in the answer.")
    
    # NEW: Check that answer doesn't claim data when none exists
    answer_lower = answer.lower()
    if "cannot" in answer_lower or "unable" in answer_lower or "no data" in answer_lower:
        # If answer says it cannot answer, that's acceptable if no data was retrieved
        # But we already checked data_available above, so this shouldn't happen
        pass
```

#### 3.3 Add Quantitative vs Qualitative Query Detection

**Add helper function**:
```python
def _is_quantitative_query(test_code: str) -> bool:
    """Determine if a test code requires quantitative (SQL) data retrieval."""
    quantitative_codes = ["AVG", "BRD", "CNT", "PCT", "R07", "AVP"]
    return test_code in quantitative_codes

def _is_qualitative_query(test_code: str) -> bool:
    """Determine if a test code requires qualitative (semantic search) data retrieval."""
    qualitative_codes = ["NOI", "TMP", "TOP"]
    return test_code in qualitative_codes
```

**Use in validators**:
```python
def _validate_avg_feedback_rating(resp: Dict) -> None:
    # ... existing code ...
    
    # For quantitative queries, require SQL success
    if _is_quantitative_query("AVG"):
        sql_success = any(
            tc.get("tool") == "execute_sql" and 
            tc.get("output", {}).get("success", False) and
            tc.get("output", {}).get("row_count", 0) > 0
            for tc in tool_calls
        )
        if not sql_success:
            raise AssertionError(...)
```

### Phase 4: Update Test Runner to Pass Test Code

**File**: `test/python/common_test_queries.py`

#### 4.1 Pass Test Code to Validators

**Modify `run_single_test()` function**:

**Current**:
```python
test_case.validator(resp)
```

**Proposed**:
```python
# Pass test code to validator if it accepts it
if hasattr(test_case.validator, '__code__'):
    import inspect
    sig = inspect.signature(test_case.validator)
    if 'test_code' in sig.parameters:
        test_case.validator(resp, test_code=test_code)
    else:
        test_case.validator(resp)
else:
    test_case.validator(resp)
```

**Update validator signatures**:
```python
def _validate_avg_feedback_rating(resp: Dict, test_code: str = None) -> None:
    # ... use test_code to determine if quantitative ...
```

### Phase 5: Add Response Validation in Agent

**File**: `backend/agents/query_agent.py`

#### 5.1 Validate Synthesis Response Before Returning

**Location**: After synthesis LLM call (around line 425)

**Add**:
```python
                # Validate synthesis response for hallucination indicators
                if not has_successful_data:
                    # Check if answer claims to have data when it doesn't
                    answer_lower = final_answer.lower()
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
                    
                    # Also check for numeric values (likely hallucinated if no data)
                    import re
                    has_numbers = bool(re.search(r'\d+\.?\d*', final_answer))
                    
                    # Check for specific numeric patterns that suggest calculations
                    has_calculated_values = bool(re.search(r'\d+\.\d+', final_answer))  # Decimals suggest calculations
                    
                    if (any(indicator in answer_lower for indicator in hallucination_indicators) or 
                        (has_numbers and has_calculated_values)):
                        logger.warning(
                            "[SYNTHESIS] ⚠️ LLM generated answer claims to have data or contains numbers when none exists. "
                            "This is a hallucination. Replacing with explicit no-data message."
                        )
                        logger.warning(
                            f"[SYNTHESIS] Original (hallucinated) answer: {final_answer[:200]}"
                        )
                        final_answer = (
                            "I cannot answer this question because I was unable to retrieve the required data from the database. "
                            "All attempts to query the database failed. Please try rephrasing your question or check if the data is available."
                        )
```

## Implementation Order

1. **Phase 1** (Synthesis Prompt) - Highest priority, prevents hallucination at source
2. **Phase 2** (Agent Logic) - Adds metadata for validation
3. **Phase 3** (Validators) - Catches issues in tests
4. **Phase 4** (Test Runner) - Enables test-code-aware validation
5. **Phase 5** (Response Validation) - Safety net in agent

## Testing Strategy

### Test Cases to Add/Update

1. **Test with all SQL failures**:
   - Should fail validation
   - Should return explicit "cannot answer" message

2. **Test with partial failures**:
   - Some tools succeed, some fail
   - Should pass if primary result has data

3. **Test with no rows returned**:
   - SQL succeeds but returns 0 rows
   - Should fail validation or return "no data" message

4. **Test hallucination detection**:
   - Mock response with "Based on query results" but no data
   - Should be caught by validator

## Files to Modify

1. `backend/agents/prompts.py` - Enhance synthesis prompt
2. `backend/agents/query_agent.py` - Add data availability checks and metadata
3. `test/python/common_test_queries_validators.py` - Add data grounding validation
4. `test/python/common_test_queries.py` - Pass test code to validators

## Expected Outcomes

1. ✅ **No more false positives**: Tests fail when data retrieval fails
2. ✅ **Zero hallucination**: 
   - LLM explicitly states it cannot answer when no data
   - Multiple layers prevent guessing (system prompt, synthesis prompt, post-validation)
   - Any attempt to guess is caught and replaced with explicit "cannot answer" message
3. ✅ **Better validation**: Validators check data grounding, not just keywords
4. ✅ **Clearer errors**: Test failures explain why (no data retrieved)
5. ✅ **Metadata tracking**: Response includes data availability flags
6. ✅ **Explicit prohibitions**: 
   - System prompt reinforces anti-hallucination at agent level
   - Synthesis prompt has explicit "DO NOT" list with examples
   - Post-synthesis validation catches any remaining attempts to guess

## Rollback Plan

If issues arise:
1. Keep old validator logic as fallback
2. Make new validation optional via flag
3. Gradual rollout: validate → warn → fail

