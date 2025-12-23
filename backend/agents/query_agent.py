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
                    "customer_id": "TEXT",
                    "brand": "TEXT",
                    "fridge_model": "TEXT",
                    "capacity_liters": "NUMERIC",
                    "price": "NUMERIC",
                    "sales_date": "DATE",
                    "store_name": "TEXT",
                    "store_address": "TEXT",
                    "customer_feedback": "TEXT",
                    "feedback_rating": "INTEGER",
                    "feedback_sentiment_category": "TEXT",
                    "embedding": "VECTOR(1536)"
                }
            }
        self.schema_info = schema_info
        
        # Initialize tools
        self.tools = {
            "execute_sql": SQLTool(db_pool),
            "semantic_search": SemanticSearchTool(db_pool, openai_client, schema_info),
            "generate_sql": SQLGeneratorTool(bedrock_client, schema_info)
        }
        
        # Build system prompt with tool info
        tools_info = [tool.get_info() for tool in self.tools.values()]
        self.system_prompt = get_agent_system_prompt(tools_info)

    def _select_synthesis_inputs(self, tool_results: List[Dict[str, Any]]) -> Dict[str, Any]:
        """
        Select the primary result and optional context results for synthesis.

        Priority:
        1. execute_sql result with rows (for quantitative queries)
        2. semantic_search result with rows (for qualitative/RAG queries)
        3. generate_sql result (as context only)

        - Primary result: last successful execute_sql with row_count > 0, OR
                          last successful semantic_search with row_count > 0 (if no SQL result)
        - Context results: other successful tool calls for additional context
        """
        primary_sql_output: Optional[Dict[str, Any]] = None
        primary_semantic_output: Optional[Dict[str, Any]] = None
        last_generate_sql: Optional[Dict[str, Any]] = None
        last_semantic_search: Optional[Dict[str, Any]] = None

        for result in tool_results:
            tool_name = result.get("tool")
            output = result.get("output", {}) or {}

            if not output.get("success"):
                continue

            if tool_name == "execute_sql" and output.get("row_count", 0) > 0:
                # Keep the last successful execute_sql with rows as primary
                primary_sql_output = output
            elif tool_name == "semantic_search":
                last_semantic_search = result
                # Use semantic_search as primary if it has rows and no SQL result exists
                if output.get("row_count", 0) > 0:
                    primary_semantic_output = output
            elif tool_name == "generate_sql":
                last_generate_sql = result

        # Determine primary result: SQL takes precedence, but use semantic_search if no SQL
        primary_result = primary_sql_output if primary_sql_output else primary_semantic_output
        primary_result_type = "sql" if primary_sql_output else ("semantic" if primary_semantic_output else None)

        context_results: List[Dict[str, Any]] = []
        # Add other successful tools as context
        if last_generate_sql and not primary_sql_output:
            # Only include generate_sql as context if we're not using its SQL result
            context_results.append({
                "tool": last_generate_sql.get("tool"),
                "summary": last_generate_sql.get("summary", ""),
            })
        if last_semantic_search and primary_result_type == "sql":
            # Include semantic_search as context if we're using SQL as primary
            context_results.append({
                "tool": last_semantic_search.get("tool"),
                "summary": last_semantic_search.get("summary", ""),
            })

        return {
            "primary_sql_result": primary_result if primary_result_type == "sql" else None,
            "primary_semantic_result": primary_result if primary_result_type == "semantic" else None,
            "context_results": context_results,
        }
    
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
        
        tool_results: List[Dict[str, Any]] = []
        iteration = 0
        should_break_early = False

        # Store current question for fallback parameter mapping
        self._current_question = question
        
        try:
            # Agent planning and execution loop
            while iteration < self.MAX_ITERATIONS:
                iteration += 1
                logger.log_iteration(iteration)
                
                # Planning phase: Agent decides what to do
                logger.info(f"===== ITERATION {iteration} =====")
                logger.info(f"Planning phase: Generating tool calls for query: '{question}'")
                logger.info(f"Previous tool results: {len(tool_results)} result(s)")
                
                planning_prompt = get_planning_prompt(question, [], tool_results)
                agent_response = claude_complete(
                    system_prompt=self.system_prompt,
                    user_message=planning_prompt,
                    max_tokens=500
                )
                
                logger.log_thought(agent_response)
                logger.info(f"Agent response (planning): {agent_response[:200]}...")
                
                # Parse agent response to extract tool calls
                tool_calls = self._parse_agent_response(agent_response)
                logger.info(f"Parsed {len(tool_calls)} tool call(s) from agent response")
                
                if not tool_calls:
                    # Agent thinks it's done
                    logger.info(f"✅ No more tool calls - agent thinks it's done. Proceeding to synthesis.")
                    break
                
                # Execute tools
                last_tool_name: Optional[str] = None
                last_tool_output: Optional[Dict[str, Any]] = None
                for tool_call in tool_calls:
                    tool_name = tool_call.get("tool")
                    tool_input = tool_call.get("input", {})
                    last_tool_name = tool_name
                    
                    logger.info(f"--- Executing tool: {tool_name} ---")
                    logger.info(f"Tool input (raw): {tool_input}")
                    
                    if tool_name not in self.tools:
                        logger.warning(f"Unknown tool: {tool_name}")
                        continue
                    
                    # Execute tool
                    tool = self.tools[tool_name]
                    tool_start = time.time()
                    
                    # Normalize parameter names for tool execution
                    normalized_input = self._normalize_tool_input(tool_name, tool_input)

                    # Auto-extract SQL from previous generate_sql results if execute_sql is called without SQL
                    if tool_name == "execute_sql":
                        has_sql = normalized_input.get("sql_query") or normalized_input.get("sql")
                        if not has_sql or (
                            isinstance(has_sql, str)
                            and has_sql.lower().startswith(
                                ("(the sql", "the sql query", "[the sql")
                            )
                        ):
                            # Look for SQL from previous generate_sql tool results
                            logger.info(
                                "🔗 execute_sql called without valid SQL. Searching previous tool results..."
                            )
                            for prev_result in reversed(tool_results):  # Check most recent first
                                if prev_result.get("tool") == "generate_sql":
                                    prev_output = prev_result.get("output", {}) or {}
                                    if prev_output.get("success") and "sql" in prev_output:
                                        sql = prev_output["sql"]
                                        logger.info("✅ Found SQL from previous generate_sql result")
                                        logger.info(f"   Extracted SQL: {sql[:200]}...")
                                        normalized_input["sql_query"] = sql
                                        break
                            else:
                                logger.warning(
                                    "⚠️  No SQL found in previous tool results. execute_sql will likely fail."
                                )

                    logger.info(f"Tool input (normalized): {normalized_input}")
                    
                    tool_output = tool.execute(**normalized_input)
                    tool_time = (time.time() - tool_start) * 1000
                    last_tool_output = tool_output
                    
                    logger.info(f"Tool execution result: Success={tool_output.get('success', False)}, Time={tool_time:.2f}ms")
                    if tool_output.get('success'):
                        if 'row_count' in tool_output:
                            logger.info(f"  Rows returned: {tool_output.get('row_count', 0)}")
                        if 'sql' in tool_output:
                            logger.info(f"  SQL executed: {tool_output.get('sql', '')[:200]}...")
                    else:
                        logger.warning(f"  Error: {tool_output.get('error', 'Unknown error')}")
                    
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
                    else:
                        # If SQL execution succeeded with results, we can break early
                        if tool_name == "execute_sql" and tool_output.get("success") and tool_output.get("row_count", 0) > 0:
                            logger.info(f"✅ SQL execution succeeded with {tool_output.get('row_count')} rows. Breaking loop to proceed to synthesis.")
                            should_break_early = True
                            break
                
                # Break out of while loop if we broke from tool execution
                if should_break_early:
                    logger.info(f"✅ Early break triggered - SQL execution succeeded. Stopping iterations.")
                    break
                
                # Also check if we have successful SQL results from any previous iteration
                has_successful_sql = any(
                    r.get("tool") == "execute_sql" and 
                    r.get("output", {}).get("success") and 
                    r.get("output", {}).get("row_count", 0) > 0
                    for r in tool_results
                )
                if has_successful_sql:
                    logger.info(f"✅ Found successful SQL execution in tool results. Stopping iterations to proceed to synthesis.")
                    break
            
            # After planning loop, ensure we have executed SQL if SQL was generated
            has_successful_sql = any(
                r.get("tool") == "execute_sql"
                and r.get("output", {}).get("success")
                and r.get("output", {}).get("row_count", 0) > 0
                for r in tool_results
            )

            if not has_successful_sql:
                # Look for the last successful generate_sql result with an SQL string
                last_sql: Optional[str] = None
                for r in reversed(tool_results):
                    if r.get("tool") == "generate_sql":
                        out = r.get("output", {}) or {}
                        if out.get("success") and "sql" in out:
                            last_sql = out["sql"]
                            break

                if last_sql:
                    logger.info(
                        "[AUTO] No successful execute_sql found; running execute_sql "
                        "with SQL from last generate_sql result."
                    )
                    tool = self.tools.get("execute_sql")
                    if tool is not None:
                        auto_start = time.time()
                        try:
                            auto_output = tool.execute(sql_query=last_sql)
                            auto_time = (time.time() - auto_start) * 1000

                            logger.info(
                                f"[AUTO] execute_sql result: "
                                f"Success={auto_output.get('success', False)}, "
                                f"Rows={auto_output.get('row_count', 0)}, "
                                f"Time={auto_time:.2f}ms"
                            )

                            # Log tool call and record metrics
                            logger.log_tool_call(
                                "execute_sql",
                                {"sql_query": last_sql},
                                auto_output,
                                auto_time,
                            )
                            agent_metrics.record_tool_call(
                                "execute_sql",
                                auto_time,
                                auto_output.get("success", False),
                            )

                            tool_results.append(
                                {
                                    "tool": "execute_sql",
                                    "input": {"sql_query": last_sql},
                                    "output": auto_output,
                                    "summary": self._summarize_tool_result(auto_output),
                                }
                            )
                        except Exception as e:
                            logger.error(
                                f"[AUTO] execute_sql failed with auto-generated SQL: {e}",
                                exc_info=True,
                            )

            # Synthesis phase: Generate final answer
            logger.info("===== SYNTHESIS PHASE =====")
            logger.info(f"Tool results collected: {len(tool_results)} result(s)")

            if tool_results:
                # Choose which tool outputs to feed into the synthesizer
                synthesis_inputs = self._select_synthesis_inputs(tool_results)
                primary_sql_result = synthesis_inputs.get("primary_sql_result")
                primary_semantic_result = synthesis_inputs.get("primary_semantic_result")
                context_results = synthesis_inputs.get("context_results", [])

                if primary_sql_result:
                    logger.info(
                        "[SYNTHESIS] Using primary SQL result with "
                        f"{primary_sql_result.get('row_count', len(primary_sql_result.get('rows', []) or []))} rows."
                    )
                elif primary_semantic_result:
                    logger.info(
                        "[SYNTHESIS] Using primary semantic search result with "
                        f"{primary_semantic_result.get('row_count', len(primary_semantic_result.get('rows', []) or []))} rows."
                    )
                else:
                    logger.warning(
                        "[SYNTHESIS] No primary result found. Synthesis will proceed without authoritative rows."
                    )

                if context_results:
                    logger.info(
                        f"[SYNTHESIS] Context results available from tools: "
                        f"{[c.get('tool') for c in context_results]}"
                    )

                synthesis_prompt = get_synthesis_prompt(
                    question=question,
                    primary_sql_result=primary_sql_result,
                    primary_semantic_result=primary_semantic_result,
                    context_results=context_results,
                )

                logger.info("[SYNTHESIS] ===== GENERATING FINAL ANSWER =====")
                logger.info(f"[SYNTHESIS] Question: '{question}'")
                logger.info(
                    f"[SYNTHESIS] Synthesis prompt (first 1000 chars): {synthesis_prompt[:1000]}..."
                )
                if len(synthesis_prompt) > 1000:
                    logger.info(
                        f"[SYNTHESIS] ... (prompt truncated, total length: {len(synthesis_prompt)} chars)"
                    )

                logger.info("[SYNTHESIS] Calling LLM for final answer synthesis...")
                final_answer = claude_complete(
                    system_prompt=self.system_prompt,
                    user_message=synthesis_prompt,
                    max_tokens=1000,
                )

                logger.info("[SYNTHESIS] ===== FINAL ANSWER GENERATED =====")
                logger.info(f"[SYNTHESIS] Final answer length: {len(final_answer)} chars")
                logger.info("[SYNTHESIS] Final answer (FULL TEXT):")
                logger.info(f"[SYNTHESIS] {'='*80}")
                # Log answer in chunks to avoid truncation
                for i, line in enumerate(final_answer.split("\n"), 1):
                    logger.info(f"[SYNTHESIS] {line}")
                if "\n" not in final_answer:
                    # If no newlines, log the whole thing
                    logger.info(f"[SYNTHESIS] {final_answer}")
                logger.info(f"[SYNTHESIS] {'='*80}")
            else:
                final_answer = (
                    "I couldn't gather enough information to answer your question. "
                    "Please try rephrasing it."
                )
            
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
    
    def _normalize_tool_input(self, tool_name: str, tool_input: Dict[str, Any]) -> Dict[str, Any]:
        """Normalize tool input parameters to match tool signatures."""
        normalized = tool_input.copy()
        
        # Map common parameter names to tool-specific names
        if tool_name == "semantic_search":
            # Map "question" or "query" to "query_text"
            if "question" in normalized and "query_text" not in normalized:
                normalized["query_text"] = normalized.pop("question")
            elif "query" in normalized and "query_text" not in normalized:
                normalized["query_text"] = normalized.pop("query")
            
            # Fallback: if query_text is still missing, use the original question
            # This handles cases where LLM doesn't provide proper parameters
            if "query_text" not in normalized and hasattr(self, '_current_question'):
                normalized["query_text"] = self._current_question
            
            # Convert filter parameters to filters dict
            # semantic_search expects: filters={"store_name": ["value"]}
            # But agent may pass: store_name="value"
            # Derive filterable columns from schema_info (TEXT columns, excluding id and embedding)
            filters = normalized.get("filters", {})
            if not isinstance(filters, dict):
                filters = {}
            
            # Get filterable columns from schema_info
            # Filterable columns are TEXT columns (excluding id, embedding, customer_feedback, and other non-filterable fields)
            # Note: customer_feedback is the column being searched semantically, not filtered
            filterable_columns = set()
            if self.schema_info and "columns" in self.schema_info:
                excluded_columns = {
                    "id",           # Primary key
                    "embedding",    # Vector column (searched, not filtered)
                    "customer_feedback"  # This is the text column being searched semantically, not filtered
                }
                for col_name, col_type in self.schema_info["columns"].items():
                    # Include TEXT columns that aren't excluded
                    if col_name not in excluded_columns and "TEXT" in str(col_type).upper():
                        filterable_columns.add(col_name)
            
            # Convert direct filter parameters to filters dict format
            for filter_key in filterable_columns:
                if filter_key in normalized and filter_key not in filters:
                    filter_value = normalized.pop(filter_key)
                    # Convert single value to list if needed
                    if isinstance(filter_value, str):
                        filters[filter_key] = [filter_value]
                    elif isinstance(filter_value, list):
                        filters[filter_key] = filter_value
                    else:
                        filters[filter_key] = [str(filter_value)]
            
            if filters:
                normalized["filters"] = filters
        
        elif tool_name == "execute_sql":
            # Map "sql_query" or "query" to "sql"
            if "sql_query" in normalized and "sql" not in normalized:
                normalized["sql"] = normalized.pop("sql_query")
            elif "query" in normalized and "sql" not in normalized:
                normalized["sql"] = normalized.pop("query")
        
        elif tool_name == "generate_sql":
            # Map "query" to "question"
            if "query" in normalized and "question" not in normalized:
                normalized["question"] = normalized.pop("query")
        
        return normalized
    
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

