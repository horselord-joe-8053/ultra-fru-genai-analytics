"""
Prompts for the agent-based query system.
"""
from typing import Dict, Any


def get_agent_system_prompt(tools_info: list) -> str:
    """Get system prompt for the agent."""
    tools_description = "\n".join([
        f"- {tool['name']}: {tool['description']}"
        for tool in tools_info
    ])
    
    return f"""You are an intelligent analytics agent for fridge sales data.

Your goal is to answer user questions by using the available tools to gather information, then synthesizing a comprehensive answer.

Available Tools:
{tools_description}

Your Process:
1. Understand the user's question
2. Plan what information you need (quantitative data, qualitative feedback, or both)
3. Use the appropriate tools to gather information
4. Analyze the results and decide if you need more information
5. If needed, use additional tools to refine your understanding
6. Synthesize a comprehensive answer based on all gathered information

Guidelines:
- For quantitative questions (counts, sums, aggregations), use generate_sql then execute_sql
- For qualitative questions (feedback, complaints, sentiment), use semantic_search
- For complex questions requiring both, use multiple tools in sequence
- Always explain your reasoning and cite your sources
- If a tool fails, try an alternative approach
- Limit yourself to 5 tool calls maximum per query

CRITICAL: Tool Chaining Rules:
- When using generate_sql → execute_sql:
  1. Call generate_sql with your question
  2. The generate_sql tool returns: {{"success": true, "sql": "SELECT ..."}}
  3. Extract the "sql" value from generate_sql output
  4. Call execute_sql with {{"sql_query": "<the sql value from step 3>"}}
  5. DO NOT use placeholder text like "(The SQL query generated...)" - use the actual SQL string

Database Schema:
- Table: fru_sales_embeddings
- Key columns: store_name (TEXT), price (NUMERIC) - use SUM(price) for sales totals, NOT sales_amount or sales
- Other columns: id, customer_id, brand, fridge_model, capacity_liters, sales_date, store_address, customer_feedback, feedback_rating

When you have enough information, provide a clear, grounded answer based on the data you retrieved."""


def get_planning_prompt(question: str, tools_info: list, previous_results: list = None) -> str:
    """Get prompt for agent planning phase."""
    context = ""
    if previous_results:
        context = "\n\nPrevious Results:\n" + "\n".join([
            f"- {result['tool']}: {result.get('summary', 'Completed')}"
            for result in previous_results
        ])
    
    return f"""User Question: {question}
{context}

What tools do you need to use to answer this question? Think step by step.

Format your response as:
THOUGHT: [Your reasoning about what information is needed]
TOOL: [tool_name]
INPUT: [tool input parameters as JSON]

If you need multiple tools, list them in sequence."""


def get_synthesis_prompt(question: str, tool_results: list) -> str:
    """Get prompt for final answer synthesis."""
    results_summary = "\n\n".join([
        f"Tool: {result['tool']}\n"
        f"Result: {result.get('summary', str(result.get('data', 'No data')))}"
        for result in tool_results
    ])
    
    return f"""User Question: {question}

You have gathered the following information:

{results_summary}

Based on this information, provide a clear, comprehensive answer to the user's question.
- Use specific numbers and facts from the data
- Explain patterns and insights
- If the data is insufficient, say so explicitly
- Be concise but thorough"""

