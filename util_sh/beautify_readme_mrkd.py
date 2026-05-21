#!/usr/bin/env python3
"""Apply mrkd-markdown-authoring structure to FRU legacy README.md."""

from __future__ import annotations

import re
import sys
from pathlib import Path

H1_STYLE = (
    'style="color:#0d47a1;font-size:1.5em;font-weight:700;'
    'border-bottom:2px solid #90caf9;padding-bottom:0.25em;margin-top:0"'
)
H2_STYLE = (
    'style="color:#1565c0;font-size:1.22em;font-weight:650;'
    'border-left:4px solid #42a5f5;padding-left:10px;margin-top:1.1em"'
)
H3_STYLE = (
    'style="color:#00695c;font-size:1.05em;font-weight:600;margin-top:0.85em"'
)

TABLE_OF_CONTENTS = """<h2 id="document-outline" {h2}>📋 Table of Contents</h2>

- [🧠 1. Concept](#1-concept)
- [🧩 2. Architecture Overview](#2-architecture-overview)
  - [System layers](#system-layers)
  - [📐 Architecture Diagram](#architecture-diagram)
- [🗂 3. Project Layout](#3-project-layout)
- [⚡️ 4. Local Quickstart](#4-local-quickstart)
- [🔥 5. Analytics with Spark + Delta](#5-analytics-with-spark-delta)
  - [5.1 Ingest CSV → Delta Lake](#51-ingest-csv-delta-lake)
  - [5.2 Generate NLQ→SQL examples for LoRA](#52-generate-nlqsql-examples-for-lora)
- [🧠 6. Intelligence Model: OpenAI Embeddings + pgvector](#6-intelligence-model-openai-embeddings-pgvector)
  - [6.1 Overview](#61-overview)
  - [6.2 Embedding Generation (Offline Factory)](#62-embedding-generation-offline-factory)
  - [6.3 pgvector Schema](#63-pgvector-schema)
  - [6.4 Inference-Time Flow](#64-inference-time-flow)
  - [6.5 LLM Prompt Pattern](#65-llm-prompt-pattern)
  - [6.6 Why pgvector vs Spark SQL?](#66-why-pgvector-vs-spark-sql)
- [🦾 7. Integrating Bedrock Claude](#7-integrating-bedrock-claude)
  - [Prompt logic (conceptual)](#prompt-logic-conceptual)
- [🏗 8. Full AWS Deployment](#8-full-aws-deployment)
- [🛡 9. Governance & Safety](#9-governance-safety)
- [🤖 10. Query Processing Architecture](#10-query-processing-architecture) ⭐
  - [10.1 Current Implementation](#101-current-implementation)
    - [Architecture](#architecture)
    - [Flow](#flow)
  - [10.2 Evolution Path: Enhancement_A → B → C](#102-evolution-path-enhancement_a-b-c)
    - [Enhancement_A: LLM Classification + SQL Generation](#enhancement_a-llm-classification-sql-generation)
    - [Enhancement_B: Hybrid Query Processing](#enhancement_b-hybrid-query-processing)
    - [Enhancement_C: Agent-Based Autonomous Planning (Implemented)](#enhancement_c-agent-based-autonomous-planning-implemented)
  - [10.3 Agent-Based System (Enhancement_C) - Implementation](#103-agent-based-system-enhancement_c-implementation)
    - [Components](#components)
    - [Usage](#usage)
    - [Feature Flags](#feature-flags)
    - [Debugging](#debugging)
    - [Performance Considerations](#performance-considerations)
    - [Migration Path](#migration-path)
    - [Rollback](#rollback)
- [📌 11. Next Steps (Roadmap)](#11-next-steps-roadmap)
- [🙌 Summary](#summary)
""".format(h2=H2_STYLE)

STACK_TABLE = """<table>
<thead>
<tr style="background:#1565c0;color:white"><th style="padding:8px">Layer</th><th style="padding:8px">Technology</th><th style="padding:8px">Role</th></tr>
</thead>
<tbody>
<tr><td style="background:#e3f2fd;padding:8px"><strong>Batch</strong></td><td style="background:#e8f5e9;padding:8px">Spark + Delta Lake</td><td style="background:#e8f5e9;padding:8px">Ingest, analytics, NLQ→SQL training data</td></tr>
<tr><td style="background:#e3f2fd;padding:8px"><strong>Interactive</strong></td><td style="background:#fff3e0;padding:8px">OpenAI embeddings + pgvector</td><td style="background:#fff3e0;padding:8px">Low-latency semantic search and SQL filters</td></tr>
<tr><td style="background:#e3f2fd;padding:8px"><strong>Narrative</strong></td><td style="background:#e8f5e9;padding:8px">AWS Bedrock Claude</td><td style="background:#e8f5e9;padding:8px">Grounded explanations over retrieved facts</td></tr>
<tr><td style="background:#e3f2fd;padding:8px"><strong>Deploy</strong></td><td style="background:#fff3e0;padding:8px">Terraform + Terragrunt, ECS/EKS</td><td style="background:#fff3e0;padding:8px">Modular IaC and environment management</td></tr>
</tbody>
</table>"""

ANCHOR_RE = re.compile(r'^<a id="([^"]+)"></a>\s*$')
H1_RE = re.compile(r"^# (.+)$")
H2_RE = re.compile(r"^## (.+)$")
H3_RE = re.compile(r"^### (.+)$")
FENCE_OPEN_RE = re.compile(r"^```(\w*)$")
TOC_START = re.compile(r"^## 📋 Table of Contents")
DOC_GUIDE_RE = re.compile(r"^## 📚 Documentation Guide")


def _escape(text: str) -> str:
    return text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def _slugify(title: str) -> str:
    t = re.sub(r"[*_`]", "", title).strip().lower()
    t = re.sub(r"[^\w\s-]", "", t)
    t = re.sub(r"\s+", "-", t)
    return re.sub(r"-+", "-", t).strip("-")


def _html_heading(level: int, id_: str, title: str) -> str:
    esc = _escape(title)
    if level == 1:
        return f'<h1 id="{id_}" {H1_STYLE}>{esc}</h1>'
    if level == 2:
        return f'<h2 id="{id_}" {H2_STYLE}>{esc}</h2>'
    return f'<h3 id="{id_}" {H3_STYLE}>{esc}</h3>'


def _guess_fence_lang(body: str) -> str:
    lines = [ln for ln in body.splitlines() if ln.strip()]
    if not lines:
        return "text"
    first = lines[0].strip()
    if first.startswith(("graph ", "flowchart ", "sequenceDiagram")):
        return "mermaid"
    if first.startswith(("{", "[")):
        return "json"
    if first.startswith(("SELECT ", "CREATE ", "WITH ")):
        return "sql"
    if "→" in body or "│" in body or "┌" in body:
        return "text"
    if first.startswith(("curl ", "export ", "USE_", "spark-submit")):
        return "bash"
    return "text"


def _tag_fences(text: str) -> str:
    lines = text.splitlines(keepends=True)
    out: list[str] = []
    i = 0
    while i < len(lines):
        m = FENCE_OPEN_RE.match(lines[i].rstrip("\n"))
        if not m:
            out.append(lines[i])
            i += 1
            continue
        lang = m.group(1)
        i += 1
        body_lines: list[str] = []
        while i < len(lines) and lines[i].rstrip("\n") != "```":
            body_lines.append(lines[i])
            i += 1
        body = "".join(body_lines)
        if not lang:
            lang = _guess_fence_lang(body)
        out.append(f"```{lang}\n")
        out.extend(body_lines)
        if i < len(lines):
            out.append(lines[i])
            i += 1
    return "".join(out)


def beautify(text: str) -> str:
    if '<h1 id="fru-readme-title"' in text:
        return text

    lines = text.splitlines()
    out: list[str] = []
    i = 0
    pending_anchor: str | None = None
    in_toc = False

    while i < len(lines):
        line = lines[i]

        # Title block (first lines)
        if i == 0 and line.startswith("# 📦"):
            out.append(
                f'<h1 id="fru-readme-title" {H1_STYLE}>FRU GenAI Analytics Overview</h1>\n'
            )
            i += 1
            continue
        if i == 1 and line.startswith("**("):
            out.append(f"\n{line}\n")
            i += 1
            continue
        if i == 2 and line.strip() == "":
            i += 1
            continue
        if i == 3 and line.startswith("FRU"):
            out.append(f"\n{line}\n")
            i += 1
            continue

        if TOC_START.match(line):
            in_toc = True
            out.append("\n")
            out.append(TABLE_OF_CONTENTS)
            out.append("\n---\n\n")
            i += 1
            while i < len(lines) and not (
                lines[i].strip() == "---" and i > 5 and not lines[i - 1].startswith("- [")
            ):
                i += 1
            if i < len(lines) and lines[i].strip() == "---":
                i += 1
            in_toc = False
            continue

        if DOC_GUIDE_RE.match(line):
            out.append(
                f'\n<h2 id="documentation-guide" {H2_STYLE}>📚 Documentation Guide</h2>\n'
            )
            i += 1
            continue

        if line.strip() == "It demonstrates:":
            out.append("\n**What this repo demonstrates:**\n\n")
            out.append(STACK_TABLE)
            out.append("\n\n")
            i += 1
            continue

        m_anchor = ANCHOR_RE.match(line)
        if m_anchor:
            pending_anchor = m_anchor.group(1)
            i += 1
            if i < len(lines) and lines[i].strip() == "":
                i += 1
            continue

        m1, m2, m3 = H1_RE.match(line), H2_RE.match(line), H3_RE.match(line)
        if m1 or m2 or m3:
            title = (m1 or m2 or m3).group(1)
            hid = pending_anchor or _slugify(title)
            pending_anchor = None
            if m1:
                out.append(_html_heading(2, hid, title) + "\n")
            elif m2:
                out.append(_html_heading(3, hid, title) + "\n")
            else:
                out.append(_html_heading(3, hid, title) + "\n")
            i += 1
            continue

        # Collapse duplicate horizontal rules before section 10
        if (
            line.strip() == "---"
            and out
            and out[-1].strip() == "---"
        ):
            i += 1
            continue

        out.append(line + "\n")
        i += 1

    result = "".join(out)
    # Remove checklist bullets duplicated by table (lines after table until "It is designed")
    result = re.sub(
        r"\n- ✔️ \*\*Enterprise GenAI architecture\*\*.*?\n\nIt is designed",
        "\n\n- ⭐ **Agent-based query processing** (optional) — See [Section 10](#10-query-processing-architecture).\n"
        "- ✔️ **Optimized deployment** — ~15–30s saved on repeat deploys.\n"
        "- ✔️ **Enhanced frontend** — Version tracking, error handling, resizable panels.\n\nIt is designed",
        result,
        count=1,
        flags=re.DOTALL,
    )
    result = re.sub(r"\n---\n\n\n+", "\n---\n\n", result)
    return _tag_fences(result)


def main() -> int:
    path = Path(__file__).resolve().parents[1] / "README.md"
    if len(sys.argv) > 1:
        path = Path(sys.argv[1])
    text = path.read_text(encoding="utf-8")
    path.write_text(beautify(text), encoding="utf-8")
    print(f"Beautified {path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
