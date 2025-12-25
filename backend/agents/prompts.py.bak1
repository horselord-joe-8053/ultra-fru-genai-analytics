"""
Prompts for the agent-based query system.
"""
from typing import Dict, Any, Optional, List


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

CRITICAL: Feedback Rating vs Sentiment Category:
- feedback_rating is INTEGER (1-10) - use for NUMERIC operations: AVG(feedback_rating), SUM, ranges (WHERE feedback_rating BETWEEN 8 AND 10)
- feedback_sentiment_category is TEXT ('Positive', 'Neutral', 'Negative') - use for CATEGORICAL operations: COUNT WHERE feedback_sentiment_category = 'Negative', filtering by sentiment
- For "how many negative/positive/neutral" queries → use feedback_sentiment_category, NOT feedback_rating
- For "average rating" queries → use AVG(feedback_rating) on the INTEGER column
- NEVER use feedback_rating with text comparisons like 'Negative' or 'Positive' - use feedback_sentiment_category instead

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
- Other columns: id, customer_id, brand, fridge_model, capacity_liters, sales_date, store_address, customer_feedback, feedback_rating, feedback_sentiment_category
- IMPORTANT: 
  - feedback_rating is INTEGER (1-10) - human-reviewed numeric satisfaction rating. Use for quantitative queries (AVG, SUM, ranges, etc.)
  - feedback_sentiment_category is TEXT (values: 'Positive', 'Neutral', 'Negative') - human-reviewed sentiment category. Use for categorical filtering and sentiment analysis.
  - Both fields are "man in the loop" labels (human-assigned, not auto-generated) representing ground truth for CUSTOMER_FEEDBACK text.
  - For "average rating" queries, use AVG(feedback_rating) on the numeric column.
  - For sentiment analysis, use feedback_sentiment_category for filtering and counting.

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


def get_synthesis_prompt(
    question: str,
    primary_sql_result: Optional[Dict[str, Any]] = None,
    primary_semantic_result: Optional[Dict[str, Any]] = None,
    context_results: List[Dict[str, Any]] = None,
) -> str:
    """
    Build synthesis prompt from the selected primary result (SQL or semantic_search) and optional context.

    The goal is to:
    - Ground the answer on the actual rows returned by execute_sql (for quantitative queries)
      OR semantic_search (for qualitative/RAG queries).
    - Optionally provide brief context from other successful tools.
    - Give very explicit instructions to avoid hallucinating store names or numbers.
    """
    if context_results is None:
        context_results = []

    sections: List[str] = []
    sections.append(f"User Question: {question}")
    sections.append("")

    # Primary result section (authoritative data)
    primary_result = primary_sql_result or primary_semantic_result
    result_type = "SQL" if primary_sql_result else ("Semantic Search" if primary_semantic_result else None)

    if primary_result:
        rows = primary_result.get("rows") or []
        row_count = primary_result.get("row_count", len(rows))

        sections.append(f"Primary {result_type} Result (authoritative data):")
        
        if primary_sql_result:
            # SQL-specific information
            columns = primary_sql_result.get("columns") or []
            sql = primary_sql_result.get("sql", "")
            if sql:
                sections.append("SQL:")
                sections.append(sql)
            sections.append(f"Columns: {columns}")
        else:
            # Semantic search result
            sections.append("Semantic search retrieved customer feedback records based on meaning similarity.")
            sections.append("These records contain actual customer feedback text from the database.")
        
        sections.append(f"Row count: {row_count}")

        if rows:
            # For semantic_search results, show more rows (20) to capture more feedback patterns
            # For SQL results, keep 10 rows (usually smaller result sets)
            max_rows_to_show = 20 if primary_semantic_result else 10
            rows_to_show = rows[:max_rows_to_show]
            
            if row_count > max_rows_to_show:
                sections.append(f"Rows (showing first {max_rows_to_show} of {row_count} total):")
            else:
                sections.append("Rows:")
            
            for idx, row in enumerate(rows_to_show, start=1):
                # Format row for readability
                if isinstance(row, dict):
                    # For semantic_search, highlight customer_feedback field
                    if primary_semantic_result and "customer_feedback" in row:
                        sections.append(f"{idx}) {row}")
                    else:
                        sections.append(f"{idx}) {row}")
                else:
                    sections.append(f"{idx}) {row}")
            
            # For semantic_search with many rows, add summary statistics
            if primary_semantic_result and row_count > max_rows_to_show:
                sections.append("")
                sections.append(f"Note: Showing {max_rows_to_show} of {row_count} total feedback entries.")
                sections.append("When synthesizing your answer, identify COMMON THEMES across all feedback,")
                sections.append("not just the individual examples shown above.")
                
                # Extract common themes from all rows (brands, models mentioned)
                if rows:
                    brands_mentioned = {}
                    models_mentioned = {}
                    for row in rows:
                        if isinstance(row, dict):
                            brand = row.get("brand", "")
                            model = row.get("fridge_model", "")
                            if brand:
                                brands_mentioned[brand] = brands_mentioned.get(brand, 0) + 1
                            if model:
                                models_mentioned[model] = models_mentioned.get(model, 0) + 1
                    
                    if brands_mentioned:
                        top_brands = sorted(brands_mentioned.items(), key=lambda x: x[1], reverse=True)[:5]
                        sections.append(f"Brands mentioned in feedback: {', '.join([f'{b} ({c})' for b, c in top_brands])}")
        else:
            sections.append("Rows: []  # No rows returned")
    else:
        sections.append(
            "Primary Result: NONE (no successful tool result with rows was found)."
        )

    # Optional context (how we got the data)
    if context_results:
        sections.append("")
        sections.append("Other successful tool results (context, not authoritative data):")
        for ctx in context_results:
            tool_name = ctx.get("tool", "unknown_tool")
            summary = ctx.get("summary", "")
            sections.append(f"- {tool_name}: {summary}")

    sections.append("")
    sections.append("Instructions for answering:")
    sections.append("- Base your answer ONLY on the concrete data in the 'Rows' above.")
    
    if primary_sql_result:
        sections.append(
            "- Do NOT invent new store names or numeric values that are not present in those rows."
        )
        sections.append(
            "- If row_count is 3, your answer should list exactly 3 stores with their sales values."
        )
    elif primary_semantic_result:
        sections.append(
            "- Use the actual customer_feedback text from the rows to answer the question."
        )
        sections.append(
            "- Identify COMMON THEMES and PATTERNS across all feedback entries (even if you only see a sample)."
        )
        sections.append(
            "- Group similar complaints or feedback into themes (e.g., 'noise issues', 'temperature problems')."
        )
        sections.append(
            "- Quote or paraphrase specific examples from the rows shown, but also summarize the overall patterns."
        )
        sections.append(
            "- If you see multiple similar complaints, mention that this is a recurring theme."
        )
        sections.append(
            "- If row_count is large (e.g., 50), your answer should reflect that this represents a significant pattern, not just isolated cases."
        )
    
    sections.append(
        "- If there are no rows, explicitly say you cannot answer from the available data and do NOT fabricate any information."
    )
    sections.append(
        "- Provide a clear, concise explanation and any insights you can derive from the rows."
    )

    return "\n".join(sections)

