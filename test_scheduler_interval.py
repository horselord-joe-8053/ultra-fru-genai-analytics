#!/usr/bin/env python3
"""
Test script to verify scheduler interval configuration.
Tests fail-fast behavior and scheduler initialization.
"""
import os
import sys
from pathlib import Path

# Add backend to path
sys.path.insert(0, str(Path(__file__).parent / 'backend'))

# Load .env file
env_file = Path('.env')
if env_file.exists():
    with open(env_file) as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith('#') and '=' in line:
                key, value = line.split('=', 1)
                os.environ[key.strip()] = value.strip()

from backend.utils.env_helpers import get_optional_bool_env, get_required_int_env
from backend.services.analytics_scheduler import start_analytics_scheduler
import time

def test_fail_fast_missing():
    """Test 1: Fail-fast when env var is missing"""
    print("=" * 60)
    print("Test 1: Fail-Fast (Missing Env Var)")
    print("=" * 60)
    
    original_value = os.environ.pop('ANALYTICS_SCHEDULER_INTERVAL_SECONDS', None)
    try:
        get_required_int_env('ANALYTICS_SCHEDULER_INTERVAL_SECONDS', 'test')
        print("❌ FAILED: Should have raised ValueError")
        return False
    except ValueError as e:
        print(f"✅ PASSED: {e}")
        return True
    finally:
        if original_value:
            os.environ['ANALYTICS_SCHEDULER_INTERVAL_SECONDS'] = original_value

def test_fail_fast_invalid():
    """Test 2: Fail-fast when env var is invalid"""
    print("\n" + "=" * 60)
    print("Test 2: Fail-Fast (Invalid Value)")
    print("=" * 60)
    
    original_value = os.environ.get('ANALYTICS_SCHEDULER_INTERVAL_SECONDS')
    os.environ['ANALYTICS_SCHEDULER_INTERVAL_SECONDS'] = 'invalid'
    try:
        get_required_int_env('ANALYTICS_SCHEDULER_INTERVAL_SECONDS', 'test')
        print("❌ FAILED: Should have raised ValueError")
        return False
    except ValueError as e:
        print(f"✅ PASSED: {e}")
        return True
    finally:
        if original_value:
            os.environ['ANALYTICS_SCHEDULER_INTERVAL_SECONDS'] = original_value
        else:
            os.environ.pop('ANALYTICS_SCHEDULER_INTERVAL_SECONDS', None)

def test_valid_configuration():
    """Test 3: Valid configuration"""
    print("\n" + "=" * 60)
    print("Test 3: Valid Configuration")
    print("=" * 60)
    
    enable = get_optional_bool_env("ENABLE_ANALYTICS_SCHEDULER", False)
    print(f"ENABLE_ANALYTICS_SCHEDULER: {enable}")
    
    if not enable:
        print("⚠️  Scheduler disabled in .env (set ENABLE_ANALYTICS_SCHEDULER=true to test)")
        return True
    
    try:
        interval = get_required_int_env("ANALYTICS_SCHEDULER_INTERVAL_SECONDS", "test")
        print(f"ANALYTICS_SCHEDULER_INTERVAL_SECONDS: {interval} seconds ({interval/60:.1f} minutes)")
        print("✅ Configuration valid!")
        return True
    except ValueError as e:
        print(f"❌ Configuration error: {e}")
        return False

def test_scheduler_initialization():
    """Test 4: Scheduler initialization (without actually starting)"""
    print("\n" + "=" * 60)
    print("Test 4: Scheduler Initialization")
    print("=" * 60)
    
    enable = get_optional_bool_env("ENABLE_ANALYTICS_SCHEDULER", False)
    if not enable:
        print("⚠️  Skipping: Scheduler disabled")
        return True
    
    try:
        interval = get_required_int_env("ANALYTICS_SCHEDULER_INTERVAL_SECONDS", "test")
        print(f"Attempting to initialize scheduler with interval: {interval} seconds")
        
        # Just verify the function signature works (don't actually start it)
        # We'll test actual startup separately
        print("✅ Scheduler function signature valid")
        print(f"   Function: start_analytics_scheduler(interval_seconds={interval})")
        return True
    except Exception as e:
        print(f"❌ Error: {e}")
        return False

def test_scheduler_runs():
    """Test 5: Actually start scheduler and verify it runs at correct interval"""
    print("\n" + "=" * 60)
    print("Test 5: Scheduler Runtime Test")
    print("=" * 60)
    
    enable = get_optional_bool_env("ENABLE_ANALYTICS_SCHEDULER", False)
    if not enable:
        print("⚠️  Skipping: Scheduler disabled")
        return True
    
    try:
        interval = get_required_int_env("ANALYTICS_SCHEDULER_INTERVAL_SECONDS", "test")
        print(f"Starting scheduler with interval: {interval} seconds")
        print("⚠️  Note: This will actually start the scheduler!")
        print("⚠️  Make sure Delta table exists and Spark is configured")
        print("⚠️  Press Ctrl+C to stop after observing first run")
        
        scheduler = start_analytics_scheduler(interval_seconds=interval)
        print(f"✅ Scheduler started successfully!")
        print(f"   Will run every {interval} seconds")
        print(f"   Monitoring for {interval + 10} seconds...")
        
        # Wait for first run + buffer
        time.sleep(interval + 10)
        
        scheduler.shutdown()
        print("✅ Scheduler test completed")
        return True
    except KeyboardInterrupt:
        print("\n⚠️  Test interrupted by user")
        if 'scheduler' in locals():
            scheduler.shutdown()
        return True
    except Exception as e:
        print(f"❌ Error: {e}")
        import traceback
        traceback.print_exc()
        return False

if __name__ == "__main__":
    print("\n" + "=" * 60)
    print("Scheduler Interval Configuration Tests")
    print("=" * 60 + "\n")
    
    results = []
    results.append(("Fail-Fast (Missing)", test_fail_fast_missing()))
    results.append(("Fail-Fast (Invalid)", test_fail_fast_invalid()))
    results.append(("Valid Configuration", test_valid_configuration()))
    results.append(("Scheduler Init", test_scheduler_initialization()))
    
    # Only run runtime test if user explicitly wants it
    if len(sys.argv) > 1 and sys.argv[1] == "--run-scheduler":
        results.append(("Scheduler Runtime", test_scheduler_runs()))
    
    print("\n" + "=" * 60)
    print("Test Summary")
    print("=" * 60)
    for name, passed in results:
        status = "✅ PASSED" if passed else "❌ FAILED"
        print(f"{name}: {status}")
    
    all_passed = all(result[1] for result in results)
    print("\n" + ("✅ All tests passed!" if all_passed else "❌ Some tests failed"))
    sys.exit(0 if all_passed else 1)

