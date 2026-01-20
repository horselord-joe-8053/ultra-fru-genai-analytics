# Flask Startup Diagnostic Plan

## Problem
Flask app crashes silently after "Starting Flask API server..." - no errors, no Flask logs, health probes fail.

## Root Cause Hypothesis
1. **Module import failure** - Python fails to import `backend.api.app` silently
2. **Database connection failure** - `init_db_pool()` raises exception that's caught but Flask exits
3. **Missing environment variable** - `get_required_env()` raises ValueError during module-level code
4. **Python path issue** - Module imports fail despite PYTHONPATH being set
5. **Silent exception in __main__** - Exception in `if __name__ == "__main__":` block not being logged

## Diagnostic Plan

### Phase 1: Enhanced Entrypoint Error Capture (IMMEDIATE)
**Goal**: Catch Python process exit and log error details

**Changes to `infra/docker/docker-entrypoint.sh`:**
1. Remove `set -e` temporarily (or wrap exec in error handling)
2. Wrap Python execution in error capture
3. Add pre-flight checks (Python path, module existence)
4. Log Python exit code and any stderr output

**Implementation:**
```bash
# Instead of: exec python -u -m backend.api.app 2>&1
# Use a wrapper that captures errors:
python -u -m backend.api.app 2>&1 || {
    exit_code=$?
    echo "[entrypoint] ERROR: Python process exited with code $exit_code" >&2
    exit $exit_code
}
```

### Phase 2: Add Detailed Logging to Flask Startup
**Goal**: Add logging at every critical step

**Changes to `backend/api/app.py`:**
1. Add logging BEFORE `if __name__ == "__main__":` block
2. Add try-catch around entire __main__ block
3. Add logging before/after each initialization step:
   - Before/after `init_db_pool()`
   - Before/after `init_agent()`
   - Before/after `app.run()`
4. Log Python version, sys.path, environment variables (sanitized)

**Implementation:**
```python
if __name__ == "__main__":
    import sys
    import traceback
    app.logger.info("=" * 60)
    app.logger.info("Flask startup initiated")
    app.logger.info(f"Python version: {sys.version}")
    app.logger.info(f"Python path: {sys.path[:3]}...")  # First 3 entries
    
    try:
        app.logger.info("Step 1: Initializing database pool...")
        init_db_pool()
        app.logger.info("Step 1: Database pool initialization complete")
        
        app.logger.info("Step 2: Initializing agent...")
        init_agent()
        app.logger.info("Step 2: Agent initialization complete")
        
        app.logger.info("Step 3: Starting Flask server...")
        app.logger.info("Starting FRU API server...")
        app.logger.info("Note: Analytics scheduler runs separately")
        app.run(host="0.0.0.0", port=5000)
    except Exception as e:
        app.logger.error(f"CRITICAL: Flask startup failed: {e}", exc_info=True)
        traceback.print_exc()
        sys.exit(1)
```

### Phase 3: Pre-flight Import Test
**Goal**: Test if module can be imported before running Flask

**Changes to `infra/docker/docker-entrypoint.sh`:**
Add import test before starting Flask:
```bash
echo "[entrypoint] Testing module import..."
python -u -c "
import sys
sys.path.insert(0, '/app')
try:
    print('[entrypoint] Testing: import backend.api.app')
    import backend.api.app
    print('[entrypoint] SUCCESS: Module import succeeded')
except Exception as e:
    print(f'[entrypoint] ERROR: Module import failed: {e}')
    import traceback
    traceback.print_exc()
    sys.exit(1)
" || {
    echo "[entrypoint] CRITICAL: Module import test failed"
    exit 1
}
```

### Phase 4: Test Database Connection Separately
**Goal**: Verify database connectivity before Flask startup

**Add to `backend/api/app.py` __main__ block:**
```python
# Test database connection
app.logger.info("Testing database connection...")
try:
    test_conn = get_db_conn()
    if test_conn:
        test_conn.close()
        app.logger.info("Database connection test: SUCCESS")
    else:
        app.logger.error("Database connection test: FAILED (None returned)")
except Exception as e:
    app.logger.error(f"Database connection test: FAILED - {e}", exc_info=True)
    # Continue anyway - Flask might still start
```

### Phase 5: Add Environment Variable Validation
**Goal**: Check all required env vars before startup

**Add to `backend/api/app.py` __main__ block:**
```python
import os
app.logger.info("Validating environment variables...")
required_vars = ['PGHOST', 'PGUSER', 'PGPASSWORD', 'PGDATABASE', 'ALLOWED_ORIGINS']
missing = [v for v in required_vars if not os.environ.get(v)]
if missing:
    app.logger.error(f"Missing required environment variables: {missing}")
    # Don't exit - let Flask try to start and fail gracefully
else:
    app.logger.info("Environment variables: OK")
```

### Phase 6: Enhanced Error Output in Entrypoint
**Goal**: Ensure all Python output (including uncaught exceptions) is visible

**Changes to `infra/docker/docker-entrypoint.sh`:**
```bash
# Don't use exec immediately - run and capture output
echo "[entrypoint] Starting Flask API server..."
echo "[entrypoint] Python path: $PYTHONPATH"
echo "[entrypoint] Working directory: $(pwd)"
echo "[entrypoint] Python executable: $(which python)"

# Run Python and capture exit code
python -u -m backend.api.app 2>&1
python_exit_code=$?

if [ $python_exit_code -ne 0 ]; then
    echo "[entrypoint] CRITICAL: Python process exited with code $python_exit_code" >&2
    echo "[entrypoint] Check logs above for error details" >&2
    exit $python_exit_code
fi
```

## Implementation Order

1. **Phase 1 + Phase 6** (Enhanced entrypoint) - IMMEDIATE
2. **Phase 2** (Detailed logging in app.py) - IMMEDIATE  
3. **Phase 3** (Import test) - If Phase 1/2 don't reveal issue
4. **Phase 4** (DB connection test) - If Phase 3 passes
5. **Phase 5** (Env var validation) - As part of Phase 2

## Expected Outcomes

After implementing:
- **If import fails**: We'll see "[entrypoint] ERROR: Module import failed" with traceback
- **If DB connection fails**: We'll see "Failed to create connection pool" with details
- **If env var missing**: We'll see "Missing required environment variables"
- **If exception in __main__**: We'll see "CRITICAL: Flask startup failed" with traceback
- **If Flask runs but crashes later**: We'll see Flask startup logs and then error

## Testing Strategy

1. Build new image with enhanced logging
2. Deploy to EKS
3. Check pod logs immediately after deployment
4. Look for new diagnostic messages
5. Identify exact failure point from logs
6. Fix root cause based on diagnostic output

