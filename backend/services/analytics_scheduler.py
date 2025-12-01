"""
Scheduler service to run Spark batch analytics periodically.
"""
import os
import subprocess
import logging
from apscheduler.schedulers.background import BackgroundScheduler
from apscheduler.triggers.interval import IntervalTrigger

logger = logging.getLogger(__name__)


def run_spark_analytics():
    """Execute Spark analytics job and save to PostgreSQL."""
    try:
        # Get paths from environment or use defaults
        repo_root = os.environ.get("REPO_ROOT", os.path.dirname(os.path.dirname(os.path.dirname(__file__))))
        delta_path = os.environ.get("DELTA_TABLE_PATH", "data/delta/fru_sales")
        spark_home = os.environ.get("SPARK_HOME", "")
        
        # Construct spark-submit command
        spark_submit = "spark-submit"
        if spark_home:
            spark_submit = os.path.join(spark_home, "bin", "spark-submit")
        
        script_path = os.path.join(repo_root, "spark_jobs", "run_analytics.py")
        output_dir = os.path.join(repo_root, "data", "analytics")
        
        # Check if Delta table exists
        delta_full_path = os.path.join(repo_root, delta_path)
        if not os.path.exists(delta_full_path):
            logger.warning(f"Delta table not found at {delta_full_path}, skipping analytics run")
            return
        
        # Run spark-submit
        cmd = [
            spark_submit,
            "--packages", "io.delta:delta-spark_2.12:3.2.0",
            script_path,
            delta_path,
            output_dir
        ]
        
        logger.info(f"Running Spark analytics: {' '.join(cmd)}")
        result = subprocess.run(
            cmd,
            cwd=repo_root,
            capture_output=True,
            text=True,
            timeout=300  # 5 minute timeout
        )
        
        if result.returncode == 0:
            logger.info("Spark analytics completed successfully")
        else:
            logger.error(f"Spark analytics failed: {result.stderr}")
            
    except subprocess.TimeoutExpired:
        logger.error("Spark analytics job timed out after 5 minutes")
    except Exception as e:
        logger.error(f"Error running Spark analytics: {e}", exc_info=True)


def start_analytics_scheduler(interval_minutes: int = 5):
    """
    Start the analytics scheduler.
    
    Args:
        interval_minutes: How often to run analytics (default: 5 minutes)
    """
    scheduler = BackgroundScheduler()
    scheduler.add_job(
        run_spark_analytics,
        trigger=IntervalTrigger(minutes=interval_minutes),
        id='batch_analytics',
        name='Run batch analytics',
        replace_existing=True
    )
    scheduler.start()
    logger.info(f"Analytics scheduler started (runs every {interval_minutes} minutes)")
    return scheduler

