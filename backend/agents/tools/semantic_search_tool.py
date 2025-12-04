"""
Semantic search tool for agent using pgvector.
"""
import time
import logging
from typing import Dict, Any, Optional, List, Tuple
import psycopg2
from psycopg2.extras import RealDictCursor
from psycopg2 import Error as Psycopg2Error
from openai import OpenAI

from .base_tool import BaseTool

logger = logging.getLogger(__name__)


class SemanticSearchTool(BaseTool):
    """Tool for semantic search using pgvector."""
    
    def __init__(self, db_connection_pool, openai_client: OpenAI):
        super().__init__(
            name="semantic_search",
            description="Search customer feedback using semantic similarity. Can filter by store_name, brand, or feedback_rating."
        )
        self.db_pool = db_connection_pool
        self.openai_client = openai_client
    
    def _embed_text(self, text: str) -> List[float]:
        """Generate embedding for text using OpenAI."""
        try:
            response = self.openai_client.embeddings.create(
                model="text-embedding-3-small",
                input=text
            )
            return response.data[0].embedding
        except Exception as e:
            logger.error(f"Failed to generate embedding: {e}")
            raise ValueError(f"Embedding generation failed: {e}")
    
    def validate_input(self, query_text: str = None, **kwargs) -> Tuple[bool, Optional[str]]:
        """Validate search input."""
        if not query_text:
            return False, "query_text is required"
        
        if len(query_text.strip()) < 3:
            return False, "query_text must be at least 3 characters"
        
        return True, None
    
    def execute(
        self,
        query_text: str,
        limit: int = 50,
        filters: Optional[Dict[str, List[str]]] = None,
        **kwargs
    ) -> Dict[str, Any]:
        """
        Execute semantic search.
        
        Args:
            query_text: Text to search for
            limit: Maximum number of results
            filters: Optional dict with keys: store_name, brand, feedback_rating
                    Values are lists of strings to filter by
        
        Returns:
            Dict with success, rows, row_count, error, execution_time_ms
        """
        start_time = time.time()
        
        # Validate input
        is_valid, error_msg = self.validate_input(query_text=query_text)
        if not is_valid:
            return {
                "success": False,
                "error": error_msg,
                "execution_time_ms": (time.time() - start_time) * 1000
            }
        
        conn = None
        try:
            # Generate embedding
            embedding = self._embed_text(query_text)
            
            # Build SQL with optional filters
            base_sql = (
                "SELECT id, brand, fridge_model, price, sales_date, store_name, "
                "customer_feedback, feedback_rating "
                "FROM fru_sales_embeddings "
            )
            
            where_clauses = []
            params = []
            
            # Add filters
            if filters:
                if "store_name" in filters and filters["store_name"]:
                    placeholders = ",".join(["%s"] * len(filters["store_name"]))
                    where_clauses.append(f"store_name IN ({placeholders})")
                    params.extend(filters["store_name"])
                
                if "brand" in filters and filters["brand"]:
                    placeholders = ",".join(["%s"] * len(filters["brand"]))
                    where_clauses.append(f"brand IN ({placeholders})")
                    params.extend(filters["brand"])
                
                if "feedback_rating" in filters and filters["feedback_rating"]:
                    placeholders = ",".join(["%s"] * len(filters["feedback_rating"]))
                    where_clauses.append(f"feedback_rating IN ({placeholders})")
                    params.extend(filters["feedback_rating"])
            
            # Build complete SQL
            if where_clauses:
                sql = base_sql + "WHERE " + " AND ".join(where_clauses) + " "
            else:
                sql = base_sql
            
            sql += "ORDER BY embedding <-> %s LIMIT %s;"
            params.extend([embedding, limit])
            
            # Execute query
            conn = self.db_pool.getconn()
            with conn.cursor(cursor_factory=RealDictCursor) as cur:
                cur.execute(sql, params)
                rows = cur.fetchall()
                result_rows = [dict(row) for row in rows]
                
                execution_time = (time.time() - start_time) * 1000
                
                logger.info(f"Semantic search completed: {len(result_rows)} results in {execution_time:.2f}ms")
                
                return {
                    "success": True,
                    "rows": result_rows,
                    "row_count": len(result_rows),
                    "execution_time_ms": execution_time
                }
        
        except Psycopg2Error as e:
            error_msg = f"Database error: {str(e)}"
            logger.error(f"Semantic search error: {error_msg}")
            return {
                "success": False,
                "error": error_msg,
                "execution_time_ms": (time.time() - start_time) * 1000
            }
        
        except Exception as e:
            error_msg = f"Unexpected error: {str(e)}"
            logger.error(f"Semantic search error: {error_msg}")
            return {
                "success": False,
                "error": error_msg,
                "execution_time_ms": (time.time() - start_time) * 1000
            }
        
        finally:
            if conn:
                self.db_pool.putconn(conn)

