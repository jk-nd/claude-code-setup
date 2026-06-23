#!/usr/bin/env bash
#
# pre-compact.sh — PreCompact hook. Persists a snapshot of session state to
# disk just before Claude Code compacts the context window, so anything the
# orchestrator was holding (branch, uncommitted work, stashes, recent
# activity) survives compaction and can be reloaded.
#
# Non-blocking by contract: always exits 0.
#
set -uo pipefail

git rev-parse --git-dir >/dev/null 2>&1 || exit 0
dir=".claude/state"
mkdir -p "$dir" 2>/dev/null || exit 0

{
  echo "# Pre-compaction snapshot"
  echo
  echo "- Branch: $(git branch --show-current 2>/dev/null || echo detached) @ $(git rev-parse --short HEAD 2>/dev/null || echo '?')"
  echo
  echo "## Uncommitted paths"
  git status --porcelain 2>/dev/null | head -80 | sed 's/^/    /' || true
  echo
  echo "## Stashes"
  git stash list 2>/dev/null | sed 's/^/    /' || true
  echo
  echo "## Recent commits"
  git log --oneline -10 2>/dev/null | sed 's/^/    /' || true
} > "$dir/last-precompact.md" 2>/dev/null

exit 0
