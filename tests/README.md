# Unit tests (pytest)

Fast, mocked unit tests for `module_app_core/backend`. Integration query tests live under `module_test_verification/`.

## Run

```bash
# From repo root
pip install -r requirements-dev.txt
pytest
# or
./scripts/run_unit_tests.sh
```

Coverage (current gate **42%** on `module_app_core/backend`, target **80%** per refactor plan):

```bash
./scripts/run_unit_tests.sh
# or: coverage run -m pytest && coverage html
```

## Layers

| Layer | Location | When |
|-------|----------|------|
| Unit | `tests/` | Every PR; mocked DB/LLM/OpenAI |
| Integration | `module_test_verification/test_query_*.sh` | Local/AWS with running API |

```mermaid
graph LR
  UT[pytest unit mocked] --> PR[PR gate fast]
  IV[module_test_verification live API] --> Merge[pre-release or nightly]

  style UT fill:#e8f5e9,stroke:#2e7d32,stroke-width:1px,font-size:9px
  style IV fill:#fff3e0,stroke:#e65100,stroke-width:1px,font-size:9px
  style PR fill:#e3f2fd,stroke:#1976d2,stroke-width:1px,font-size:9px
  style Merge fill:#ede7f6,stroke:#5e35b1,stroke-width:1px,font-size:9px
```

## Traceability (unit ↔ integration)

| Integration query | Code path exercised in unit tests |
|-------------------|-----------------------------------|
| `1_AVG` (average rating) | `validate_query`, `is_qualitative`, agent `execute_sql` / legacy `/query` mocks |
| `1_TOP` | SQL tool validation, quantitative keyword routing |
| `9` / stream variants | `/query/stream` error path when agent disabled |

## Markers

- Default: `-m "not integration"` (see `pytest.ini`)
- `@pytest.mark.integration` — reserved for future live-stack tests
