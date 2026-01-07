"""
Ingest CSV file into Delta table.
Converts CSV to Delta format for efficient analytics queries.
"""
from pyspark.sql import SparkSession
import sys
from spark_helper import print_relevant_env_vars, print_hadoop_conf


def main(input_path, output_path):
    """
    Create Delta table from CSV file.
    
    Args:
        input_path: Path to CSV file (local or S3)
        output_path: Path where Delta table will be created
    """
    # Debug: Print environment variables (helps diagnose S3A config issues)
    print_relevant_env_vars()
    
    # Configure Spark with Delta Lake extensions
    # Note: S3A configuration is set via --conf flags in spark-submit command
    spark = (
        SparkSession.builder.appName("fru-ingest")
        .config("spark.sql.extensions", "io.delta.sql.DeltaSparkSessionExtension")
        .config("spark.sql.catalog.spark_catalog", "org.apache.spark.sql.delta.catalog.DeltaCatalog")
        .getOrCreate()
    )
    
    # Debug: Print Hadoop configuration
    print_hadoop_conf(spark)
    
    # Read CSV and convert to Delta table
    df = (
        spark.read.option("header", "true")
        .option("inferSchema", "true")
        .csv(input_path)
    )
    
    # Normalize column name (ID -> id for consistency)
    if "ID" in df.columns:
        df = df.withColumnRenamed("ID", "id")
    
    # Write as Delta table (overwrite mode)
    df.write.format("delta").mode("overwrite").save(output_path)
    print(f"✓ Delta table created at: {output_path}")

if __name__ == "__main__":
    if len(sys.argv) < 3:
        print("Usage: ingest_delta.py <input_csv> <output_delta_path>")
        sys.exit(1)
    main(sys.argv[1], sys.argv[2])
