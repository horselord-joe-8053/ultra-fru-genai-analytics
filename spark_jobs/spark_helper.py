"""
Debugging utilities for Spark jobs.
Helps diagnose S3A configuration and environment variable issues.
"""
import os

def print_relevant_env_vars():
    """
    Print environment variables that contain S3A, SPARK, or HADOOP in their names.
    This helps diagnose configuration issues where environment variables might
    be set with problematic string values (e.g., "60s", "24h").
    """
    print("=== START - Relevant Environment Variables (S3A, SPARK, HADOOP) ===")
    
    found_any = False
    for k, v in sorted(os.environ.items()):
        k_upper = k.upper()
        if "S3A" in k_upper or "SPARK" in k_upper or "HADOOP" in k_upper:
            print(f"[SSH] {k}={v}")
            found_any = True
    
    if not found_any:
        print("No relevant environment variables found.")
    
    print("=== END - Relevant Environment Variables (S3A, SPARK, HADOOP) ===")


def print_hadoop_conf(spark):
    """
    Print Hadoop configuration key-value pairs from Spark session.
    This helps diagnose configuration issues where Hadoop properties might
    be set with problematic string values (e.g., "60s", "24h").
    
    Args:
        spark: SparkSession object (must be created first)
    """
    print("=== START - Hadoop conf entries ===")
    
    try:
        hconf = spark.sparkContext._jsc.hadoopConfiguration()
        it = hconf.iterator()
        
        while it.hasNext():
            e = it.next()
            k = e.getKey()
            v = e.getValue()
            print(f"[HAD] {k}={v}")
    except Exception as e:
        print(f"Error retrieving Hadoop configuration: {e}")
    
    print("=== END - Hadoop conf entries ===")

