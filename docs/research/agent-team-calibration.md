# Agent-team calibration log

This file captures drift incidents — moments where a subagent operated outside
its mandate, the orchestrator under- or over-dispatched, calibration thresholds
([decide-vs-ask](../../AGENTS.md#9-decide-rather-than-ask-on-mechanical-questions),
[dispatch-vs-self](../../AGENTS.md#12-default-to-subagent-dispatch-over-direct-orchestrator-work))
were missed, or any other in-flight operational issue worth recording. Entries
are dated and short; the goal is to spot patterns across incidents, not to
write incident reports.

Patterns that recur across several entries are candidates for upstream
amendment to `jk-nd/claude-code-setup` (track as issue comments on the v3
amendments issue or its successor).

## Entry format

```
### YYYY-MM-DD HH:MM — <one-line subject>

**Pattern:** <which AGENTS.md operating clarification this maps to, or "new">
**What happened:** <one or two sentences>
**Recovery:** <what the orchestrator did to recover>
**Upstream candidate:** <yes/no — if yes, what would the template change look like?>
```

Single-line entries are also fine. The orchestrator appends these directly
to `main` (this is one of the few direct-to-`main` exceptions in
[AGENTS.md operating clarification #21](../../AGENTS.md#21-pr-ceremony-for-every-change));
multi-line entries flow through `doc-keeper` + PR like any other doc change.

## Entries

(none yet — append below as drift events surface)
