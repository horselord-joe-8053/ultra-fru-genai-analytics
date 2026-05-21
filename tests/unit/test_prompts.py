"""Unit tests for agent prompt guardrails."""

from backend.agents.prompts import (
    get_agent_system_prompt,
    get_planning_prompt,
    get_synthesis_prompt,
)


def test_agent_system_prompt_anti_hallucination():
    prompt = get_agent_system_prompt([{"name": "execute_sql", "description": "run sql"}])
    assert "NEVER GUESS" in prompt or "NEVER invent" in prompt
    assert "execute_sql" in prompt


def test_planning_prompt_includes_question():
    prompt = get_planning_prompt("How many LG units sold?", [], [])
    assert "How many LG units sold?" in prompt


def test_synthesis_prompt_requires_grounding():
    prompt = get_synthesis_prompt("q", {"rows": []}, [])
    assert "JSON" in prompt or "data" in prompt.lower()
