"""
Service to save Spark analytics results to PostgreSQL.
Can be called from Spark job or Python script.
"""
import os
import json
import psycopg2
from typing import Dict, Any, Optional
from datetime import datetime
from backend.utils.env_helpers import get_required_env, get_optional_int_env


def save_analytics_to_db(
    sales_by_brand: list,
    store_performance: list,
    feedback_analysis: list,
    top_models: list,
    price_stats: Dict[str, Any],
    total_records: int,
    total_revenue: float,
    db_config: Optional[Dict[str, Any]] = None
) -> bool:
    """
    Save analytics results to PostgreSQL batch_analytics table.
    
    Args:
        sales_by_brand: List of brand analytics dicts
        store_performance: List of store performance dicts
        feedback_analysis: List of feedback analysis dicts
        top_models: List of top models dicts
        price_stats: Price statistics dict
        total_records: Total number of records
        total_revenue: Total revenue
        db_config: Optional DB config dict, defaults to env vars
    
    Returns:
        bool: True if successful, False otherwise
    """
    if db_config is None:
        db_config = {
            "host": get_required_env("PGHOST", "Database host"),
            "port": get_optional_int_env("PGPORT", 5432),
            "user": get_required_env("PGUSER", "Database username"),
            "password": get_required_env("PGPASSWORD", "Database password"),
            "dbname": get_required_env("PGDATABASE", "Database name"),
        }
    
    try:
        conn = psycopg2.connect(**db_config)
        cur = conn.cursor()
        
        # Convert lists to JSONB
        sales_by_brand_json = json.dumps(sales_by_brand)
        store_performance_json = json.dumps(store_performance)
        feedback_analysis_json = json.dumps(feedback_analysis)
        top_models_json = json.dumps(top_models)
        price_stats_json = json.dumps(price_stats)
        
        # Insert into batch_analytics table
        insert_sql = """
        INSERT INTO batch_analytics 
        (sales_by_brand, store_performance, feedback_analysis, top_models, 
         price_stats, total_records, total_revenue)
        VALUES (%s, %s, %s, %s, %s, %s, %s)
        """
        
        cur.execute(
            insert_sql,
            (
                sales_by_brand_json,
                store_performance_json,
                feedback_analysis_json,
                top_models_json,
                price_stats_json,
                total_records,
                total_revenue,
            )
        )
        
        conn.commit()
        cur.close()
        conn.close()
        
        print(f"✓ Analytics saved to database at {datetime.now().isoformat()}")
        return True
        
    except Exception as e:
        print(f"✗ Error saving analytics to database: {e}")
        return False

