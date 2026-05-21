"""SQLGeneratorTool LLM extraction."""

from unittest.mock import MagicMock, patch

from backend.agents.tools.sql_generator_tool import SQLGeneratorTool

SCHEMA = {"table": "fru_sales_embeddings", "columns": {"brand": "TEXT", "price": "NUMERIC"}}


def test_extract_sql_strips_markdown():
    tool = SQLGeneratorTool(MagicMock(), SCHEMA)
    raw = "```sql\nSELECT COUNT(*) FROM fru_sales_embeddings;\n```"
    assert "SELECT" in tool._extract_sql(raw)


@patch("backend.agents.tools.sql_generator_tool.claude_complete")
def test_execute_returns_sql(mock_complete, mock_db_pool):
    mock_complete.return_value = {"text": "SELECT COUNT(*) AS c FROM fru_sales_embeddings;"}
    tool = SQLGeneratorTool(MagicMock(), SCHEMA)
    result = tool.execute(question="How many rows?")
    assert result["success"] is True
    assert "SELECT" in result["sql"].upper()
