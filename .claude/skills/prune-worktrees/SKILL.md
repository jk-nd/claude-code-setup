---
name: prune-worktrees
description: Safely clean up leftover agent dispatch worktrees and their ephemeral branches (worktree-agent-*) without losing in-flight work. Use when worktrees or stale branches have accumulated — e.g. "prune the agent worktrees", "clean up stale branches", "git worktree list is huge". Dry-run by default; only deletes when told to.
---

# prune-worktrees

Orchestrator dispatch worktrees and their `worktree-agent-*` branches accumulate fast (real projects hit 40+ worktrees and 55+ stale branches). Cleaning them up by hand is easy to get wrong: blindly deleting unmerged branches loses work, removing an *active* worktree breaks in-flight work, and squash-merge makes `git branch --merged` under-report what's safe to delete. This skill encodes the safe procedure.

## How to run it

```bash
# Dry-run — shows exactly what WOULD be removed, deletes nothing:
.claude/skills/prune-worktrees/prune-worktrees.sh

# Actually remove the REMOVABLE entries:
.claude/skills/prune-worktrees/prune-worktrees.sh --apply
```

Optional flags: `--prefix <p>` (ephemeral branch prefix, default `worktree-agent-`), `--base <ref>` (what "merged" is judged against, default `origin/main`, fallback `main`).

## What it does, and the safety rules

1. Runs `git worktree prune` to drop records for worktrees whose directories are already gone.
2. Writes a **recovery manifest** (`<git-dir>/prune-manifests/prune-<ts>.txt`) listing every matching branch's tip SHA + date + subject **before** deleting anything. A wrongly deleted branch is recoverable from the SHA (reflog / `git fsck`); the manifest names it.
3. Classifies each `worktree-agent-*` branch and only deletes the safe ones. It **never**:
   - touches a branch checked out in a live worktree that is **dirty** (uncommitted changes) or **unmerged** (commits not in base) — that's in-flight work, left and reported;
   - touches **co-tenant** branches (`codex/*`);
   - touches anything outside the ephemeral prefix.
4. Orphaned ephemeral branches (no live worktree) are removed — merged ones outright, unmerged ones with the manifest as the safety net.
5. Prints a PROTECTED list (what was left and why) and a REMOVABLE list.

**Default is dry-run.** Review the REMOVABLE list, then re-run with `--apply`. Idempotent — running it again after an apply is a no-op.

## When to use / not use

Use it as periodic hygiene after a fan-out of implementers, or when `git worktree list` / the branch list has grown unwieldy. Don't use it to delete a *specific* known branch — just `git branch -D` that one. This skill is for safe bulk cleanup where you don't want to eyeball each branch's merge state.
