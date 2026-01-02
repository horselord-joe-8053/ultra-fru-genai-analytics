#!/usr/bin/env python3
"""
Generate batch analytics from PostgreSQL database and save to batch_analytics table.
This is a simpler alternative to Spark-based analytics that reads directly from the database.
"""
import sys
import os
from decimal import Decimal

# Add project root to path
project_root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, project_root)

from backend.services.save_analytics_to_db import save_analytics_to_db
from backend.utils.env_helpers import get_required_env, get_optional_int_env
from psycopg2.extras import RealDictCursor
import psycopg2


def compute_analytics_from_db():
    """Compute batch analytics from PostgreSQL database."""
    db_config = {
        "host": get_required_env("PGHOST", "Database host"),
        "port": get_optional_int_env("PGPORT", 5432),
        "user": get_required_env("PGUSER", "Database username"),
        "password": get_required_env("PGPASSWORD", "Database password"),
        "dbname": get_required_env("PGDATABASE", "Database name"),
    }
    conn = psycopg2.connect(**db_config)
    
    try:
        with conn.cursor(cursor_factory=RealDictCursor) as cur:
            # 1. Sales by Brand
            cur.execute("""
                SELECT 
                    brand,
                    COUNT(*) as total_sales,
                    SUM(price) as total_revenue,
                    AVG(price) as avg_price,
                    MIN(price) as min_price,
                    MAX(price) as max_price
                FROM fru_sales_embeddings
                WHERE brand IS NOT NULL
                GROUP BY brand
                ORDER BY total_sales DESC
            """)
            sales_by_brand = [
                {
                    "brand": row["brand"],
                    "total_sales": int(row["total_sales"]),
                    "total_revenue": float(row["total_revenue"]) if row["total_revenue"] else 0.0,
                    "avg_price": float(row["avg_price"]) if row["avg_price"] else 0.0,
                    "min_price": float(row["min_price"]) if row["min_price"] else 0.0,
                    "max_price": float(row["max_price"]) if row["max_price"] else 0.0,
                }
                for row in cur.fetchall()
            ]
            
            # 2. Store Performance
            cur.execute("""
                SELECT 
                    store_name,
                    COUNT(*) as total_sales,
                    SUM(price) as total_revenue,
                    AVG(price) as avg_sale_price,
                    COUNT(CASE WHEN feedback_sentiment_category = 'Negative' THEN 1 END) as negative_feedback_count,
                    COUNT(CASE WHEN feedback_sentiment_category = 'Positive' THEN 1 END) as positive_feedback_count
                FROM fru_sales_embeddings
                WHERE store_name IS NOT NULL
                GROUP BY store_name
                ORDER BY total_revenue DESC
            """)
            store_performance = []
            for row in cur.fetchall():
                total_sales = int(row["total_sales"])
                negative_count = int(row["negative_feedback_count"] or 0)
                negative_rate = (negative_count / total_sales * 100) if total_sales > 0 else 0.0
                
                store_performance.append({
                    "store_name": row["store_name"],
                    "total_sales": total_sales,
                    "total_revenue": float(row["total_revenue"]) if row["total_revenue"] else 0.0,
                    "avg_sale_price": float(row["avg_sale_price"]) if row["avg_sale_price"] else 0.0,
                    "negative_feedback_count": negative_count,
                    "positive_feedback_count": int(row["positive_feedback_count"] or 0),
                    "negative_feedback_rate": round(negative_rate, 2),
                })
            
            # 3. Feedback Analysis by Brand
            cur.execute("""
                SELECT 
                    brand,
                    feedback_sentiment_category,
                    COUNT(*) as count
                FROM fru_sales_embeddings
                WHERE brand IS NOT NULL AND feedback_sentiment_category IS NOT NULL
                GROUP BY brand, feedback_sentiment_category
                ORDER BY brand, count DESC
            """)
            feedback_by_brand = [
                {
                    "brand": row["brand"],
                    "sentiment": row["feedback_sentiment_category"],
                    "count": int(row["count"]),
                }
                for row in cur.fetchall()
            ]
            
            # 4. Top Models by Sales
            cur.execute("""
                SELECT 
                    brand,
                    fridge_model,
                    COUNT(*) as sales_count,
                    SUM(price) as total_revenue,
                    AVG(price) as avg_price
                FROM fru_sales_embeddings
                WHERE brand IS NOT NULL AND fridge_model IS NOT NULL
                GROUP BY brand, fridge_model
                ORDER BY sales_count DESC
                LIMIT 10
            """)
            top_models = [
                {
                    "brand": row["brand"],
                    "model": row["fridge_model"],
                    "sales_count": int(row["sales_count"]),
                    "total_revenue": float(row["total_revenue"]) if row["total_revenue"] else 0.0,
                    "avg_price": float(row["avg_price"]) if row["avg_price"] else 0.0,
                }
                for row in cur.fetchall()
            ]
            
            # 5. Price Statistics
            cur.execute("""
                SELECT 
                    AVG(price) as mean_price,
                    MIN(price) as min_price,
                    MAX(price) as max_price
                FROM fru_sales_embeddings
                WHERE price IS NOT NULL
            """)
            price_row = cur.fetchone()
            price_stats = {
                "mean_price": float(price_row["mean_price"]) if price_row["mean_price"] else 0.0,
                "min_price": float(price_row["min_price"]) if price_row["min_price"] else 0.0,
                "max_price": float(price_row["max_price"]) if price_row["max_price"] else 0.0,
            }
            
            # 6. Total records and revenue
            cur.execute("""
                SELECT 
                    COUNT(*) as total_records,
                    SUM(price) as total_revenue
                FROM fru_sales_embeddings
            """)
            totals = cur.fetchone()
            total_records = int(totals["total_records"] or 0)
            total_revenue = float(totals["total_revenue"]) if totals["total_revenue"] else 0.0
            
            print("=" * 80)
            print("FRU Batch Analytics Report (from PostgreSQL)")
            print("=" * 80)
            print(f"\nTotal records: {total_records}")
            print(f"Total revenue: ${total_revenue:,.2f}")
            print(f"\nSales by Brand: {len(sales_by_brand)} brands")
            print(f"Store Performance: {len(store_performance)} stores")
            print(f"Feedback Analysis: {len(feedback_by_brand)} brand-sentiment pairs")
            print(f"Top Models: {len(top_models)} models")
            print("=" * 80)
            
            # Save to database
            success = save_analytics_to_db(
                sales_by_brand=sales_by_brand,
                store_performance=store_performance,
                feedback_analysis=feedback_by_brand,
                top_models=top_models,
                price_stats=price_stats,
                total_records=total_records,
                total_revenue=total_revenue,
            )
            
            if success:
                print("✓ Batch analytics saved successfully!")
                return True
            else:
                print("✗ Failed to save batch analytics")
                return False
                
    finally:
        conn.close()


if __name__ == "__main__":
    print("Running batch analytics from PostgreSQL database...")
    success = compute_analytics_from_db()
    sys.exit(0 if success else 1)

