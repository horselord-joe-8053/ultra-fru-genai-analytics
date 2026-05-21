"""SemanticSearchTool with mocked embeddings and DB."""

from unittest.mock import MagicMock

from backend.agents.tools.semantic_search_tool import SemanticSearchTool


def test_validate_input_requires_query_text(mock_db_pool):
    tool = SemanticSearchTool(mock_db_pool, MagicMock())
    ok, err = tool.validate_input()
    assert ok is False


def test_execute_with_mocked_embedding(mock_db_pool, mock_db_connection):
    openai = MagicMock()
    openai.embeddings.create.return_value = MagicMock(
        data=[MagicMock(embedding=[0.1] * 8)]
    )
    tool = SemanticSearchTool(mock_db_pool, openai)
    result = tool.execute(query_text="delivery complaints", limit=5)
    assert result["success"] is True
    assert result["row_count"] >= 0
