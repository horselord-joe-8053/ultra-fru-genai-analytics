"""
SQL execution tool for agent.
"""
import time
import logging
from typing import Dict, Any, Optional, List, Tuple
import psycopg2
from psycopg2.extras import RealDictCursor
from psycopg2 import Error as Psycopg2Error

from .base_tool import BaseTool

logger = logging.getLogger(__name__)


class SQLTool(BaseTool):
    """Tool for executing SQL queries."""
    
    # Dangerous SQL keywords to block
    DANGEROUS_KEYWORDS = [
        'DROP', 'DELETE', 'TRUNCATE', 'ALTER', 'CREATE', 'INSERT', 'UPDATE',
        'GRANT', 'REVOKE', 'EXEC', 'EXECUTE'
    ]
    
    def __init__(self, db_connection_pool):
        super().__init__(
            name="execute_sql",
            description="Execute SQL queries on the fru_sales_embeddings table. Returns query results as JSON."
        )
        self.db_pool = db_connection_pool
    
    def validate_input(self, sql_query: str = None, **kwargs) -> Tuple[bool, Optional[str]]:
        """Validate SQL query for safety."""
        if not sql_query:
            return False, "SQL query is required"
        
        sql_upper = sql_query.upper().strip()
        
        # Block dangerous operations
        for keyword in self.DANGEROUS_KEYWORDS:
            if keyword in sql_upper:
                return False, f"Dangerous SQL keyword '{keyword}' is not allowed"
        
        # Only allow SELECT queries
        if not sql_upper.startswith('SELECT'):
            return False, "Only SELECT queries are allowed"
        
        return True, None
    
    def execute(self, sql_query: str, **kwargs) -> Dict[str, Any]:
        """
        Execute SQL query.
        
        Args:
            sql_query: SQL SELECT query string
        
        Returns:
            Dict with success, rows, columns, row_count, error, execution_time_ms
        """
        start_time = time.time()
        
        # Validate input
        is_valid, error_msg = self.validate_input(sql_query=sql_query)
        if not is_valid:
            return {
                "success": False,
                "error": error_msg,
                "execution_time_ms": (time.time() - start_time) * 1000
            }
        
        conn = None
        try:
            conn = self.db_pool.getconn()
            with conn.cursor(cursor_factory=RealDictCursor) as cur:
                cur.execute(sql_query)
                rows = cur.fetchall()
                
                # Convert to list of dicts
                result_rows = [dict(row) for row in rows]
                
                # Get column names
                columns = [desc[0] for desc in cur.description] if cur.description else []
                
                execution_time = (time.time() - start_time) * 1000
                
                logger.info(f"SQL executed successfully: {len(result_rows)} rows in {execution_time:.2f}ms")
                
                return {
                    "success": True,
                    "rows": result_rows,
                    "columns": columns,
                    "row_count": len(result_rows),
                    "execution_time_ms": execution_time
                }
        
        except Psycopg2Error as e:
            error_msg = f"Database error: {str(e)}"
            logger.error(f"SQL execution error: {error_msg}")
            return {
                "success": False,
                "error": error_msg,
                "execution_time_ms": (time.time() - start_time) * 1000
            }
        
        except Exception as e:
            error_msg = f"Unexpected error: {str(e)}"
            logger.error(f"SQL execution error: {error_msg}")
            return {
                "success": False,
                "error": error_msg,
                "execution_time_ms": (time.time() - start_time) * 1000
            }
        
        finally:
            if conn:
                self.db_pool.putconn(conn)

