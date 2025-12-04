"""
Structured logging for agent execution.
"""
import json
import logging
import uuid
from typing import Dict, Any, List, Optional
from datetime import datetime
from collections import defaultdict

logger = logging.getLogger(__name__)


class AgentLogger:
    """Structured logger for agent operations."""
    
    def __init__(self, query_id: Optional[str] = None):
        self.query_id = query_id or str(uuid.uuid4())
        self.tool_calls: List[Dict[str, Any]] = []
        self.agent_thoughts: List[str] = []
        self.iterations = 0
        self.start_time: Optional[float] = None
        self.end_time: Optional[float] = None
    
    def start_query(self, question: str):
        """Log start of query processing."""
        self.start_time = datetime.now().timestamp()
        logger.info(f"[{self.query_id}] Starting query: {question}")
    
    def log_thought(self, thought: str):
        """Log agent reasoning."""
        self.agent_thoughts.append(thought)
        logger.debug(f"[{self.query_id}] Agent thought: {thought}")
    
    def log_tool_call(self, tool_name: str, input_data: Dict[str, Any], 
                     output_data: Dict[str, Any], execution_time_ms: float):
        """Log tool execution."""
        tool_call = {
            "tool": tool_name,
            "input": input_data,
            "output": {
                "success": output_data.get("success", False),
                "summary": self._summarize_output(output_data),
                "error": output_data.get("error"),
                "row_count": output_data.get("row_count"),
                "execution_time_ms": execution_time_ms
            },
            "timestamp": datetime.now().isoformat()
        }
        self.tool_calls.append(tool_call)
        logger.info(f"[{self.query_id}] Tool: {tool_name}, Success: {tool_call['output']['success']}, Time: {execution_time_ms:.2f}ms")
    
    def log_iteration(self, iteration_num: int):
        """Log iteration number."""
        self.iterations = iteration_num
        logger.debug(f"[{self.query_id}] Iteration {iteration_num}")
    
    def end_query(self, success: bool, answer: Optional[str] = None):
        """Log end of query processing."""
        self.end_time = datetime.now().timestamp()
        total_time = (self.end_time - self.start_time) * 1000 if self.start_time else 0
        logger.info(f"[{self.query_id}] Query completed: Success={success}, Time={total_time:.2f}ms, Iterations={self.iterations}")
    
    def _summarize_output(self, output: Dict[str, Any]) -> str:
        """Create a summary of tool output."""
        if not output.get("success"):
            return f"Error: {output.get('error', 'Unknown error')}"
        
        if "rows" in output:
            return f"Retrieved {len(output['rows'])} rows"
        elif "sql" in output:
            return f"Generated SQL: {output['sql'][:100]}..."
        else:
            return "Completed successfully"
    
    def get_debug_info(self) -> Dict[str, Any]:
        """Get complete debug information."""
        return {
            "query_id": self.query_id,
            "iterations": self.iterations,
            "tool_calls": self.tool_calls,
            "agent_thoughts": self.agent_thoughts,
            "total_time_ms": (self.end_time - self.start_time) * 1000 if self.start_time and self.end_time else 0,
            "start_time": datetime.fromtimestamp(self.start_time).isoformat() if self.start_time else None,
            "end_time": datetime.fromtimestamp(self.end_time).isoformat() if self.end_time else None
        }
    
    def to_json(self) -> str:
        """Convert to JSON string."""
        return json.dumps(self.get_debug_info(), indent=2)

