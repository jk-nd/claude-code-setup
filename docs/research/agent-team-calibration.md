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

Each entry is a small, **structured**, append-only record so patterns can be
counted and promoted, not just read:

```
### YYYY-MM-DD HH:MM — <one-line subject>

**Pattern:** <AGENTS.md clarification # it maps to, or "new">
**Confidence:** <0.3–0.9 — how sure this is a real, recurring pattern vs a one-off>
**Scope:** <project | global>   **Domain:** <tag: dispatch | ci | merge | docs | security | …>
**What happened:** <one or two sentences>
**Recovery:** <what the orchestrator did>
**Promotion:** <recurrence count; whether it is now an upstream candidate>
```

- **Confidence** rises as the same pattern recurs; a fresh one-off starts low
  (~0.3–0.5), a well-evidenced recurring pattern is ~0.8–0.9.
- **Scope** is `project` for a repo-specific quirk, `global` for something that
  would apply to any repo built from the template.
- Use `scripts/calibration-add.py` to append a well-formed entry.

The orchestrator appends entries directly to `main` (one of the few
direct-to-`main` exceptions in [#21](../../AGENTS.md#21-pr-ceremony-for-every-change));
multi-line entries flow through `doc-keeper` + PR like any other doc change.

## Promotion

A **`global`**-scope pattern at **confidence ≥ 0.7** seen in **≥ 2 entries**
(here or across repos) is an **upstream amendment candidate**: file an issue on
`jk-nd/claude-code-setup` describing the template change, per
[#22](../../AGENTS.md#22-cross-repo-dependencies-signal-via-github-issues-in-the-target-repo).
`project`-scope patterns stay local. This is the structured form of the
recurrence rule in [#20](../../AGENTS.md#20-calibration-log-as-a-default-template-file).

## Entries

(none yet — append below as drift events surface)
