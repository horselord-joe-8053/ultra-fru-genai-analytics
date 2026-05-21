"""SQLTool validation and execution."""

from backend.agents.tools.sql_tool import SQLTool


def test_validate_input_rejects_drop(mock_db_pool):
    tool = SQLTool(mock_db_pool)
    ok, err = tool.validate_input(sql_query="DROP TABLE fru_sales_embeddings")
    assert ok is False
    assert "DROP" in err


def test_validate_input_requires_select(mock_db_pool):
    tool = SQLTool(mock_db_pool)
    ok, err = tool.validate_input(sql_query="UPDATE fru_sales_embeddings SET brand='x'")
    assert ok is False


def test_execute_returns_rows(mock_db_pool, mock_db_connection):
    tool = SQLTool(mock_db_pool)
    result = tool.execute(sql_query="SELECT id, brand FROM fru_sales_embeddings LIMIT 1")
    assert result["success"] is True
    assert result["row_count"] == 1
    assert result["execution_time_ms"] >= 0
    mock_db_pool.putconn.assert_called()
