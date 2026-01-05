"""
ReAct agent for autonomous query processing.

Applicable environment: [local] [aws {ecs | eks}] [azure {aci | aks}] [gcp {cloud-run | gke}]
"""
import json
import re
import time
import logging
from typing import Dict, Any, Optional, List, Callable
from decimal import Decimal
from datetime import datetime, date

from backend.llm.client_factory import claude_complete
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
    
    def process_query(self, question: str, progress_callback: Optional[Callable[[str, Dict[str, Any]], None]] = None) -> Dict[str, Any]:
        """
        Process a query using the agent.
        
        Args:
            question: User's natural language question
            progress_callback: Optional callback function(event_type: str, data: dict) called at key execution points
        
        Returns:
            Dict with answer, method, iterations, tool_calls, execution_time_ms, debug_info
        """
        start_time = time.time()
        logger = AgentLogger()
        logger.start_query(question)
        
        # Emit question event
        if progress_callback:
            progress_callback("question", {"question": question})
            progress_callback("method", {"method": "agentic"})
        
        tool_results: List[Dict[str, Any]] = []
        iteration = 0
        should_break_early = False
        max_iterations_exceeded = False
        all_data_retrieval_tools_successful = True  # Track if all data retrieval tools executed successfully (no errors)

        # Store current question for fallback parameter mapping
        self._current_question = question
        
        try:
            # Agent planning and execution loop
            while iteration < self.MAX_ITERATIONS:
                iteration += 1
                logger.log_iteration(iteration)
                
                # Check if this is the last iteration
                if iteration >= self.MAX_ITERATIONS:
                    max_iterations_exceeded = True
                
                # Emit iteration start event
                if progress_callback:
                    progress_callback("iteration_start", {"iteration": iteration})
                
                # Planning phase: Agent decides what to do
                logger.info(f"===== ITERATION {iteration} =====")
                logger.info(f"Planning phase: Generating tool calls for query: '{question}'")
                logger.info(f"Previous tool results: {len(tool_results)} result(s)")
                
                planning_prompt = get_planning_prompt(question, [], tool_results)
                planning_result = claude_complete(
                    system_prompt=self.system_prompt,
                    user_message=planning_prompt,
                    max_tokens=500
                )
                
                # Handle both dict (new format) and str (backward compatibility)
                if isinstance(planning_result, dict):
                    agent_response = planning_result.get("text", "")
                    tokens = planning_result.get("tokens", {})
                    if tokens.get("total", 0) > 0:
                        logger.debug(f"Planning tokens: input={tokens.get('input', 0)}, output={tokens.get('output', 0)}, total={tokens.get('total', 0)}")
                else:
                    agent_response = planning_result
                    tokens = {}
                
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
                    
                    # Emit tool_call_start event
                    if progress_callback:
                        progress_callback("tool_call_start", {
                            "iteration": iteration,
                            "tool": tool_name,
                            "input": tool_input
                        })
                    
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
                    logger.log_tool_call(tool_name, tool_input, tool_output, tool_time, iteration)
                    
                    # Emit tool_call_complete event (THIS IS KEY - streams immediately after each tool)
                    if progress_callback:
                        # Create summary for output
                        output_summary = {
                            "success": tool_output.get("success", False),
                            "summary": self._summarize_tool_result(tool_output),
                            "error": tool_output.get("error"),
                            "row_count": tool_output.get("row_count"),
                        }
                        # Preserve SQL if present
                        if "sql" in tool_output:
                            output_summary["sql"] = tool_output["sql"]
                        
                        progress_callback("tool_call_complete", {
                            "iteration": iteration,
                            "tool": tool_name,
                            "input": tool_input,
                            "output": output_summary,
                            "execution_time_ms": tool_time
                        })
                    
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
                        # Only track data retrieval tools (execute_sql, semantic_search)
                        if tool_name in ["execute_sql", "semantic_search"]:
                            all_data_retrieval_tools_successful = False
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
            
            # Check if we hit max iterations
            if iteration >= self.MAX_ITERATIONS:
                max_iterations_exceeded = True
            
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
                                iteration
                            )
                            
                            # Emit tool_call_complete event for auto-executed SQL
                            if progress_callback:
                                output_summary = {
                                    "success": auto_output.get("success", False),
                                    "summary": self._summarize_tool_result(auto_output),
                                    "error": auto_output.get("error"),
                                    "row_count": auto_output.get("row_count"),
                                }
                                if "sql" in auto_output:
                                    output_summary["sql"] = auto_output["sql"]
                                
                                progress_callback("tool_call_complete", {
                                    "iteration": iteration,
                                    "tool": "execute_sql",
                                    "input": {"sql_query": last_sql},
                                    "output": output_summary,
                                    "execution_time_ms": auto_time
                                })
                            
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
            
            # Track synthesis start time
            synthesis_start_time = time.time()
            
            # Emit synthesis_start event
            if progress_callback:
                progress_callback("synthesis_start", {})

            if tool_results:
                # Choose which tool outputs to feed into the synthesizer
                synthesis_inputs = self._select_synthesis_inputs(tool_results)
                primary_sql_result = synthesis_inputs.get("primary_sql_result")
                primary_semantic_result = synthesis_inputs.get("primary_semantic_result")
                context_results = synthesis_inputs.get("context_results", [])
                primary_result_type = None

                # Check if we have any successful data retrieval
                has_successful_data = (
                    (primary_sql_result and primary_sql_result.get("row_count", 0) > 0) or
                    (primary_semantic_result and primary_semantic_result.get("row_count", 0) > 0)
                )
                
                # Verify all_data_retrieval_tools_successful by checking actual tool results
                # This ensures we have the correct state even if tools were called in auto-execution
                if not has_successful_data and tool_results:
                    data_retrieval_tools = [r for r in tool_results if r.get("tool") in ["execute_sql", "semantic_search"]]
                    if data_retrieval_tools:
                        # Re-check: all data retrieval tools must have succeeded
                        all_data_retrieval_tools_successful = all(
                            r.get("output", {}).get("success", False) 
                            for r in data_retrieval_tools
                        )
                    else:
                        # No data retrieval tools were called, so we can't say "all successful"
                        all_data_retrieval_tools_successful = False
                
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
                        "[SYNTHESIS] ⚠️ NO DATA RETRIEVED - All tool executions failed. "
                        "Cannot generate grounded answer. Synthesis will proceed with explicit no-data instructions."
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
                # Increase max_tokens for synthesis to avoid truncation of complex answers
                # 2000 tokens should be sufficient for most synthesis tasks
                synthesis_result = claude_complete(
                    system_prompt=self.system_prompt,
                    user_message=synthesis_prompt,
                    max_tokens=2000,
                )
                
                # Handle both dict (new format) and str (backward compatibility)
                if isinstance(synthesis_result, dict):
                    final_answer = synthesis_result.get("text", "")
                    synthesis_tokens = synthesis_result.get("tokens", {})
                else:
                    final_answer = synthesis_result
                    synthesis_tokens = {}

                # Determine failure reason and generate appropriate message
                # ALWAYS replace answer when no successful data, regardless of LLM output
                if not has_successful_data:
                    import re
                    answer_lower = final_answer.lower()
                    
                    # Quick validation checks for logging
                    has_numeric = bool(re.search(r'\d+\.?\d+', final_answer))  # Any number with optional decimal
                    has_tool_format = bool(re.search(r'<generate_sql>|<execute_sql>|<semantic_search>', final_answer))
                    has_data_phrases = any(phrase in answer_lower for phrase in [
                        "based on query results", "according to the data", "the query results show",
                        "from the database", "the data indicates", "based on the information"
                    ])
                    
                    # Log if hallucination detected
                    if has_numeric or has_tool_format or has_data_phrases:
                        logger.warning(
                            f"[SYNTHESIS] ⚠️ Hallucination detected (numeric={has_numeric}, tool_format={has_tool_format}, data_phrases={has_data_phrases}). "
                            f"Replacing answer. Original: {final_answer[:200]}"
                        )
                    else:
                        logger.info(
                            f"[SYNTHESIS] No data found. Replacing LLM answer with appropriate message. "
                            f"Original: {final_answer[:200]}"
                        )
                    
                    # ALWAYS replace with appropriate message based on failure reason
                    # Priority: 1) No data found (if all tools successful), 2) Resource limits, 3) Tool failures
                    if all_data_retrieval_tools_successful:
                        # All data retrieval tools executed successfully but returned no data
                        # This takes priority over max_iterations_exceeded
                        final_answer = "No relevant data found for this query."
                    elif max_iterations_exceeded:
                        final_answer = (
                            "Search exceeded time and resource limit. Try again or contact your system admin to increase the limit."
                        )
                    else:
                        # Some tools failed
                        final_answer = (
                            "I cannot answer this question because I was unable to retrieve the required data from the database. "
                            "All attempts to query the database failed. Please try rephrasing your question or check if the data is available."
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
                
                # Log synthesis step as pseudo-tool call
                synthesis_time = (time.time() - synthesis_start_time) * 1000
                logger.log_synthesis(
                    question=question,
                    primary_result_type=primary_result_type,
                    primary_result_row_count=(
                        primary_sql_result.get("row_count", 0) if primary_sql_result
                        else (primary_semantic_result.get("row_count", 0) if primary_semantic_result else 0)
                    ),
                    context_results=context_results,
                    final_answer=final_answer,
                    execution_time_ms=synthesis_time,
                    token_usage=synthesis_tokens
                )
                
                # Emit synthesis step as tool_call_complete event for frontend
                if progress_callback:
                    progress_callback("tool_call_complete", {
                        "iteration": None,  # Synthesis doesn't belong to an iteration
                        "tool": "pseudo_tool#llm_synthesize_answer",
                        "input": {
                            "question": question,
                            "primary_result_type": primary_result_type,
                            "primary_result_row_count": (
                                primary_sql_result.get("row_count", 0) if primary_sql_result
                                else (primary_semantic_result.get("row_count", 0) if primary_semantic_result else 0)
                            ),
                            "context_results_count": len(context_results)
                        },
                        "output": {
                            "success": True,
                            "answer": final_answer,
                            "execution_time_ms": synthesis_time,
                            "token_usage": synthesis_tokens
                        },
                        "execution_time_ms": synthesis_time
                    })
            else:
                # No tool results at all
                has_successful_data = False
                primary_sql_result = None
                primary_semantic_result = None
                primary_result_type = None
                synthesis_tokens = {}
                synthesis_start_time = time.time()
                
                # Determine appropriate message based on failure reason
                # Priority: 1) No data found (if all tools successful), 2) Resource limits, 3) Tool failures
                if all_data_retrieval_tools_successful:
                    # All data retrieval tools executed successfully but returned no data
                    # This takes priority over max_iterations_exceeded
                    final_answer = "No relevant data found for this query."
                elif max_iterations_exceeded:
                    final_answer = (
                        "Search exceeded time and resource limit. Try again or contact your system admin to increase the limit."
                    )
                else:
                    # Some tools failed or no tools were executed
                    final_answer = (
                        "I cannot answer this question because I was unable to retrieve the required data from the database. "
                        "All attempts to query the database failed. Please try rephrasing your question or check if the data is available."
                    )
                
                # Log synthesis step even when no tool results
                synthesis_time = (time.time() - synthesis_start_time) * 1000
                logger.log_synthesis(
                    question=question,
                    primary_result_type=None,
                    primary_result_row_count=0,
                    context_results=[],
                    final_answer=final_answer,
                    execution_time_ms=synthesis_time,
                    token_usage={}
                )
                
                # Emit synthesis step as tool_call_complete event for frontend
                if progress_callback:
                    progress_callback("tool_call_complete", {
                        "iteration": None,
                        "tool": "pseudo_tool#llm_synthesize_answer",
                        "input": {
                            "question": question,
                            "primary_result_type": None,
                            "primary_result_row_count": 0,
                            "context_results_count": 0
                        },
                        "output": {
                            "success": True,
                            "answer": final_answer,
                            "execution_time_ms": synthesis_time,
                            "token_usage": {}
                        },
                        "execution_time_ms": synthesis_time
                    })
            
            execution_time = (time.time() - start_time) * 1000
            
            # Record metrics (include token usage from synthesis)
            agent_metrics.record_query(
                query_type="agentic",
                latency_ms=execution_time,
                iterations=iteration,
                success=True,
                input_tokens=synthesis_tokens.get("input", 0),
                output_tokens=synthesis_tokens.get("output", 0),
                total_tokens=synthesis_tokens.get("total", 0)
            )
            
            logger.end_query(success=True, answer=final_answer)
            
            # Determine primary result type for metadata (if not already set)
            if primary_result_type is None:
                if primary_sql_result:
                    primary_result_type = "sql"
                elif primary_semantic_result:
                    primary_result_type = "semantic"
            
            result = {
                "answer": final_answer,
                "method": "agentic",
                "iterations": iteration,
                "tool_calls": logger.tool_calls,
                "execution_time_ms": execution_time,
                "debug_info": logger.get_debug_info(),
                "token_usage": {
                    "input_tokens": synthesis_tokens.get("input", 0),
                    "output_tokens": synthesis_tokens.get("output", 0),
                    "total_tokens": synthesis_tokens.get("total", 0)
                },
                # Add metadata about data availability
                "data_available": has_successful_data,
                "primary_result_type": primary_result_type,  # "sql", "semantic", or None
                "primary_result_row_count": (
                    primary_sql_result.get("row_count", 0) if primary_sql_result
                    else (primary_semantic_result.get("row_count", 0) if primary_semantic_result else 0)
                ),
            }
            
            # Emit complete event
            if progress_callback:
                progress_callback("complete", {
                    "iterations": iteration,
                    "execution_time_ms": execution_time,
                    "token_usage": result["token_usage"],
                    "answer": final_answer
                })
            
            return result
        
        except Exception as e:
            execution_time = (time.time() - start_time) * 1000
            error_msg = f"Agent processing failed: {str(e)}"
            logger.error(f"Agent error: {error_msg}", exc_info=True)
            
            agent_metrics.record_query(
                query_type="error",
                latency_ms=execution_time,
                iterations=iteration,
                success=False
            )
            
            logger.end_query(success=False)
            
            # Emit error event if callback is available
            if progress_callback:
                progress_callback("error", {"message": error_msg})
            
            return {
                "answer": "An error has occurred while processing your query. Please contact your system admin.",
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
    
    def _json_safe_rows(self, rows: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
        """
        Convert rows to JSON-serializable format.
        
        Handles Decimal, datetime, and date types that aren't JSON-serializable.
        """
        def _json_safe_value(value: Any) -> Any:
            """Convert a single value to JSON-serializable form."""
            if isinstance(value, Decimal):
                return float(value)
            if isinstance(value, (datetime, date)):
                return value.isoformat()
            if isinstance(value, list):
                return [_json_safe_value(v) for v in value]
            if isinstance(value, dict):
                return {k: _json_safe_value(v) for k, v in value.items()}
            return value
        
        return [{k: _json_safe_value(v) for k, v in row.items()} for row in rows]

