"""
Standalone entry point for Spark analytics scheduler.
Runs scheduler as separate process (not integrated with Flask app).

Usage:
    python -m spark_jobs.run_scheduler
    # Or: python spark_jobs/run_scheduler.py
    
Environment Variables:
    ENABLE_ANALYTICS_SCHEDULER - Must be "true" to start scheduler
    ANALYTICS_SCHEDULER_INTERVAL_SECONDS - How often to run analytics
    DELTA_TABLE_PATH - Path to Delta table (default: data/delta/fru_sales)
    SPARK_HOME - Spark installation path (default: /opt/spark)
"""
import os
import sys
import logging
from spark_jobs.scheduler import start_analytics_scheduler
from backend.utils.env_helpers import get_optional_bool_env, get_required_int_env

logging.basicConfig(
    level=os.getenv("LOG_LEVEL", "INFO").upper(),
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

if __name__ == "__main__":
    enable_scheduler = get_optional_bool_env("ENABLE_ANALYTICS_SCHEDULER", False)
    
    if not enable_scheduler:
        logger.info("Analytics scheduler disabled. Set ENABLE_ANALYTICS_SCHEDULER=true to enable.")
        sys.exit(0)
    
    try:
        scheduler_interval_seconds = get_required_int_env(
            "ANALYTICS_SCHEDULER_INTERVAL_SECONDS",
            "Analytics scheduler interval in seconds (required when ENABLE_ANALYTICS_SCHEDULER=true)"
        )
        scheduler = start_analytics_scheduler(interval_seconds=scheduler_interval_seconds)
        logger.info(f"Analytics scheduler started (runs every {scheduler_interval_seconds} seconds)")
        
        # Keep process alive
        import time
        try:
            while True:
                time.sleep(60)
        except KeyboardInterrupt:
            logger.info("Stopping scheduler...")
            scheduler.shutdown()
    except Exception as e:
        logger.error(f"Failed to start analytics scheduler: {e}", exc_info=True)
        sys.exit(1)

