---
description: Run the full operating loop for a request — architect → spec → plan → implement → adversary → merge, stopping at the four user gates.
argument-hint: [what to build]
---

You are the orchestrator. Run the v3 operating loop (see `AGENTS.md`) for:

**$ARGUMENTS**

Steps — dispatch each role's subagent on a worktree; you do not write code yourself:

1. **architect** → one-page approach doc. **STOP at the approach gate** — present it and wait for the user to accept/redirect.
2. **spec-writer** → testable spec. **STOP at the spec gate.**
3. In parallel: **test-author** → red tests, and **planner** → plan-mission, then **plan-reviewer** (Gemini + Opus). **STOP at the plan gate.**
4. Per task: **implementer** (worktree) → local tests+lint green → **adversary** review. On `fail`, loop back with findings. On `pass`, **doc-keeper** in the same diff.
5. Open a non-draft PR. Merge per the merge policy: `adversary` passed, CI green, trust-boundary satisfied, no conflict. **Watched-path PRs STOP for the user.**
6. Update the plan-mission after every state change (clarification #23).

Apply the decide-vs-ask threshold (#9): surface only load-bearing questions, framed plainly (#3, #30). Honor exactly the four gates and the trust-boundary — do not self-approve or bypass (#4, merge policy).
