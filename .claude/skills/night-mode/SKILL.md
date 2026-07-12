---
name: night-mode
description: Prepare a session-scoped permission profile before an unattended (overnight) build so the run doesn't stall on the first destructive-command gate. Use before launching a long autonomous run — assemble a .claude/settings.local.json that pre-approves the commands THIS build actually uses (compose, db clients, gh pr/run, git worktree). Operator opt-in; local overrides are your own risk surface.
---

# night-mode

An unattended run stalls the moment it hits a command outside the allowlist — a single `docker rm -f` prompt is enough to wake you at 3am. The shared `.claude/settings.json` (from the template) is deliberately conservative and language-generic. **`night-mode` is where the operator opts into the broader, project-specific command set an autonomous build needs** — for the duration of a run, in a local, git-ignored `.claude/settings.local.json` that merges on top of the shared settings.

## What to do

1. **Enumerate what this build actually runs.** Read the `Makefile` / `docker-compose.yml` / `scripts/` for the stack-bring-up, DB, and CI commands the loop will invoke (compose up/down, `docker ps/logs/stop/rm`, `psql`, `gh pr *`, `gh run *`, `git worktree`, …).
2. **Add them to `.claude/settings.local.json`** — copy `.claude/settings.local.json.example` and edit. This file is **git-ignored** and additive to the shared `settings.json`.
3. **Never weaken the shared `deny`-list.** `settings.local.json` only *adds* allows; the deny-list (sudo, force-push, …) stays. If a night run genuinely needs an autonomous merge, `gh pr merge` belongs **here** — a deliberate per-run operator grant — not in the shared template.
4. **Scope it to the run.** These are broader grants you accept for an unattended build. Trim them — or delete the local file — when done, so day-to-day sessions run under the conservative shared allowlist.

## Why local, not shared

The shared template must stay safe for every repo, so project-specific and destructive-adjacent commands (`docker rm`, DB clients, `gh pr merge`) are the **operator's own risk surface**. Granting them per-repo in a git-ignored local override keeps that decision explicit and out of the shared, audited template. (The *safe, generally-applicable* additions — git/gh/file-ops — do live in the shared template; only the project-specific and merge grants stay local.)

`.claude/settings.local.json.example` is a copy-and-edit starter with the common autonomous-build commands.
