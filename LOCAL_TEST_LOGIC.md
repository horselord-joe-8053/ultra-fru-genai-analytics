# Local Test Logic Flow - Agent-Based Query Processing

## Overview

This document describes the logic flow during a local test execution using the agent-based query processing system. The test `./test/test_query_1_AVG.sh --test-env local` queries "What is the average feedback rating?" and takes ~47 seconds.

## Agent Location

The agent code is located in:
- **Main Agent**: `backend/agents/query_agent.py` - `QueryAgent` class
- **Tools**: `backend/agents/tools/` - SQLTool, SemanticSearchTool, SQLGeneratorTool
- **Prompts**: `backend/agents/prompts.py` - System prompts and planning/synthesis prompts
- **Logger**: `backend/agents/logger.py` - `AgentLogger` for structured logging
- **API Integration**: `backend/api/app.py` - `/query` endpoint (lines 495-550)

## High-Level Architecture

```mermaid
graph TB
    A[Test Script] -->|HTTP POST| B[Flask API /query]
    B -->|USE_AGENT_QUERY=true| C{Agent Available?}
    C -->|Yes| D[QueryAgent.process_query]
    C -->|No| E[Simple Method Fallback]
    D --> F[Agent Planning Loop]
    F --> G[Tool Execution]
    G --> H[Synthesis Phase]
    H --> I[Return Answer]
    I --> B
    B -->|JSON Response| A
```

## Complete Request Flow

```mermaid
sequenceDiagram
    participant Test as Test Script
    participant API as Flask API (/query)
    participant Agent as QueryAgent
    participant Planner as Planning LLM
    participant SQLGen as SQLGeneratorTool
    participant SQLExec as SQLTool
    participant DB as PostgreSQL
    participant Synthesis as Synthesis LLM

    Test->>API: POST /query {"query": "What is the average feedback rating?"}
    API->>API: Validate query
    API->>Agent: process_query(question)
    
    loop 5 Iterations (MAX_ITERATIONS)
        Agent->>Planner: Planning LLM call (get_planning_prompt)
        Planner-->>Agent: Tool calls to execute
        Agent->>SQLGen: generate_sql(question)
        SQLGen->>Planner: LLM call to generate SQL
        Planner-->>SQLGen: SQL query string
        SQLGen-->>Agent: SQL query result
        
        Agent->>SQLExec: execute_sql(sql_query)
        SQLExec->>DB: Execute SELECT query
        DB-->>SQLExec: Error: function avg(text) does not exist
        SQLExec-->>Agent: Failure result
        
        Note over Agent: Agent learns from error<br/>and tries again
    end
    
    Agent->>Synthesis: Synthesis LLM call (get_synthesis_prompt)
    Note over Synthesis: No primary SQL result<br/>Uses tool results context
    Synthesis-->>Agent: Final answer
    Agent-->>API: Response with answer, iterations, tool_calls
    API-->>Test: JSON response
```

## Agent Processing Loop (ReAct Pattern)

```mermaid
flowchart TD
    Start([Start: process_query]) --> Init[Initialize AgentLogger<br/>iteration = 0]
    Init --> Loop{iteration < MAX_ITERATIONS?}
    
    Loop -->|Yes| Inc[iteration++]
    Inc --> Plan[Planning Phase:<br/>LLM call with get_planning_prompt]
    Plan --> Parse[Parse agent response<br/>Extract tool calls]
    Parse --> HasTools{Tool calls found?}
    
    HasTools -->|No| Break[Break: Agent thinks done]
    HasTools -->|Yes| Execute[Execute Tools]
    
    Execute --> Tool1[generate_sql]
    Execute --> Tool2[execute_sql]
    Execute --> Tool3[semantic_search]
    
    Tool1 --> Check[Check tool results]
    Tool2 --> Check
    Tool3 --> Check
    
    Check --> Success{SQL executed<br/>successfully?}
    Success -->|Yes| EarlyBreak[Break early]
    Success -->|No| Loop
    
    Break --> Select[Select synthesis inputs]
    EarlyBreak --> Select
    
    Select --> Synthesis[Synthesis Phase:<br/>LLM call with get_synthesis_prompt]
    Synthesis --> Return[Return answer, iterations,<br/>tool_calls, debug_info]
    Return --> End([End])
    
    Loop -->|No| Select
```

## Detailed Iteration Flow (Example: Iteration 1)

```mermaid
sequenceDiagram
    participant Agent as QueryAgent
    participant Logger as AgentLogger
    participant Planner as Planning LLM<br/>(Claude via Bedrock)
    participant SQLGen as SQLGeneratorTool
    participant SQLExec as SQLTool
    participant DB as PostgreSQL

    Note over Agent: Iteration 1 starts
    Agent->>Logger: log_iteration(1)
    Agent->>Planner: get_planning_prompt(question, [], [])
    Note over Planner: System prompt +<br/>User question +<br/>Tool descriptions
    Planner-->>Agent: "THOUGHT: Need SQL...<br/>TOOL: generate_sql<br/>INPUT: {...}"
    
    Agent->>Agent: _parse_agent_response()
    Agent->>Agent: _normalize_tool_input()
    
    Agent->>SQLGen: execute(question="What is...")
    SQLGen->>Planner: LLM call to generate SQL
    Planner-->>SQLGen: "SELECT AVG(feedback_rating)..."
    SQLGen->>SQLGen: _extract_sql()
    SQLGen-->>Agent: {success: true, sql: "SELECT AVG..."}
    Agent->>Logger: log_tool_call("generate_sql", ...)
    
    Agent->>SQLExec: execute(sql_query="SELECT AVG...")
    SQLExec->>DB: Execute query
    DB-->>SQLExec: ERROR: function avg(text) does not exist
    SQLExec-->>Agent: {success: false, error: "..."}
    Agent->>Logger: log_tool_call("execute_sql", ...)
    
    Note over Agent: Tool failed, continue to next iteration
```

## Tool Execution Details

### SQLGeneratorTool Flow

```mermaid
flowchart LR
    A[execute called] --> B[Validate input]
    B --> C[Build system prompt<br/>with schema info]
    C --> D[Call Claude LLM<br/>max_tokens=500]
    D --> E[Extract SQL from response]
    E --> F[Return SQL result]
    
    style D fill:#ff9999
    style E fill:#99ff99
```

### SQLTool Flow

```mermaid
flowchart LR
    A[execute called] --> B[Validate SQL<br/>Check for dangerous keywords]
    B --> C{Valid SELECT?}
    C -->|No| D[Return error]
    C -->|Yes| E[Get DB connection<br/>from pool]
    E --> F[Execute query]
    F --> G{Success?}
    G -->|Yes| H[Return rows, columns,<br/>row_count]
    G -->|No| I[Return error]
    
    style F fill:#ff9999
    style H fill:#99ff99
```

## Synthesis Phase

```mermaid
flowchart TD
    A[After iterations] --> B[_select_synthesis_inputs]
    B --> C{Primary result?}
    C -->|SQL with rows| D[Use SQL result]
    C -->|Semantic with rows| E[Use semantic result]
    C -->|None| F[Use context only]
    
    D --> G[Build synthesis prompt]
    E --> G
    F --> G
    
    G --> H[Call Claude LLM<br/>max_tokens=2000]
    H --> I[Extract answer]
    I --> J[Return final response]
    
    style H fill:#ff9999
    style I fill:#99ff99
```

## Test Execution Flow

```mermaid
sequenceDiagram
    participant Test as test_query_1_AVG.sh
    participant Runner as run_test_suite.sh
    participant Env as test_environment.sh
    participant Python as common_test_queries.py
    participant API as Flask API
    participant Agent as QueryAgent

    Test->>Runner: run_test_suite("query_1_avg", --test-env local, "AVG")
    Runner->>Env: setup_local_environment()
    Env->>Env: Load .env file
    Env->>Env: API_BASE_URL="http://localhost:5001"
    Env-->>Runner: API_BASE_URL exported
    
    Runner->>Python: Run test with API_BASE_URL
    Python->>API: POST /query {"query": "What is the average feedback rating?"}
    
    API->>Agent: process_query(question)
    Note over Agent: 5 iterations<br/>~46.5 seconds
    Agent-->>API: {answer, iterations: 5, tool_calls, ...}
    
    API-->>Python: JSON response
    Python->>Python: Validate response<br/>(check iterations, answer content)
    Python-->>Runner: Test result
    Runner-->>Test: PASSED/FAILED
```

## Time Breakdown (47 seconds)

```mermaid
gantt
    title Agent Processing Timeline (47s total)
    dateFormat X
    axisFormat %Ls
    
    section Iteration 1
    Planning LLM call     :0, 7200
    generate_sql LLM      :7200, 1500
    execute_sql (failed)  :8700, 7
    
    section Iteration 2
    Planning LLM call     :8707, 7900
    generate_sql LLM      :16607, 1600
    execute_sql (failed)  :18207, 2
    
    section Iteration 3
    Planning LLM call     :18209, 1600
    generate_sql LLM      :19809, 1500
    execute_sql (failed)  :21309, 0
    
    section Iteration 4
    Planning LLM call     :21309, 17300
    generate_sql LLM      :38609, 2000
    execute_sql (failed)  :40609, 15
    
    section Iteration 5
    Planning LLM call     :40624, 8900
    generate_sql LLM      :49524, 1500
    execute_sql (failed)  :51024, 1
    
    section Synthesis
    Synthesis LLM call    :51025, 3600
```

## Key Components

### 1. QueryAgent (`backend/agents/query_agent.py`)

**Main Method**: `process_query(question: str) -> Dict[str, Any]`

**Key Attributes**:
- `MAX_ITERATIONS = 5` - Maximum planning iterations
- `tools` - Dictionary of available tools (execute_sql, semantic_search, generate_sql)
- `system_prompt` - System prompt with tool descriptions

**Process**:
1. Initialize `AgentLogger` for structured logging
2. **Planning Loop** (up to 5 iterations):
   - Call planning LLM with `get_planning_prompt()`
   - Parse agent response to extract tool calls
   - Execute tools in sequence
   - Break early if SQL execution succeeds
3. **Synthesis Phase**:
   - Select primary result (SQL or semantic search)
   - Build synthesis prompt with results
   - Call synthesis LLM with `get_synthesis_prompt()`
   - Return final answer

### 2. Tools

#### SQLGeneratorTool (`backend/agents/tools/sql_generator_tool.py`)
- **Purpose**: Generate SQL queries from natural language
- **Method**: `execute(question: str) -> Dict[str, Any]`
- **Process**: LLM call → Extract SQL → Return SQL string

#### SQLTool (`backend/agents/tools/sql_tool.py`)
- **Purpose**: Execute SQL queries safely
- **Method**: `execute(sql_query: str) -> Dict[str, Any]`
- **Validation**: Blocks dangerous keywords, only allows SELECT
- **Process**: Validate → Execute → Return rows/error

#### SemanticSearchTool (`backend/agents/tools/semantic_search_tool.py`)
- **Purpose**: Semantic search using pgvector
- **Method**: `execute(query_text: str, filters: Dict) -> Dict[str, Any]`
- **Process**: Generate embedding → Vector search → Return similar records

### 3. Prompts (`backend/agents/prompts.py`)

- **`get_agent_system_prompt()`**: System prompt with tool descriptions and guidelines
- **`get_planning_prompt()`**: Prompt for planning phase (what tools to use)
- **`get_synthesis_prompt()`**: Prompt for synthesis phase (generate final answer)

### 4. AgentLogger (`backend/agents/logger.py`)

Tracks:
- Query ID (UUID)
- Iterations
- Tool calls (input/output/timing)
- Agent thoughts
- Execution time

## Issue Analysis: Why 5 Iterations?

The agent went through all 5 iterations because:

1. **Type Error**: `feedback_rating` column is stored as TEXT in some cases, but AVG() requires numeric
2. **SQL Generation**: LLM kept generating `SELECT AVG(feedback_rating)` without type casting
3. **Error Recovery**: Agent tried to fix the error but didn't understand the root cause
4. **Final Synthesis**: Since no SQL succeeded, synthesis used tool results context to generate answer

**Error Pattern**:
```
Iteration 1-5: SELECT AVG(feedback_rating) → Error: function avg(text) does not exist
```

**Solution Needed**: 
- Fix schema info to indicate `feedback_rating` needs casting: `AVG(CAST(feedback_rating AS INTEGER))`
- Or update prompts to emphasize type casting for aggregation functions

## Performance Comparison

| Metric | Local (Docker) | AWS (ECS) |
|--------|---------------|-----------|
| **Total Time** | 47s | ~10s |
| **Planning Calls** | 5 × ~7-9s = ~35-40s | Likely 1-2 iterations |
| **generate_sql Calls** | 5 × ~1.5-2s = ~8s | Likely 1-2 calls |
| **Synthesis** | ~3.6s | ~3-4s |
| **Network Latency** | ~500ms-1s per LLM call | ~50-200ms per call |
| **Root Cause** | SQL type errors → 5 iterations | Better SQL generation → fewer iterations |

## Files Reference

- **Agent**: `backend/agents/query_agent.py`
- **API Endpoint**: `backend/api/app.py` (lines 495-550)
- **Tools**: `backend/agents/tools/`
- **Prompts**: `backend/agents/prompts.py`
- **Test Script**: `test/test_query_1_AVG.sh`
- **Test Runner**: `test/common_sh/run_test_suite.sh`
- **Test Environment**: `test/common_sh/test_environment.sh`

