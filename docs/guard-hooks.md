# Guard hooks (`PreToolUse`)

Guard hooks run **before** a tool call and can block it. They turn three pieces
of operating discipline from advice into enforcement. They are **opt-in** —
`scripts/bootstrap.sh` offers to wire them into `.claude/settings.json`, and
they're off by default. See [`docs/hooks.md`](hooks.md) for the general hook
contract.

Protocol: a guard exits `0` to allow the tool call, or `2` to block it (its
stderr is fed back to the model as the reason).

## What ships

| Guard | Matches | Blocks | Escape hatch |
| --- | --- | --- | --- |
| `config-protection.sh` | `Edit`/`Write`/`MultiEdit` | Edits to quality-gate configs (golangci, eslint, prettier, ruff, flake8, editorconfig, markdownlint, `tox.ini`, `setup.cfg`, `ops/coverage-baseline.json`) — the "relax the linter to make the check pass" failure mode. | `ECC_ALLOW_CONFIG_EDIT=1` for a deliberate config change |
| `safety-guard.sh` | `Bash` | A narrow set of never-legitimate commands: `rm -rf` outside a temp dir, `git push --force`, `git clean -f`, `chmod -R 777`, `mkfs`/`dd of=/dev/*`, fork bombs. A runtime backstop to the static deny-list, for unattended runs. | (none — run it yourself if genuinely intended) |
| `investigate-before-edit.sh` | `Edit`/`Write`/`MultiEdit` | **Experimental, off by default.** The first edit to each file (per checkout) is blocked once with a reminder to check importers/callers/data-flow; the retry proceeds. | `ECC_INVESTIGATE_GATE=off` |

`safety-guard` is deliberately conservative: it never blocks commands the
operating loop legitimately runs (e.g. `git reset --hard origin/main` to sync a
checkout). The goal is a backstop that cannot derail autonomous work, not a
broad policy engine.

## Enabling later

If you skipped them at bootstrap, add `PreToolUse` entries to
`.claude/settings.json`:

```json
"hooks": {
  "PreToolUse": [
    { "matcher": "Edit|Write|MultiEdit", "hooks": [ { "type": "command", "command": "bash .claude/hooks/config-protection.sh" } ] },
    { "matcher": "Bash", "hooks": [ { "type": "command", "command": "bash .claude/hooks/safety-guard.sh" } ] }
  ]
}
```

Add the `investigate-before-edit.sh` entry (same matcher as
`config-protection`) only if you want the investigate gate.

## Authoring your own guard

A guard reads the tool call as JSON on stdin (`{"tool_name": ..., "tool_input":
{...}}`), decides, and exits `0` (allow) or `2` (block, with a reason on
stderr). Keep them fast and specific — a guard that false-positives on routine
commands will train the orchestrator to route around it.
