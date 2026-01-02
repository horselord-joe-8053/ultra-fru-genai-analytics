"""
Statistics computation utilities for query results.
"""
from typing import List, Dict, Any


def compute_simple_stats(rows: List[Dict[str, Any]]) -> Dict[str, Any]:
    """
    Compute simple statistics from query result rows.
    
    Args:
        rows: List of row dictionaries from database query
        
    Returns:
        Dictionary with:
        - total_matches: Total number of rows
        - by_brand: Count by brand
        - by_store: Count by store
        - by_rating: Count by feedback_sentiment_category
    """
    total = len(rows)
    by_brand: Dict[str, int] = {}
    by_store: Dict[str, int] = {}
    by_rating: Dict[str, int] = {}

    for r in rows:
        brand = (r.get("brand") or "").strip()
        store = (r.get("store_name") or "").strip()
        # feedback_rating is now INTEGER, feedback_sentiment_category is TEXT
        rating = r.get("feedback_rating")
        sentiment = (r.get("feedback_sentiment_category") or "").strip()

        if brand:
            by_brand[brand] = by_brand.get(brand, 0) + 1
        if store:
            by_store[store] = by_store.get(store, 0) + 1
        # Use sentiment_category for categorical stats (more meaningful than numeric rating)
        if sentiment:
            by_rating[sentiment] = by_rating.get(sentiment, 0) + 1

    return {
        "total_matches": total,
        "by_brand": by_brand,
        "by_store": by_store,
        "by_rating": by_rating,
    }

