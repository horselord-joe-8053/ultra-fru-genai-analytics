"""
Structured logging for agent execution.

Applicable environment: [local] [aws {ecs | eks}] [azure {aci | aks}] [gcp {cloud-run | gke}]
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
                     output_data: Dict[str, Any], execution_time_ms: float,
                     iteration: int):
        """Log tool execution.
        
        Args:
            tool_name: Name of the tool being executed
            input_data: Input parameters for the tool
            output_data: Output from the tool execution
            execution_time_ms: Execution time in milliseconds
            iteration: Iteration number this tool call belongs to
        """
        # Preserve SQL in output for SQL-related tools
        output_dict = {
            "success": output_data.get("success", False),
            "summary": self._summarize_output(output_data),
            "error": output_data.get("error"),
            "row_count": output_data.get("row_count"),
            "execution_time_ms": execution_time_ms
        }
        # Preserve SQL field for SQL tools (needed for test result extraction)
        if "sql" in output_data:
            output_dict["sql"] = output_data["sql"]
        
        tool_call = {
            "tool": tool_name,
            "input": input_data,
            "output": output_dict,
            "timestamp": datetime.now().isoformat(),
            "iteration": iteration
        }
        self.tool_calls.append(tool_call)
        logger.info(f"[{self.query_id}] Tool: {tool_name}, Success: {tool_call['output']['success']}, Time: {execution_time_ms:.2f}ms, Iteration: {iteration}")
    
    def log_synthesis(self, question: str, primary_result_type: Optional[str],
                     primary_result_row_count: int, context_results: List[Dict],
                     final_answer: str, execution_time_ms: float,
                     token_usage: Dict[str, int]):
        """Log synthesis step as a pseudo-tool call.
        
        Args:
            question: The original question
            primary_result_type: Type of primary result ("sql", "semantic", or None)
            primary_result_row_count: Number of rows in primary result
            context_results: List of context results from other tools
            final_answer: The synthesized final answer
            execution_time_ms: Time taken for synthesis in milliseconds
            token_usage: Token usage dictionary with input_tokens, output_tokens, total_tokens
        """
        synthesis_call = {
            "tool": "pseudo_tool#llm_synthesize_answer",
            "input": {
                "question": question,
                "primary_result_type": primary_result_type,
                "primary_result_row_count": primary_result_row_count,
                "context_results_count": len(context_results)
            },
            "output": {
                "success": True,
                "answer": final_answer,
                "execution_time_ms": execution_time_ms,
                "token_usage": token_usage
            },
            "timestamp": datetime.now().isoformat(),
            "iteration": None
        }
        self.tool_calls.append(synthesis_call)
        logger.info(f"[{self.query_id}] Synthesis: Success=True, Time: {execution_time_ms:.2f}ms, Tokens: {token_usage.get('total_tokens', 0)}")
    
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
    
    def error(self, message: str):
        """Log an error message."""
        logger.error(f"[{self.query_id}] {message}")
    
    def warning(self, message: str):
        """Log a warning message."""
        logger.warning(f"[{self.query_id}] {message}")
    
    def info(self, message: str):
        """Log an info message."""
        logger.info(f"[{self.query_id}] {message}")
    
    def debug(self, message: str):
        """Log a debug message."""
        logger.debug(f"[{self.query_id}] {message}")

