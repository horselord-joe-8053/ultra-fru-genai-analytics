"""AgentMetrics aggregation."""

from backend.agents.metrics import AgentMetrics


def test_record_query_and_stats():
    m = AgentMetrics()
    m.record_query("agentic", 100.0, 2, True, input_tokens=10, output_tokens=20, total_tokens=30)
    stats = m.get_stats()
    assert stats["total_queries"] == 1
    assert stats["success_count"] == 1
    assert stats["token_usage"]["total_tokens"] == 30


def test_reset_clears_counters():
    m = AgentMetrics()
    m.record_query("agentic", 1.0, 1, False)
    m.reset()
    assert m.get_stats()["total_queries"] == 0
