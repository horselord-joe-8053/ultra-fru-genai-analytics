# Issue Analysis and Execution Plan

## Issue 1: Why is `feedback_rating` TEXT in database when it should be INTEGER?

### Root Cause Analysis

**Current State:**
- ✅ CSV file (`data/raw/fridge_sales_with_rating.csv`): Contains numeric values (10, 5, 8, 4, etc.)
- ✅ Schema definition (`sql/schema_pgvector.sql`): Defines `feedback_rating INTEGER` (line 14)
- ✅ Schema migration (`sql/schema_pgvector.sql` lines 55-68): Attempts to convert TEXT → INTEGER
- ✅ Agent schema info (`backend/agents/query_agent.py` line 53): Correctly states `"feedback_rating": "INTEGER"`
- ✅ Agent prompts (`backend/agents/prompts.py` lines 57-58): Correctly states INTEGER
- ❌ **Actual database**: Column is `TEXT` (verified via `docker exec fru_db psql`)

**Why the migration didn't work:**
1. The migration script (`sql/schema_pgvector.sql` lines 55-68) only runs if:
   - Column exists AND
   - Column type is TEXT
2. **Problem**: If the table was created AFTER the migration script was written, the column might have been created as TEXT initially, but the migration might not have run, OR the migration ran but failed silently.

**ETL Process Analysis:**
- `backend/etl/load_openai_embeddings_to_pgvector.py` line 61: Converts to `int()` before inserting
- However, if the database column is TEXT, PostgreSQL will accept the integer value as a string
- The INSERT statement doesn't explicitly cast, so it relies on PostgreSQL's type coercion

**1.1 CSV Delimiting:**
- CSV file uses commas correctly (verified: line 2 shows proper comma separation)
- ETL script uses `pd.read_csv()` which handles commas correctly
- **Not a CSV parsing issue**

**1.2 ETL Step in Local Test:**
- Local test does NOT automatically run ETL
- ETL must be run manually: `./run_scripts/local/load-data.sh`
- The test assumes data is already loaded
- **The ETL step would show up if it ran, but it doesn't run automatically**

### Execution Plan for Issue 1

**Step 1: Verify current database state**
```bash
docker exec fru_db psql -U postgres -d fru_db -c "\d fru_sales_embeddings" | grep feedback_rating
```

**Step 2: Check if migration ran**
```bash
# Check if migration was applied
docker exec fru_db psql -U postgres -d fru_db -c "
SELECT column_name, data_type 
FROM information_schema.columns 
WHERE table_name = 'fru_sales_embeddings' 
AND column_name = 'feedback_rating';
"
```

**Step 3: Fix the database schema**
```sql
-- Option A: Direct fix (if data is numeric strings)
ALTER TABLE fru_sales_embeddings 
ALTER COLUMN feedback_rating TYPE INTEGER 
USING feedback_rating::INTEGER;

-- Option B: If some values are non-numeric, clean first
UPDATE fru_sales_embeddings 
SET feedback_rating = NULL 
WHERE feedback_rating !~ '^[0-9]+$';

ALTER TABLE fru_sales_embeddings 
ALTER COLUMN feedback_rating TYPE INTEGER 
USING feedback_rating::INTEGER;
```

**Step 4: Verify fix**
```bash
docker exec fru_db psql -U postgres -d fru_db -c "\d fru_sales_embeddings" | grep feedback_rating
```

**Step 5: Re-run ETL (if needed)**
- If data was corrupted, reload: `./run_scripts/local/load-data.sh`

**Step 6: Update migration script to be more robust**
- Add explicit type casting in CREATE TABLE
- Ensure migration runs on every init

---

## Issue 2: Why did test PASS when SQL execution failed?

### Root Cause Analysis

**Test Log Analysis:**
- Line 16: Actual Answer shows: "The average feedback rating is 5.50."
- All SQL executions failed (iterations 1-6)
- Test result: **PASSED**

**Why it passed:**

1. **Agent's Final Answer:**
   - The agent provided: "The average feedback rating is 5.50."
   - This is a **hallucinated answer** (no data was retrieved)
   - The answer also contains tool-calling format: `<generate_sql>...` and `<execute_sql>...`
   - This indicates the agent didn't properly synthesize the final answer

2. **Validator Logic Analysis:**
   - `_validate_has_answer_and_iterations()` (lines 33-41 in validators.py) checks:
     ```python
     if data_available is not None:
         if not data_available:
             raise AssertionError(...)
     ```
   - **Problem**: If `data_available` is `None` (not set), the check is bypassed
   - **Hypothesis**: The API response might have `data_available: None` instead of `data_available: False`

3. **Numeric Hallucination Check:**
   - Lines 70-74 check for numeric values when `data_available is False
   - But this only runs if `data_available is False` (line 44)
   - If `data_available` is `None`, this check is skipped

4. **Additional Validator Check:**
   - `_validate_avg_feedback_rating()` (lines 88-99) checks:
     - `primary_result_type != "sql"` OR `primary_result_row_count == 0`
     - If true, checks for data-implying phrases
   - **BUT**: The answer "The average feedback rating is 5.50." doesn't match those phrases
   - **Missing**: Check for numeric values when SQL failed, regardless of data_available value

### Execution Plan for Issue 2

**Step 1: Check what `data_available` value was returned**
- Add logging to see the actual API response JSON
- Check if `data_available` is being set correctly in `query_agent.py`
- Verify: Is it `None`, `False`, or `True`?

**Step 2: Fix `_validate_has_answer_and_iterations()` to handle `None`**
- Change check to treat `None` as `False`:
  ```python
  data_available = resp.get("data_available")
  if data_available is None or data_available is False:
      # Treat None as False (no data available)
      if has_numeric_values(answer):
          raise AssertionError(...)
  ```

**Step 3: Fix `_validate_avg_feedback_rating()` to catch numeric hallucinations**
- Add check for numeric values when SQL failed, regardless of data_available:
  ```python
  if primary_result_type != "sql" or primary_result_row_count == 0:
      # Check for numeric values (hallucination if no data)
      import re
      if re.search(r'\d+\.?\d+', answer):  # Matches "5.50"
          raise AssertionError(
              f"[{label}] CRITICAL: Answer contains numeric values but SQL execution failed. "
              f"primary_result_type={primary_result_type}, row_count={primary_result_row_count}. "
              f"This is a hallucination. Answer: {answer[:300]}"
          )
  ```

**Step 4: Add check for tool-calling format in final answer**
- If answer contains `<generate_sql>` or `<execute_sql>`, it's not properly synthesized
- This should also fail validation

**Step 5: Verify fix**
- Re-run test and ensure it fails when SQL execution fails
- Test with `data_available: None`, `False`, and `True` cases

---

## Issue 3: Why did it run 6 iterations when MAX_ITERATIONS = 5?

### Root Cause Analysis

**Code Analysis:**
- `backend/agents/query_agent.py` line 22: `MAX_ITERATIONS = 5`
- Line 155: `while iteration < self.MAX_ITERATIONS:`
- Line 156: `iteration += 1`
- Line 157: `logger.log_iteration(iteration)`

**Test Log Analysis:**
- Shows: "Iteration 1", "Iteration 2", ..., "Iteration 6"
- Total: 6 iterations

**Why 6 iterations?**

**Hypothesis 1: Off-by-one error**
- If `iteration` starts at 0 and increments at the start of loop:
  - Iteration 0 → becomes 1 (first iteration)
  - Iteration 1 → becomes 2 (second iteration)
  - ...
  - Iteration 4 → becomes 5 (fifth iteration)
  - Iteration 5 → becomes 6 (sixth iteration) ← **This should not happen!**

**Hypothesis 2: Loop condition issue**
- `while iteration < self.MAX_ITERATIONS:` means `while iteration < 5:`
- If `iteration` starts at 0:
  - iteration=0: 0 < 5 → true, increment to 1
  - iteration=1: 1 < 5 → true, increment to 2
  - iteration=2: 2 < 5 → true, increment to 3
  - iteration=3: 3 < 5 → true, increment to 4
  - iteration=4: 4 < 5 → true, increment to 5
  - iteration=5: 5 < 5 → false, exit
  - **Should only run 5 times (iterations 1-5)**

**Actual Code:**
- Line 147: `iteration = 0`
- Line 155: `while iteration < self.MAX_ITERATIONS:` (while iteration < 5)
- Line 156: `iteration += 1` (increments FIRST, then executes)

**Expected Behavior:**
- iteration=0: 0 < 5 → true, increment to 1, execute iteration 1
- iteration=1: 1 < 5 → true, increment to 2, execute iteration 2
- iteration=2: 2 < 5 → true, increment to 3, execute iteration 3
- iteration=3: 3 < 5 → true, increment to 4, execute iteration 4
- iteration=4: 4 < 5 → true, increment to 5, execute iteration 5
- iteration=5: 5 < 5 → **false, should exit**
- **Should only run 5 iterations (1-5)**

**Actual Behavior:**
- Test log shows 6 iterations (Iteration 1 through Iteration 6)

**Possible Causes:**
1. **Synthesis phase counted as iteration**: The log shows "Step 14. LLM Analysis" after iteration 6
   - Need to check if synthesis phase increments iteration counter
   - Synthesis happens AFTER the while loop, so it shouldn't increment iteration

2. **Early break logic issue**: Lines 283-294 have early break logic
   - If early break doesn't work correctly, loop might continue
   - Need to verify early break conditions

3. **Off-by-one in logging**: The logger might be counting differently
   - `logger.log_iteration(iteration)` is called after increment
   - Need to check if logger adds an extra iteration

4. **Exception handling**: If an exception occurs, iteration might not be decremented
   - But exceptions should exit the loop, not continue

### Execution Plan for Issue 3

**Step 1: Trace iteration counting**
- Add detailed logging to see exactly when `iteration` is incremented
- Check if synthesis phase increments iteration

**Step 2: Fix iteration counting**
- Ensure `MAX_ITERATIONS = 5` means exactly 5 iterations (1-5)
- If synthesis is counted separately, exclude it from iteration count
- Or change condition to `iteration <= self.MAX_ITERATIONS` and start at 1

**Step 3: Verify fix**
- Run test and verify exactly 5 iterations (or 5 + synthesis)

**Recommended Fix:**
```python
# Option A: Start at 1, use <=
iteration = 1
while iteration <= self.MAX_ITERATIONS:
    logger.log_iteration(iteration)
    # ... do work ...
    iteration += 1

# Option B: Start at 0, but check before increment
iteration = 0
while iteration < self.MAX_ITERATIONS:
    iteration += 1
    logger.log_iteration(iteration)
    # ... do work ...
    # Ensure no other code path increments iteration
```

---

## Summary of Issues

| Issue | Severity | Root Cause | Fix Priority |
|-------|----------|------------|-------------|
| 1. feedback_rating is TEXT | 🔴 Critical | Migration didn't run or failed | **P0** - Blocks all AVG queries |
| 2. Test passed when SQL failed | 🔴 Critical | Validator doesn't check for numeric hallucinations | **P0** - False positives |
| 3. 6 iterations instead of 5 | 🟡 Medium | Off-by-one or synthesis counting | **P1** - Performance/waste |

## Recommended Execution Order

1. **Fix Issue 1 first** (database schema) - This will fix the SQL errors
2. **Fix Issue 2** (validator) - This will catch hallucinations properly
3. **Fix Issue 3** (iteration count) - This is less critical but should be fixed

## Testing Plan

After fixes:
1. Fix database schema → Re-run test → Should see SQL succeed
2. If SQL still fails, validator should catch it → Test should FAIL
3. Verify iteration count is exactly 5 (or 5 + synthesis)

