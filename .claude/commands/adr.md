---
description: Capture an architectural-shape decision as a new ADR under docs/adr/.
argument-hint: [the decision]
---

Capture this decision as an Architecture Decision Record:

**$ARGUMENTS**

1. Confirm it's an **architectural-shape** decision (a boundary, dependency, or
   contract choice). If it's mechanical/operational, it belongs in the approach
   doc's `## Decisions made by architect` section instead (AGENTS.md #9) — say so
   and stop.
2. Next ADR number: highest `docs/adr/NNNN-*.md` + 1 (start at `0001`). Copy
   `docs/adr/0000-template.md` to `docs/adr/NNNN-<kebab-title>.md`.
3. Fill it from the conversation + approach doc: **Context** (the forces),
   **Options considered** (with tradeoffs), **Decision** (chosen option + one-line
   rationale, linking the approach doc / spec / PR), **Consequences**. Set
   `Status: accepted` and today's date.
4. If this supersedes an existing ADR, set that ADR's status to
   `superseded by [NNNN]` (append-only — do not rewrite it; AGENTS.md #1).
5. Route the new file through `doc-keeper` + a PR, and cross-link it from the
   approach doc.
