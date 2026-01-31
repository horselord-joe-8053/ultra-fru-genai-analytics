"""
Metrics tracking for agent performance.

Applicable environment: [local] [aws {ecs | eks}] [azure {aci | aks}] [gcp {cloud-run | gke}]
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
        # Token tracking
        self.input_tokens_histogram = []
        self.output_tokens_histogram = []
        self.total_tokens_histogram = []
    
    def record_query(self, query_type: str, latency_ms: float, iterations: int, success: bool, 
                     input_tokens: int = 0, output_tokens: int = 0, total_tokens: int = 0):
        """Record query metrics."""
        with self._lock:
            self.query_count += 1
            self.latency_histogram.append(latency_ms)
            self.iteration_counts.append(iterations)
            
            if input_tokens > 0:
                self.input_tokens_histogram.append(input_tokens)
            if output_tokens > 0:
                self.output_tokens_histogram.append(output_tokens)
            if total_tokens > 0:
                self.total_tokens_histogram.append(total_tokens)
            
            if success:
                self.success_count += 1
            else:
                self.failure_count += 1
                self.error_count[query_type] += 1
    
    def record_tool_call(self, tool_name: str, latency_ms: float, success: bool, 
                         input_tokens: int = 0, output_tokens: int = 0, total_tokens: int = 0):
        """Record tool call metrics."""
        with self._lock:
            self.tool_call_count[tool_name] += 1
            if not success:
                self.error_count[f"tool_{tool_name}"] += 1
            
            # Track tokens for tool calls (e.g., SQL generation, synthesis)
            if input_tokens > 0:
                self.input_tokens_histogram.append(input_tokens)
            if output_tokens > 0:
                self.output_tokens_histogram.append(output_tokens)
            if total_tokens > 0:
                self.total_tokens_histogram.append(total_tokens)
    
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
            
            # Token statistics
            total_input_tokens = sum(self.input_tokens_histogram) if self.input_tokens_histogram else 0
            total_output_tokens = sum(self.output_tokens_histogram) if self.output_tokens_histogram else 0
            total_tokens = sum(self.total_tokens_histogram) if self.total_tokens_histogram else 0
            avg_input_tokens = (
                total_input_tokens / len(self.input_tokens_histogram)
                if self.input_tokens_histogram else 0
            )
            avg_output_tokens = (
                total_output_tokens / len(self.output_tokens_histogram)
                if self.output_tokens_histogram else 0
            )
            avg_total_tokens = (
                total_tokens / len(self.total_tokens_histogram)
                if self.total_tokens_histogram else 0
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
                "errors": dict(self.error_count),
                "token_usage": {
                    "total_input_tokens": total_input_tokens,
                    "total_output_tokens": total_output_tokens,
                    "total_tokens": total_tokens,
                    "avg_input_tokens": avg_input_tokens,
                    "avg_output_tokens": avg_output_tokens,
                    "avg_total_tokens": avg_total_tokens,
                    "token_calls": len(self.total_tokens_histogram)
                }
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
            self.input_tokens_histogram.clear()
            self.output_tokens_histogram.clear()
            self.total_tokens_histogram.clear()


# Global metrics instance
agent_metrics = AgentMetrics()

