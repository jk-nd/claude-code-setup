# Hooks — making the operating model executable

The operating contract in [`AGENTS.md`](../AGENTS.md) is mostly *advisory*: it
describes what the orchestrator should do. Hooks make the load-bearing parts
*executable* — Claude Code runs them automatically at defined lifecycle and
tool events, so behavior doesn't depend on the orchestrator remembering.

Hooks ship in `.claude/hooks/` and are wired into `.claude/settings.json` (the
template at `templates/claude-settings.json.template`, copied by bootstrap).

## What ships

| Hook | Event | What it does |
| --- | --- | --- |
| `session-start.sh` | `SessionStart` | Loads a **bounded** snapshot of operating state (branch, uncommitted paths, open stashes, in-flight plan-missions) as session context, so the orchestrator starts already oriented. |
| `pre-compact.sh` | `PreCompact` | Persists a session snapshot to `.claude/state/last-precompact.md` **before** context compaction, so in-flight state survives. |
| `session-end.sh` | `SessionEnd` | Writes an end-of-session working-tree summary (uncommitted work, open stashes) to `.claude/state/last-session-end.md`, per [AGENTS.md #27](../AGENTS.md#27-session-boundary-stash-hygiene). |

Guard hooks (`config-protection`, `safety-guard`, an investigate-before-edit
gate) run at the `PreToolUse` event and are documented in their own section
below once enabled.

## The hook contract

- **Lifecycle hooks are non-blocking.** `session-start`, `pre-compact`, and
  `session-end` always `exit 0` and degrade gracefully (e.g. outside a git
  repo) — they must never error or stall a session.
- **`PreToolUse` guard hooks may block.** They exit non-zero (or emit a deny
  decision) *only* when intentionally gating an action; otherwise they pass
  through. See `docs/guard-hooks.md`.
- **Fast and quiet.** Hooks run on every matching event; keep them to quick
  local `git`/file reads. No network calls.
- **Runtime state is git-ignored.** Hooks write under `.claude/state/`, which
  is in `.gitignore` — it is per-checkout runtime state, never committed.

## Tuning

- `ECC_SESSION_START_CONTEXT=off` — disable the start-of-session context load.
- `ECC_SESSION_START_MAX_CHARS=N` — cap the injected context (default 4000).

## Authoring a hook

A hook is a script in `.claude/hooks/` registered under the matching event in
`settings.json` `hooks`:

```json
"hooks": {
  "SessionStart": [
    { "hooks": [ { "type": "command", "command": "bash .claude/hooks/session-start.sh" } ] }
  ]
}
```

Lifecycle hooks should `set -uo pipefail`, guard on `git rev-parse --git-dir`,
and `exit 0`. `PreToolUse` hooks receive the tool call as JSON on stdin and
decide whether to allow it. Keep logic in the script (not the prompt) so the
behavior is identical every run. Add the hook's invocation to the Bash
allowlist in `templates/claude-settings.json.template` if needed.
