"""QueryAgent parsing and synthesis selection."""

from unittest.mock import MagicMock

from backend.agents.query_agent import QueryAgent


def _agent() -> QueryAgent:
    return QueryAgent(MagicMock(), MagicMock(), MagicMock())


def test_parse_agent_response_tool_blocks():
    agent = _agent()
    text = (
        'TOOL: execute_sql\n'
        'INPUT: {"sql_query": "SELECT COUNT(*) FROM fru_sales_embeddings"}\n'
        'TOOL: semantic_search\n'
        'INPUT: {"query_text": "complaints"}\n'
    )
    calls = agent._parse_agent_response(text)
    assert len(calls) == 2
    assert calls[0]["tool"] == "execute_sql"
    assert "sql_query" in calls[0]["input"]


def test_select_synthesis_inputs_prefers_sql():
    agent = _agent()
    tool_results = [
        {
            "tool": "execute_sql",
            "output": {"success": True, "row_count": 2, "rows": [{"n": 1}]},
        },
        {
            "tool": "semantic_search",
            "output": {"success": True, "row_count": 1, "rows": [{"n": 2}]},
        },
    ]
    picked = agent._select_synthesis_inputs(tool_results)
    assert picked["primary_sql_result"] is not None


def test_normalize_tool_input_maps_question_to_query_text():
    agent = _agent()
    agent._current_question = "delivery issues"
    out = agent._normalize_tool_input("semantic_search", {"question": "delivery issues"})
    assert out["query_text"] == "delivery issues"
