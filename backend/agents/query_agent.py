"""
ReAct agent for autonomous query processing.
"""
import json
import re
import time
import logging
from typing import Dict, Any, Optional, List

from backend.llm.bedrock_client import claude_complete
from .tools import SQLTool, SemanticSearchTool, SQLGeneratorTool
from .logger import AgentLogger
from .metrics import agent_metrics
from .prompts import get_agent_system_prompt, get_planning_prompt, get_synthesis_prompt

logger = logging.getLogger(__name__)


class QueryAgent:
    """ReAct agent for processing queries autonomously."""
    
    MAX_ITERATIONS = 5
    
    def __init__(self, db_pool, bedrock_client, openai_client, schema_info: Optional[Dict[str, Any]] = None):
        """
        Initialize agent.
        
        Args:
            db_pool: Database connection pool
            bedrock_client: AWS Bedrock client
            openai_client: OpenAI client
            schema_info: Database schema information
        """
        self.db_pool = db_pool
        self.bedrock_client = bedrock_client
        self.openai_client = openai_client
        
        # Default schema info
        if schema_info is None:
            schema_info = {
                "table": "fru_sales_embeddings",
                "columns": {
                    "id": "TEXT PRIMARY KEY",
                    "brand": "TEXT",
                    "fridge_model": "TEXT",
                    "price": "NUMERIC",
                    "sales_date": "DATE",
                    "store_name": "TEXT",
                    "store_address": "TEXT",
                    "customer_feedback": "TEXT",
                    "feedback_rating": "TEXT",
                    "embedding": "VECTOR(1536)"
                }
            }
        self.schema_info = schema_info
        
        # Initialize tools
        self.tools = {
            "execute_sql": SQLTool(db_pool),
            "semantic_search": SemanticSearchTool(db_pool, openai_client),
            "generate_sql": SQLGeneratorTool(bedrock_client, schema_info)
        }
        
        # Build system prompt with tool info
        tools_info = [tool.get_info() for tool in self.tools.values()]
        self.system_prompt = get_agent_system_prompt(tools_info)
    
    def process_query(self, question: str) -> Dict[str, Any]:
        """
        Process a query using the agent.
        
        Args:
            question: User's natural language question
        
        Returns:
            Dict with answer, method, iterations, tool_calls, execution_time_ms, debug_info
        """
        start_time = time.time()
        logger = AgentLogger()
        logger.start_query(question)
        
        tool_results = []
        iteration = 0
        
        try:
            # Agent planning and execution loop
            while iteration < self.MAX_ITERATIONS:
                iteration += 1
                logger.log_iteration(iteration)
                
                # Planning phase: Agent decides what to do
                planning_prompt = get_planning_prompt(question, [], tool_results)
                agent_response = claude_complete(
                    system_prompt=self.system_prompt,
                    user_message=planning_prompt,
                    max_tokens=500
                )
                
                logger.log_thought(agent_response)
                
                # Parse agent response to extract tool calls
                tool_calls = self._parse_agent_response(agent_response)
                
                if not tool_calls:
                    # Agent thinks it's done
                    break
                
                # Execute tools
                for tool_call in tool_calls:
                    tool_name = tool_call.get("tool")
                    tool_input = tool_call.get("input", {})
                    
                    if tool_name not in self.tools:
                        logger.warning(f"Unknown tool: {tool_name}")
                        continue
                    
                    # Execute tool
                    tool = self.tools[tool_name]
                    tool_start = time.time()
                    tool_output = tool.execute(**tool_input)
                    tool_time = (time.time() - tool_start) * 1000
                    
                    # Log tool call
                    logger.log_tool_call(tool_name, tool_input, tool_output, tool_time)
                    
                    # Record metrics
                    agent_metrics.record_tool_call(tool_name, tool_time, tool_output.get("success", False))
                    
                    # Store result
                    tool_results.append({
                        "tool": tool_name,
                        "input": tool_input,
                        "output": tool_output,
                        "summary": self._summarize_tool_result(tool_output)
                    })
                    
                    # If tool failed, agent might want to try alternative
                    if not tool_output.get("success"):
                        logger.log_thought(f"Tool {tool_name} failed: {tool_output.get('error')}")
            
            # Synthesis phase: Generate final answer
            if tool_results:
                synthesis_prompt = get_synthesis_prompt(question, tool_results)
                final_answer = claude_complete(
                    system_prompt=self.system_prompt,
                    user_message=synthesis_prompt,
                    max_tokens=1000
                )
            else:
                final_answer = "I couldn't gather enough information to answer your question. Please try rephrasing it."
            
            execution_time = (time.time() - start_time) * 1000
            
            # Record metrics
            agent_metrics.record_query(
                query_type="agentic",
                latency_ms=execution_time,
                iterations=iteration,
                success=True
            )
            
            logger.end_query(success=True, answer=final_answer)
            
            return {
                "answer": final_answer,
                "method": "agentic",
                "iterations": iteration,
                "tool_calls": logger.tool_calls,
                "execution_time_ms": execution_time,
                "debug_info": logger.get_debug_info()
            }
        
        except Exception as e:
            execution_time = (time.time() - start_time) * 1000
            error_msg = f"Agent processing failed: {str(e)}"
            logger.error(f"Agent error: {error_msg}")
            
            agent_metrics.record_query(
                query_type="error",
                latency_ms=execution_time,
                iterations=iteration,
                success=False
            )
            
            logger.end_query(success=False)
            
            return {
                "answer": "I encountered an error while processing your query. Please try again.",
                "method": "agentic",
                "error": error_msg,
                "iterations": iteration,
                "execution_time_ms": execution_time,
                "debug_info": logger.get_debug_info()
            }
    
    def _parse_agent_response(self, response: str) -> List[Dict[str, Any]]:
        """Parse agent response to extract tool calls."""
        tool_calls = []
        
        # Look for TOOL: and INPUT: patterns
        tool_pattern = r'TOOL:\s*(\w+)'
        input_pattern = r'INPUT:\s*(\{.*?\})'
        
        tools = re.findall(tool_pattern, response, re.IGNORECASE)
        inputs = re.findall(input_pattern, response, re.DOTALL)
        
        for i, tool_name in enumerate(tools):
            tool_input = {}
            if i < len(inputs):
                try:
                    tool_input = json.loads(inputs[i])
                except json.JSONDecodeError:
                    # Try to extract simple parameters
                    tool_input = self._extract_simple_input(inputs[i])
            
            tool_calls.append({
                "tool": tool_name.lower(),
                "input": tool_input
            })
        
        return tool_calls
    
    def _extract_simple_input(self, input_str: str) -> Dict[str, Any]:
        """Extract simple key-value pairs from input string."""
        result = {}
        # Look for common patterns like "question: ..." or "query_text: ..."
        patterns = [
            (r'question["\']?\s*:\s*["\']?([^"\']+)', "question"),
            (r'query_text["\']?\s*:\s*["\']?([^"\']+)', "query_text"),
            (r'sql["\']?\s*:\s*["\']?([^"\']+)', "sql"),
            (r'limit["\']?\s*:\s*(\d+)', "limit"),
        ]
        
        for pattern, key in patterns:
            match = re.search(pattern, input_str, re.IGNORECASE)
            if match:
                result[key] = match.group(1).strip()
        
        return result
    
    def _summarize_tool_result(self, result: Dict[str, Any]) -> str:
        """Create a summary of tool result for agent."""
        if not result.get("success"):
            return f"Error: {result.get('error', 'Unknown error')}"
        
        if "rows" in result:
            return f"Retrieved {result.get('row_count', 0)} rows"
        elif "sql" in result:
            return f"Generated SQL query"
        else:
            return "Completed successfully"

