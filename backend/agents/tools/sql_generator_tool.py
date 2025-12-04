"""
SQL generation tool for agent using LLM.
"""
import time
import logging
import re
from typing import Dict, Any, Optional, Tuple

from .base_tool import BaseTool
from backend.llm.bedrock_client import claude_complete

logger = logging.getLogger(__name__)


class SQLGeneratorTool(BaseTool):
    """Tool for generating SQL queries from natural language using LLM."""
    
    def __init__(self, bedrock_client, schema_info: Dict[str, Any]):
        super().__init__(
            name="generate_sql",
            description="Generate SQL SELECT queries from natural language questions. Returns valid PostgreSQL SQL."
        )
        self.bedrock_client = bedrock_client
        self.schema_info = schema_info
    
    def _build_system_prompt(self) -> str:
        """Build system prompt for SQL generation."""
        schema_desc = self._format_schema_info()
        
        return f"""You are a SQL query generator for a fridge sales analytics database.

Database Schema:
{schema_desc}

Rules:
1. Generate ONLY valid PostgreSQL SELECT queries
2. Use the exact column names from the schema
3. For aggregations, use SUM(price) for revenue, COUNT(*) for counts
4. For region analysis, extract region from store_address (e.g., "New York, NY" → "Northeast")
5. Always include appropriate WHERE clauses for filtering
6. Use GROUP BY for aggregations
7. Use ORDER BY for sorting (DESC for highest/biggest, ASC for lowest/smallest)
8. Return ONLY the SQL query, no explanations or markdown

Example:
Question: "How many Samsung fridges were sold?"
SQL: SELECT COUNT(*) AS total_sales FROM fru_sales_embeddings WHERE brand = 'Samsung';

Question: "Which region has the biggest sales?"
SQL: SELECT 
    CASE 
        WHEN store_address LIKE '%New York%' OR store_address LIKE '%Boston%' THEN 'Northeast'
        WHEN store_address LIKE '%Chicago%' OR store_address LIKE '%Detroit%' THEN 'Midwest'
        WHEN store_address LIKE '%Los Angeles%' OR store_address LIKE '%San Francisco%' THEN 'West'
        WHEN store_address LIKE '%Houston%' OR store_address LIKE '%Miami%' THEN 'South'
        ELSE 'Other'
    END AS region,
    SUM(price) AS total_sales
FROM fru_sales_embeddings
GROUP BY region
ORDER BY total_sales DESC
LIMIT 1;
"""
    
    def _format_schema_info(self) -> str:
        """Format schema information for prompt."""
        table = self.schema_info.get("table", "fru_sales_embeddings")
        columns = self.schema_info.get("columns", {})
        
        lines = [f"Table: {table}", ""]
        for col_name, col_type in columns.items():
            lines.append(f"  - {col_name}: {col_type}")
        
        return "\n".join(lines)
    
    def _extract_sql(self, response: str) -> str:
        """Extract SQL from LLM response."""
        # Remove markdown code blocks if present
        response = response.strip()
        
        # Remove ```sql or ``` markers
        response = re.sub(r'^```sql\s*', '', response, flags=re.MULTILINE)
        response = re.sub(r'^```\s*', '', response, flags=re.MULTILINE)
        response = re.sub(r'```\s*$', '', response, flags=re.MULTILINE)
        
        # Extract SQL (everything between first SELECT and last semicolon)
        sql_match = re.search(r'(SELECT.*?;)', response, re.DOTALL | re.IGNORECASE)
        if sql_match:
            return sql_match.group(1).strip()
        
        # If no match, return cleaned response
        return response.strip()
    
    def validate_input(self, question: str = None, **kwargs) -> Tuple[bool, Optional[str]]:
        """Validate input question."""
        if not question:
            return False, "question is required"
        
        if len(question.strip()) < 5:
            return False, "question must be at least 5 characters"
        
        return True, None
    
    def execute(self, question: str, **kwargs) -> Dict[str, Any]:
        """
        Generate SQL from natural language question.
        
        Args:
            question: Natural language question
        
        Returns:
            Dict with success, sql, error, execution_time_ms
        """
        start_time = time.time()
        
        # Validate input
        is_valid, error_msg = self.validate_input(question=question)
        if not is_valid:
            return {
                "success": False,
                "error": error_msg,
                "execution_time_ms": (time.time() - start_time) * 1000
            }
        
        try:
            system_prompt = self._build_system_prompt()
            user_message = f"Generate a SQL query for this question: {question}"
            
            # Call Claude
            response = claude_complete(
                system_prompt=system_prompt,
                user_message=user_message,
                max_tokens=500
            )
            
            # Extract SQL
            sql = self._extract_sql(response)
            
            execution_time = (time.time() - start_time) * 1000
            
            logger.info(f"SQL generated successfully in {execution_time:.2f}ms")
            
            return {
                "success": True,
                "sql": sql,
                "execution_time_ms": execution_time
            }
        
        except Exception as e:
            error_msg = f"SQL generation failed: {str(e)}"
            logger.error(f"SQL generation error: {error_msg}")
            return {
                "success": False,
                "error": error_msg,
                "execution_time_ms": (time.time() - start_time) * 1000
            }

