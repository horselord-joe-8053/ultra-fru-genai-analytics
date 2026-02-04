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
from spark_jobs.utils.verify_delta_table import verify_delta_table_exists
from spark_jobs.utils.spark_config import get_s3a_spark_config, get_spark_packages

logger = logging.getLogger(__name__)


def run_spark_analytics():
    """Execute Spark analytics job and save to PostgreSQL."""
    try:
        # Get paths from environment or use defaults
        # In Docker container, __file__ is at /app/spark_jobs/scheduler.py
        # So repo_root should be /app (one level up from spark_jobs/)
        repo_root = get_optional_env("REPO_ROOT", os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
        delta_path = get_optional_env("DELTA_TABLE_PATH", "data/delta/fru_sales")
        
        # Spark is installed in the same container (no docker exec needed)
        spark_home = get_optional_env("SPARK_HOME", "/opt/spark")
        spark_submit = os.path.join(spark_home, "bin", "spark-submit")
        
        # Ensure spark-submit exists
        if not os.path.exists(spark_submit):
            error_msg = f"spark-submit not found at {spark_submit}. SPARK_HOME={spark_home}. Is Spark installed?"
            logger.error(error_msg)
            raise FileNotFoundError(error_msg)
        
        script_path = os.path.join(repo_root, "spark_jobs", "run_analytics.py")
        output_dir = os.path.join(repo_root, "data", "analytics")
        
        # Detect container type from environment (set by Terraform for AWS)
        # Local deployments don't set CONTAINER_TYPE, so it will be empty
        container_type = os.environ.get("CONTAINER_TYPE", "").lower()
        is_ecs_deployment = "ecs" in container_type
        is_eks_deployment = "eks" in container_type
        is_aws_deployment = is_ecs_deployment or is_eks_deployment
        
        # Detect if path is S3-based (AWS deployments use S3)
        is_s3_based = delta_path.startswith('s3://') or delta_path.startswith('s3a://')
        
        # Validate: AWS deployments (ECS/EKS) need S3 path; non-AWS need local path
        if is_aws_deployment != is_s3_based:
            if is_aws_deployment and not is_s3_based:
                error_msg = (
                    f"Configuration mismatch: CONTAINER_TYPE={container_type} indicates AWS deployment, "
                    f"but DELTA_TABLE_PATH={delta_path} is not an S3 path (should start with s3:// or s3a://). "
                    f"Please ensure DELTA_TABLE_PATH is set to an S3 path for ECS/EKS deployments."
                )
            elif not is_aws_deployment and is_s3_based:
                error_msg = (
                    f"Configuration mismatch: DELTA_TABLE_PATH={delta_path} is an S3 path, "
                    f"but CONTAINER_TYPE={container_type or '(not set)'} does not indicate ECS/EKS. "
                    f"For AWS deployments, CONTAINER_TYPE should be set to 'ecs' or 'eks'."
                )
            else:
                error_msg = f"Configuration mismatch: CONTAINER_TYPE={container_type}, DELTA_TABLE_PATH={delta_path}"
            
            logger.error(error_msg)
            raise ValueError(error_msg)
        
        # Verify Delta table exists before running analytics
        if not verify_delta_table_exists(delta_path, repo_root, is_ecs_deployment, is_eks_deployment):
            logger.warning("Delta table not found, skipping analytics run")
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
        
        # Build Spark packages (adds S3A packages for AWS deployments)
        spark_packages = get_spark_packages(is_aws_deployment)
        logger.info(f"Spark packages: {spark_packages}")
        
        # Build spark-submit command
        cmd = [spark_submit, "--packages", spark_packages]
        
        # Add S3A configuration for AWS deployments (required for S3 access)
        if is_aws_deployment:
            cmd.extend(get_s3a_spark_config())
            logger.info("Added S3A configuration for AWS S3 access")
        
        # Add script path and arguments
        cmd.extend([script_path, delta_path, output_dir])
        
        logger.info(f"Running Spark analytics: {' '.join(cmd)}")
        result = subprocess.run(
            cmd,
            cwd=repo_root,
            env=env,
            capture_output=True,
            text=True,
            timeout=300  # 5 minute timeout
        )
        
        # Log Spark output for debugging
        if result.stdout:
            logger.info(f"Spark job stdout:\n{result.stdout}")
        if result.stderr:
            logger.warning(f"Spark job stderr:\n{result.stderr}")
        
        if result.returncode == 0:
            logger.info("Spark analytics completed successfully")
            # Check if save_analytics_to_db was called by looking for its output
            if "Analytics saved to database" in result.stdout:
                logger.info("✓ Analytics data saved to database")
            elif "Error saving analytics" in result.stdout:
                logger.error("✗ Analytics save to database failed - check Spark output above")
            else:
                logger.warning("⚠ Could not determine if analytics was saved to database (check Spark output above)")
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

