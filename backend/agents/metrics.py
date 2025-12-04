"""
Metrics tracking for agent performance.
"""
import time
import logging
from typing import Dict, Any
from collections import defaultdict
import threading

logger = logging.getLogger(__name__)


class AgentMetrics:
    """Track agent performance metrics (thread-safe)."""
    
    def __init__(self):
        self._lock = threading.Lock()
        self.query_count = 0
        self.tool_call_count = defaultdict(int)
        self.error_count = defaultdict(int)
        self.latency_histogram = []
        self.iteration_counts = []
        self.success_count = 0
        self.failure_count = 0
    
    def record_query(self, query_type: str, latency_ms: float, iterations: int, success: bool):
        """Record query metrics."""
        with self._lock:
            self.query_count += 1
            self.latency_histogram.append(latency_ms)
            self.iteration_counts.append(iterations)
            
            if success:
                self.success_count += 1
            else:
                self.failure_count += 1
                self.error_count[query_type] += 1
    
    def record_tool_call(self, tool_name: str, latency_ms: float, success: bool):
        """Record tool call metrics."""
        with self._lock:
            self.tool_call_count[tool_name] += 1
            if not success:
                self.error_count[f"tool_{tool_name}"] += 1
    
    def get_stats(self) -> Dict[str, Any]:
        """Get aggregated statistics."""
        with self._lock:
            avg_latency = (
                sum(self.latency_histogram) / len(self.latency_histogram)
                if self.latency_histogram else 0
            )
            avg_iterations = (
                sum(self.iteration_counts) / len(self.iteration_counts)
                if self.iteration_counts else 0
            )
            
            return {
                "total_queries": self.query_count,
                "success_count": self.success_count,
                "failure_count": self.failure_count,
                "success_rate": (
                    self.success_count / self.query_count * 100
                    if self.query_count > 0 else 0
                ),
                "avg_latency_ms": avg_latency,
                "avg_iterations": avg_iterations,
                "tool_calls": dict(self.tool_call_count),
                "errors": dict(self.error_count)
            }
    
    def reset(self):
        """Reset all metrics (for testing)."""
        with self._lock:
            self.query_count = 0
            self.tool_call_count.clear()
            self.error_count.clear()
            self.latency_histogram.clear()
            self.iteration_counts.clear()
            self.success_count = 0
            self.failure_count = 0


# Global metrics instance
agent_metrics = AgentMetrics()

