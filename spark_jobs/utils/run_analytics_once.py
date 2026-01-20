"""
Standalone entry point to run Spark analytics once.
Extracted from scheduler.py for reuse in trigger scripts.

Usage:
    python /app/spark_jobs/utils/run_analytics_once.py
    # Or: python -m spark_jobs.utils.run_analytics_once

Environment Variables:
    DELTA_TABLE_PATH - Path to Delta table (default: data/delta/fru_sales)
    REPO_ROOT - Repository root (auto-detected if not set)
    SPARK_HOME - Spark installation path (default: /opt/spark)
    CONTAINER_TYPE - Container type (ecs, eks, or empty for local)
    DELTA_LAKE_PACKAGE - Delta Lake Maven package (required)
    PGHOST, PGPORT, PGUSER, PGPASSWORD, PGDATABASE - Database config (required)
"""
import os
import sys

# Add /app to Python path if not already present (needed for imports when run directly)
# This file is at /app/spark_jobs/utils/run_analytics_once.py
# So we need /app in the path to import spark_jobs
script_dir = os.path.dirname(os.path.abspath(__file__))
app_dir = os.path.dirname(os.path.dirname(script_dir))  # /app/spark_jobs/utils -> /app
if app_dir not in sys.path:
    sys.path.insert(0, app_dir)

import logging
from spark_jobs.scheduler import run_spark_analytics

# Setup logging for standalone execution
logging.basicConfig(
    level=os.getenv("LOG_LEVEL", "INFO").upper(),
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

if __name__ == "__main__":
    try:
        logger.info("Running Spark analytics (standalone execution)...")
        run_spark_analytics()
        logger.info("Spark analytics execution completed")
        sys.exit(0)
    except Exception as e:
        logger.error(f"Failed to run Spark analytics: {e}", exc_info=True)
        sys.exit(1)

