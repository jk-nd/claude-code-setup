---
name: Epic
about: Multi-PR initiative split into sub-issues with a dependency graph
title: "[epic][PRIORITY] <topic>"
labels: ["epic"]
---

**Epic.** <One-paragraph description of the initiative.>

## Customer-facing pitch

<Why this matters from the user's perspective. What problem does it solve, what was missing before.>

## Architectural shape (decided)

<The shape of the solution at the architecture level. Decide here, not in the sub-issues.>

**Why this shape:**
- <Reason 1 — e.g. "don't reinvent: integrate with existing system X">
- <Reason 2 — e.g. "single source of truth matters for audit">
- <Reason 3 — e.g. "closest precedent: <library or pattern>">

**Main tradeoff:** <Honest statement of what we give up vs. the rejected alternative.>

## Sub-issues (dependency order)

| Sub | # | Title | Depends on | Status |
|---|---|---|---|---|
| A | #_  | _ | — | open |
| B | #_  | _ | A | open |
| C | #_  | _ | A | open |

## Parallelism

- **<Sub-issue> is on the critical path.** Until its API contract is stable, dependent sub-issues build against a moving target.
- <Other sub-issues> can run in parallel once <critical-path sub-issue> stabilises.

## Out of scope for this epic

- <Explicitly rejected expansion 1>
- <Explicitly rejected expansion 2>

## References

- <Architecture doc, prior PR, demo precedent>
