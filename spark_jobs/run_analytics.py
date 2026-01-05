from pyspark.sql import SparkSession
from pyspark.sql.functions import col, count, sum, avg, min, max, when, date_format
import sys
import json
import os
from datetime import datetime

# Add project root to path for importing save_analytics_to_db
# __file__ is at /app/spark_jobs/run_analytics.py, so project_root should be /app
project_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, project_root)

# Also add /app explicitly (in case __file__ path resolution differs in Spark context)
if "/app" not in sys.path:
    sys.path.insert(0, "/app")

try:
    from backend.services.analytics.save_to_db import save_analytics_to_db
    print(f"✓ Successfully imported save_analytics_to_db from {project_root}/backend/services/analytics/save_to_db.py")
except ImportError as e:
    print(f"✗ Warning: Could not import save_analytics_to_db: {e}")
    print(f"  Project root detected: {project_root}")
    print(f"  Python path (first 3 entries): {sys.path[:3]}")
    backend_path = os.path.join(project_root, "backend")
    print(f"  Backend directory exists: {os.path.exists(backend_path)}")
    analytics_path = os.path.join(project_root, "backend", "services", "analytics")
    print(f"  Analytics directory exists: {os.path.exists(analytics_path)}")
    save_to_db_path = os.path.join(project_root, "backend", "services", "analytics", "save_to_db.py")
    print(f"  save_to_db.py exists: {os.path.exists(save_to_db_path)}")
    print("Analytics will be computed but not saved to database.")
    save_analytics_to_db = None

def main(delta_path: str, output_dir: str):
    """
    Run batch analytics on Delta table.
    Demonstrates offline batch analytics capabilities of Spark + Delta.
    """
    # Get limit from environment (default to 20)
    spark_compute_limit = int(os.getenv("NUM_FOR_BATCH_ANALYTICS_TOP_SPARK_COMPUTE", "20"))
    print(f"Using Spark compute limit: {spark_compute_limit} items per aggregation")
    
    spark = (
        SparkSession.builder.appName("fru-batch-analytics")
        .config("spark.sql.extensions", "io.delta.sql.DeltaSparkSessionExtension")
        .config("spark.sql.catalog.spark_catalog", "org.apache.spark.sql.delta.catalog.DeltaCatalog")
        .getOrCreate()
    )
    
    # Read Delta table
    df = spark.read.format("delta").load(delta_path)
    
    print("=" * 80)
    print("FRU Batch Analytics Report")
    print("=" * 80)
    print(f"\nTotal records in Delta table: {df.count()}")
    
    # 1. Sales by Brand
    print("\n" + "=" * 80)
    print("1. Sales Summary by Brand")
    print("=" * 80)
    sales_by_brand = (
        df.groupBy("BRAND")
        .agg(
            count("*").alias("total_sales"),
            sum("PRICE").alias("total_revenue"),
            avg("PRICE").alias("avg_price"),
            min("PRICE").alias("min_price"),
            max("PRICE").alias("max_price")
        )
        .orderBy(col("total_sales").desc())
        .limit(spark_compute_limit)
    )
    sales_by_brand.show(truncate=False)
    
    # 2. Store Performance
    print("\n" + "=" * 80)
    print("2. Store Performance Metrics")
    print("=" * 80)
    store_performance = (
        df.groupBy("STORE_NAME")
        .agg(
            count("*").alias("total_sales"),
            sum("PRICE").alias("total_revenue"),
            avg("PRICE").alias("avg_sale_price"),
            count(when(col("FEEDBACK_SENTIMENT_CATEGORY") == "Negative", 1)).alias("negative_feedback_count"),
            count(when(col("FEEDBACK_SENTIMENT_CATEGORY") == "Positive", 1)).alias("positive_feedback_count")
        )
        .withColumn("negative_feedback_rate", 
                   (col("negative_feedback_count") / col("total_sales") * 100).cast("decimal(5,2)"))
        .orderBy(col("total_revenue").desc())
        .limit(spark_compute_limit)
    )
    store_performance.show(truncate=False)
    
    # 3. Feedback Analysis by Brand
    print("\n" + "=" * 80)
    print("3. Feedback Analysis by Brand")
    print("=" * 80)
    feedback_by_brand = (
        df.groupBy("BRAND", "FEEDBACK_SENTIMENT_CATEGORY")
        .agg(count("*").alias("count"))
        .orderBy("BRAND", col("count").desc())
    )
    feedback_by_brand.show(truncate=False)
    
    # 4. Monthly Sales Trends (if SALES_DATE exists)
    if "SALES_DATE" in df.columns:
        print("\n" + "=" * 80)
        print("4. Monthly Sales Trends")
        print("=" * 80)
        monthly_sales = (
            df.withColumn("month", date_format(col("SALES_DATE"), "yyyy-MM"))
            .groupBy("month")
            .agg(
                count("*").alias("sales_count"),
                sum("PRICE").alias("monthly_revenue"),
                avg("PRICE").alias("avg_price")
            )
            .orderBy("month")
        )
        monthly_sales.show(truncate=False)
    
    # 5. Top Models by Sales
    print("\n" + "=" * 80)
    print("5. Top Fridge Models by Sales Volume")
    print("=" * 80)
    top_models = (
        df.groupBy("BRAND", "FRIDGE_MODEL")
        .agg(
            count("*").alias("sales_count"),
            sum("PRICE").alias("total_revenue"),
            avg("PRICE").alias("avg_price")
        )
        .orderBy(col("sales_count").desc())
        .limit(spark_compute_limit)
    )
    top_models.show(truncate=False)
    
    # 6. Price Distribution Analysis
    print("\n" + "=" * 80)
    print("6. Price Distribution Statistics")
    print("=" * 80)
    price_stats = df.select(
        avg("PRICE").alias("mean_price"),
        min("PRICE").alias("min_price"),
        max("PRICE").alias("max_price")
    )
    price_stats.show(truncate=False)
    
    # Collect data for database storage
    total_records = df.count()
    total_revenue_row = df.agg(sum("PRICE").alias("total")).collect()[0]
    total_revenue = float(total_revenue_row["total"]) if total_revenue_row["total"] else 0.0
    
    # Convert Spark DataFrames to Python lists of dicts
    sales_by_brand_list = [
        {
            "brand": row["BRAND"],
            "total_sales": int(row["total_sales"]),
            "total_revenue": float(row["total_revenue"]) if row["total_revenue"] else 0.0,
            "avg_price": float(row["avg_price"]) if row["avg_price"] else 0.0,
            "min_price": float(row["min_price"]) if row["min_price"] else 0.0,
            "max_price": float(row["max_price"]) if row["max_price"] else 0.0,
        }
        for row in sales_by_brand.collect()
    ]
    
    store_performance_list = [
        {
            "store_name": row["STORE_NAME"],
            "total_sales": int(row["total_sales"]),
            "total_revenue": float(row["total_revenue"]) if row["total_revenue"] else 0.0,
            "avg_sale_price": float(row["avg_sale_price"]) if row["avg_sale_price"] else 0.0,
            "negative_feedback_count": int(row["negative_feedback_count"]),
            "positive_feedback_count": int(row["positive_feedback_count"]),
            "negative_feedback_rate": float(row["negative_feedback_rate"]) if row["negative_feedback_rate"] else 0.0,
        }
        for row in store_performance.collect()
    ]
    
    feedback_analysis_list = [
        {
            "brand": row["BRAND"],
            "feedback_sentiment_category": row["FEEDBACK_SENTIMENT_CATEGORY"],
            "count": int(row["count"]),
        }
        for row in feedback_by_brand.collect()
    ]
    
    top_models_list = [
        {
            "brand": row["BRAND"],
            "fridge_model": row["FRIDGE_MODEL"],
            "sales_count": int(row["sales_count"]),
            "total_revenue": float(row["total_revenue"]) if row["total_revenue"] else 0.0,
            "avg_price": float(row["avg_price"]) if row["avg_price"] else 0.0,
        }
        for row in top_models.collect()
    ]
    
    price_stats_dict = {}
    price_stats_row = price_stats.collect()[0]
    if price_stats_row:
        price_stats_dict = {
            "mean_price": float(price_stats_row["mean_price"]) if price_stats_row["mean_price"] else 0.0,
            "min_price": float(price_stats_row["min_price"]) if price_stats_row["min_price"] else 0.0,
            "max_price": float(price_stats_row["max_price"]) if price_stats_row["max_price"] else 0.0,
        }
    
    # Save to PostgreSQL
    if save_analytics_to_db:
        print("\n" + "=" * 80)
        print("Saving analytics to PostgreSQL...")
        print("=" * 80)
        success = save_analytics_to_db(
            sales_by_brand=sales_by_brand_list,
            store_performance=store_performance_list,
            feedback_analysis=feedback_analysis_list,
            top_models=top_models_list,
            price_stats=price_stats_dict,
            total_records=total_records,
            total_revenue=total_revenue,
        )
    else:
        print("\n" + "=" * 80)
        print("Warning: save_analytics_to_db not available, skipping database save")
        print("=" * 80)
    
    # Also save summary to JSON (optional, for backup)
    if output_dir:
        os.makedirs(output_dir, exist_ok=True)
        summary = {
            "total_records": total_records,
            "total_revenue": total_revenue,
            "avg_price": price_stats_dict.get("mean_price", 0.0),
            "last_updated": datetime.now().isoformat(),
        }
        output_path = os.path.join(output_dir, "backup_analytics_summary.json")
        with open(output_path, "w") as f:
            json.dump(summary, f, indent=2)
        print(f"✓ Analytics summary backup saved to: {output_path}")
    
    print("\n" + "=" * 80)
    print("Analytics Complete!")
    print("=" * 80)

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: run_analytics.py <delta_path> [output_dir]")
        print("Example: run_analytics.py data/delta/fru_sales data/analytics")
        sys.exit(1)
    
    delta_path = sys.argv[1]
    output_dir = sys.argv[2] if len(sys.argv) > 2 else None
    main(delta_path, output_dir)

