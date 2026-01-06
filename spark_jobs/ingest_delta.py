from pyspark.sql import SparkSession
import sys
from spark_helper import print_relevant_env_vars, print_hadoop_conf

def main(input_path, output_path):
    # Print relevant environment variables for debugging
    print_relevant_env_vars()
    
    # Configure Spark with Delta Lake
    # Note: S3A configuration is set via --conf flags in spark-submit command
    # This ensures they're set as system properties before Spark starts
    spark = (
        SparkSession.builder.appName("fru-ingest")
        .config("spark.sql.extensions", "io.delta.sql.DeltaSparkSessionExtension")
        .config("spark.sql.catalog.spark_catalog", "org.apache.spark.sql.delta.catalog.DeltaCatalog")
        .getOrCreate()
    )
    
    # Print Hadoop configuration for debugging
    print_hadoop_conf(spark)
    df = (
        spark.read.option("header", "true")
        .option("inferSchema", "true")
        .csv(input_path)
    )
    if "ID" in df.columns:
        df = df.withColumnRenamed("ID", "id")
    df.write.format("delta").mode("overwrite").save(output_path)
    print("Wrote Delta table to", output_path)

if __name__ == "__main__":
    if len(sys.argv) < 3:
        print("Usage: ingest_delta.py <input_csv> <output_delta_path>")
        sys.exit(1)
    main(sys.argv[1], sys.argv[2])
