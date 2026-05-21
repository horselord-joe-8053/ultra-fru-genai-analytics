"""AgentLogger structured traces."""

from backend.agents.logger import AgentLogger


def test_log_tool_call_captures_name(caplog):
    import logging

    caplog.set_level(logging.INFO)
    logger = AgentLogger("test-id")
    logger.start_query("q")
    logger.log_tool_call(
        "execute_sql",
        {"sql_query": "SELECT 1"},
        {"success": True, "row_count": 1, "sql": "SELECT 1"},
        12.5,
        iteration=1,
    )
    debug = logger.get_debug_info()
    assert len(debug["tool_calls"]) == 1
    assert debug["tool_calls"][0]["tool"] == "execute_sql"
