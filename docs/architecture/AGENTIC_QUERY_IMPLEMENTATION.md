# Agentic Query Processing Implementation

## Overview

This document describes the implementation of Enhancement_C: Agent-Based Autonomous Query Processing.

## Architecture

### Components

1. **Tools** (`backend/agents/tools/`)
   - `SQLTool`: Execute SQL queries safely
   - `SemanticSearchTool`: pgvector semantic search with filters
   - `SQLGeneratorTool`: LLM generates SQL from natural language

2. **Agent** (`backend/agents/query_agent.py`)
   - ReAct pattern implementation
   - Autonomous planning and execution
   - Iterative refinement (max 5 iterations)

3. **Logging** (`backend/agents/logger.py`)
   - Structured logging for debugging
   - Tool call tracking
   - Reasoning traces

4. **Metrics** (`backend/agents/metrics.py`)
   - Performance tracking
   - Success/failure rates
   - Latency monitoring

5. **API Integration** (`backend/api/app.py`)
   - `/query-v2` endpoint (agent-based)
   - `/metrics/agent` endpoint
   - Feature flag: `USE_AGENT_QUERY`

## Usage

### Enable Agent

Set environment variable:
```bash
USE_AGENT_QUERY=true
```

### API Endpoints

**Agent Query:**
```bash
curl -X POST http://localhost:5000/query-v2 \
  -H "Content-Type: application/json" \
  -d '{"query": "Which region has the biggest sales?"}'
```

**Metrics:**
```bash
curl http://localhost:5000/metrics/agent
```

## Feature Flags

- `USE_AGENT_QUERY`: Master switch (default: false)
- `USE_AGENT_QUERY_PERCENTAGE`: Gradual rollout percentage (0-100)
- `USE_AGENT_QUERY_WHITELIST`: Comma-separated user IDs for testing

## Debugging

When `FLASK_DEBUG=true`, the `/query-v2` response includes:
- `debug_info`: Complete execution trace
- `tool_calls`: All tool executions with inputs/outputs
- `agent_thoughts`: Agent reasoning

## Performance

- **Latency**: 1500-3000ms (multiple LLM calls + tool executions)
- **Cost**: Higher than current implementation (2-5 Bedrock calls per query)
- **Accuracy**: Better for complex/hybrid queries

## Testing

See `backend/tests/` for:
- Unit tests for tools
- Integration tests for agent
- End-to-end API tests

## Migration Path

1. **Phase 1**: Test with feature flag disabled (default)
2. **Phase 2**: Enable for specific users (whitelist)
3. **Phase 3**: Gradual rollout (percentage)
4. **Phase 4**: Full rollout (if metrics are good)

## Rollback

Set `USE_AGENT_QUERY=false` to disable agent and fall back to original `/query` endpoint.

