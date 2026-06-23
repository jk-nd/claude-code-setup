---
description: Compose the morning digest from plan-mission state + git activity.
---

You are the orchestrator. Dispatch the **conductor** subagent (read-only, main tree) to compose a digest covering:

- Each in-flight plan-mission: what advanced, what merged, what's blocked, what's waiting on a user gate.
- Open PRs and their state (CI, adversary, trust-boundary).
- Working-tree / stash state (clarification #27) — surface anything left behind.
- Open questions logged in the plan-missions' Open-questions sections.

Lead with the plain-language stakes, then detail (clarification #30). Keep it scannable — it's the first thing the user reads. If `.claude/state/last-session-end.md` exists, fold its summary in.
