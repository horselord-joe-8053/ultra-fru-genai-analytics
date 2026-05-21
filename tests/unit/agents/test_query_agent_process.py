"""QueryAgent.process_query with stubbed LLM (no real Bedrock)."""

from unittest.mock import MagicMock, patch

from backend.agents.query_agent import QueryAgent


@patch("backend.agents.query_agent.claude_complete")
def test_process_query_no_tool_calls_returns_answer(mock_claude, mock_db_pool):
    mock_claude.side_effect = [
        {"text": "I have enough data.", "tokens": {"input": 1, "output": 1, "total": 2}},
        {"text": "Final answer based on data.", "tokens": {"input": 1, "output": 1, "total": 2}},
    ]
    agent = QueryAgent(mock_db_pool, MagicMock(), MagicMock())
    result = agent.process_query("What is the average rating?")
    assert "answer" in result
    assert result.get("iterations", 0) >= 1
