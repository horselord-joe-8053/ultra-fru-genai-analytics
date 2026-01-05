"""
Scheduler service to run Spark batch analytics periodically.

Applicable environment: [local] [aws {ecs | eks}] [azure {aci | aks}] [gcp {cloud-run | gke}]
"""
import os
import subprocess
import logging
from apscheduler.schedulers.background import BackgroundScheduler
from apscheduler.triggers.interval import IntervalTrigger
from backend.utils.env_helpers import get_optional_env
from backend.utils.filesystem import exists

logger = logging.getLogger(__name__)


def run_spark_analytics():
    """Execute Spark analytics job and save to PostgreSQL."""
    try:
        # Get paths from environment or use defaults
        repo_root = get_optional_env("REPO_ROOT", os.path.dirname(os.path.dirname(os.path.dirname(__file__))))
        delta_path = get_optional_env("DELTA_TABLE_PATH", "data/delta/fru_sales")
        
        # Spark is installed in the same container (no docker exec needed)
        spark_home = get_optional_env("SPARK_HOME", "/opt/spark")
        spark_submit = os.path.join(spark_home, "bin", "spark-submit")
        
        script_path = os.path.join(repo_root, "spark_jobs", "run_analytics.py")
        output_dir = os.path.join(repo_root, "data", "analytics")
        
        # Check if Delta table exists (works for S3, local, EFS)
        # If delta_path is absolute (starts with s3:// or /), use as-is
        # Otherwise, join with repo_root
        if delta_path.startswith('s3://') or delta_path.startswith('/'):
            delta_full_path = delta_path
        else:
            delta_full_path = os.path.join(repo_root, delta_path)
        
        if not exists(delta_full_path):
            logger.warning(f"Delta table not found at {delta_full_path}, skipping analytics run")
            return
        
        # Configure Spark to use the API's Python (which has psycopg2)
        import sys
        api_python = sys.executable
        env = os.environ.copy()
        env["PYSPARK_PYTHON"] = api_python
        env["PYSPARK_DRIVER_PYTHON"] = api_python
        
        # Set JAVA_HOME dynamically (works for both arm64 and amd64)
        if "JAVA_HOME" not in env:
            import glob
            java_dirs = glob.glob("/usr/lib/jvm/java-21-openjdk-*")
            if java_dirs:
                env["JAVA_HOME"] = java_dirs[0]
                logger.info(f"Set JAVA_HOME to {env['JAVA_HOME']}")
        
        # Ensure database environment variables are available
        db_env_vars = ["PGHOST", "PGPORT", "PGUSER", "PGPASSWORD", "PGDATABASE"]
        for var in db_env_vars:
            if var not in env:
                value = get_optional_env(var, None)
                if value:
                    env[var] = value
        
        logger.info(f"Using Python: {api_python} (for psycopg2 support)")
        
        # Require Delta Lake package from environment (.env is source of truth, no defaults)
        delta_lake_package = os.environ.get("DELTA_LAKE_PACKAGE")
        if not delta_lake_package:
            logger.error("DELTA_LAKE_PACKAGE is not set in environment")
            logger.error("Please add DELTA_LAKE_PACKAGE to your .env file")
            logger.info("Standard combination: io.delta:delta-spark_2.13:4.0.0 (Spark 4.0.1 + Delta Lake 4.0.0 + Scala 2.13)")
            logger.info("Example .env entry: DELTA_LAKE_PACKAGE=io.delta:delta-spark_2.13:4.0.0")
            raise ValueError("DELTA_LAKE_PACKAGE must be set in .env file")
        
        logger.info(f"Using Delta Lake package: {delta_lake_package}")
        
        cmd = [
            spark_submit,
            "--packages", delta_lake_package,
            script_path,
            delta_path,
            output_dir
        ]
        
        logger.info(f"Running Spark analytics: {' '.join(cmd)}")
        result = subprocess.run(
            cmd,
            cwd=repo_root,
            env=env,
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
    except FileNotFoundError:
        logger.error("spark-submit command not found. Is Spark installed and SPARK_HOME set correctly?")
    except Exception as e:
        logger.error(f"Error running Spark analytics: {e}", exc_info=True)


def start_analytics_scheduler(interval_seconds: int):
    """
    Start the analytics scheduler.
    
    Args:
        interval_seconds: How often to run analytics in seconds (required, no default)
    """
    scheduler = BackgroundScheduler()
    scheduler.add_job(
        run_spark_analytics,
        trigger=IntervalTrigger(seconds=interval_seconds),
        id='batch_analytics',
        name='Run batch analytics',
        replace_existing=True
    )
    scheduler.start()
    logger.info(f"Analytics scheduler started (runs every {interval_seconds} seconds)")
    return scheduler

