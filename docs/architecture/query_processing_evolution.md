# Query Processing Evolution: Current → Enhancement_A → B → C

This document describes the evolution of the query processing system in FRU, from the initial implementation to the agent-based autonomous system.

---

## Current Implementation

### Architecture
- **Classification**: Simple keyword-based (`is_qualitative()` function)
- **Query Processing**: Single path - pgvector semantic search only
- **Limitations**:
  - All queries default to semantic search over feedback data
  - Quantitative queries (e.g., "which region has biggest sales?") perform poorly
  - No SQL generation capability
  - Fixed execution path

### Flow
```
User Query → Keyword Check → pgvector Search → Stats → Claude Explanation
```

### Example Problem
Query: "Which region has the biggest sales?"
- Current: Searches feedback semantically, returns 50 records
- Problem: Doesn't aggregate all sales data, only samples
- Result: Inaccurate or incomplete answer

---

## Enhancement_A: LLM Classification + SQL Generation

### What It Adds
- **LLM-based classification**: Claude/Bedrock classifies queries as `quantitative`, `qualitative`, or `hybrid`
- **SQL generation**: LLM generates SQL from natural language for quantitative queries
- **Dual execution paths**: Different handling for quantitative vs qualitative queries

### Architecture
```
User Query → LLM Classify → Route Decision
                │
    ┌───────────┴───────────┐
    │                       │
Quantitative          Qualitative
    │                       │
LLM Generate SQL    pgvector Search
    │                       │
Execute SQL         Claude Explain
    │                       │
Claude Explain      Return Answer
    │
Return Answer
```

### Benefits
- **Accurate quantitative queries**: SQL aggregations over full dataset
- **Maintains qualitative strength**: Still uses pgvector for feedback queries
- **Schema-aware**: LLM receives table structure for accurate SQL generation

### Example
Query: "Which region has the biggest sales?"
1. LLM classifies as `quantitative`
2. LLM generates: `SELECT store_address, SUM(price) FROM ... GROUP BY store_address ORDER BY SUM(price) DESC LIMIT 1`
3. Execute SQL → Get accurate result
4. Claude explains the result

---

## Enhancement_B: Hybrid Query Processing

### What It Adds
- **Two-phase execution**: Quantitative analysis first, then qualitative analysis filtered by results
- **Result fusion**: Combines quantitative metrics with qualitative insights
- **Coordinated execution**: SQL results guide semantic search

### Architecture
```
User Query → Classify as "hybrid"
    │
    ├─ Phase 1: Quantitative
    │   └─ Generate & Execute SQL → Get low-sales stores
    │
    ├─ Phase 2: Qualitative (Filtered)
    │   └─ Semantic Search (filtered by SQL results) → Get feedback
    │
    └─ Phase 3: Synthesis
        └─ Claude combines both → Generate recommendations
```

### Benefits
- **Handles complex queries**: "How to improve sales where sales were low?"
- **Efficient**: Only searches relevant subset (low-sales stores)
- **Actionable**: Combines data with insights for recommendations

### Example
Query: "How to improve sales where sales were low?"
1. **Phase 1**: SQL finds stores with below-average sales → ["Store A", "Store B"]
2. **Phase 2**: Semantic search for feedback ONLY from Store A and Store B
3. **Phase 3**: Claude synthesizes: "Store A and B have low sales. Common issues: delivery delays, poor service. Recommendations: ..."

---

## Enhancement_C: Agent-Based Autonomous Planning

### What It Adds
- **Autonomous planning**: LLM decides what analysis is needed
- **Tool-based execution**: Agent uses tools (SQL, semantic search, SQL generation)
- **Iterative refinement**: Agent can iterate multiple times based on results
- **Dynamic adaptation**: Adapts to novel queries without fixed patterns

### Architecture
```
User Query → Agent Planning
    │
    ├─ Agent thinks: "What do I need?"
    │   └─ Plans tool sequence
    │
    ├─ Execute Tool 1 (e.g., SQL)
    │   └─ Agent observes results
    │
    ├─ Agent decides: "Do I need more?"
    │   └─ If yes → Execute Tool 2 (e.g., Semantic Search)
    │
    └─ Agent synthesizes final answer
```

### Available Tools
1. **`execute_sql`**: Run SQL queries directly
2. **`semantic_search`**: pgvector search with optional filters
3. **`generate_sql`**: LLM generates SQL from natural language

### Benefits
- **Autonomous**: LLM decides approach, not hardcoded logic
- **Flexible**: Adapts to novel query patterns
- **Iterative**: Can refine based on intermediate results
- **Extensible**: Easy to add new tools

### Example Scenarios

**Scenario 1: Simple Quantitative**
```
Query: "Which region has biggest sales?"
Agent: "I need SQL aggregation" → execute_sql → Done
```

**Scenario 2: Simple Qualitative**
```
Query: "Why are customers unhappy?"
Agent: "I need semantic search" → semantic_search → Done
```

**Scenario 3: Complex Multi-Step**
```
Query: "Compare customer satisfaction between high-sales and low-sales regions"
Agent:
  1. execute_sql → Find high/low sales regions
  2. semantic_search → Get feedback from high-sales regions
  3. semantic_search → Get feedback from low-sales regions
  4. Compare patterns → Synthesize answer
```

**Scenario 4: Iterative Refinement**
```
Query: "What's causing low sales in the Midwest?"
Agent:
  1. execute_sql → Find Midwest stores with low sales
  2. semantic_search → Get feedback from those stores
  3. Agent observes: "Most complaints are about delivery"
  4. Agent decides: "I need more specific delivery data"
  5. execute_sql → Analyze delivery dates vs sales dates
  6. Synthesize comprehensive answer
```

---

## Migration Path

### Incremental Implementation
1. **Phase 1**: Implement Enhancement_A (LLM classification + SQL generation)
   - Test with quantitative queries
   - Keep existing endpoint as fallback

2. **Phase 2**: Implement Enhancement_B (Hybrid processing)
   - Test with hybrid queries
   - Integrate with Enhancement_A

3. **Phase 3**: Implement Enhancement_C (Agent-based)
   - Build tool infrastructure
   - Implement ReAct agent
   - Add comprehensive logging

### Testing Strategy
- **Unit tests**: Each tool independently
- **Integration tests**: Agent with mocked tools
- **End-to-end tests**: Full API flow
- **A/B testing**: Compare agent vs current implementation

### Rollback Plan
- Feature flag: `USE_AGENT_QUERY=false` (default)
- Gradual rollout: Percentage-based or user whitelist
- Monitoring: Track latency, accuracy, errors
- Fallback: Original `/query` endpoint always available

---

## Performance Considerations

### Latency
- **Current**: ~500-800ms (single pgvector search)
- **Enhancement_A**: ~800-1200ms (LLM classification + SQL generation)
- **Enhancement_B**: ~1200-2000ms (two-phase execution)
- **Enhancement_C**: ~1500-3000ms (multiple tool calls, iterations)

### Cost
- **Current**: OpenAI embeddings + Bedrock (1 call)
- **Enhancement_A**: +1 Bedrock call (classification/SQL generation)
- **Enhancement_B**: +1 Bedrock call (synthesis)
- **Enhancement_C**: +2-5 Bedrock calls (planning + tool calls + synthesis)

### Optimization Strategies
- Cache common SQL queries
- Batch tool executions when possible
- Use Claude Haiku for planning, Sonnet for synthesis
- Limit agent iterations (max 5 steps)

---

## Future Enhancements

### Potential Additions
- **Tool caching**: Cache SQL query results
- **Parallel execution**: Run independent tools in parallel
- **Tool learning**: Agent learns which tools work best for query types
- **Confidence scoring**: Agent reports confidence in its answer
- **Multi-turn conversations**: Agent remembers context across queries

---

## Summary

| Aspect | Current | Enhancement_A | Enhancement_B | Enhancement_C |
|--------|---------|---------------|---------------|---------------|
| **Classification** | Keyword-based | LLM-based | LLM-based | Agent decides |
| **Quantitative** | Poor (semantic only) | Good (SQL) | Good (SQL) | Excellent (SQL + iteration) |
| **Qualitative** | Good (pgvector) | Good (pgvector) | Good (pgvector) | Excellent (pgvector + iteration) |
| **Hybrid** | Poor | Limited | Good (two-phase) | Excellent (dynamic) |
| **Flexibility** | Low (fixed) | Medium | Medium | High (autonomous) |
| **Complexity** | Low | Medium | Medium-High | High |
| **Latency** | Low | Medium | Medium-High | High |
| **Cost** | Low | Medium | Medium-High | High |

The evolution from current → A → B → C represents a progression from simple, fixed logic to intelligent, autonomous decision-making, trading simplicity for capability and accuracy.

