#!/usr/bin/env bash
#
# session-end.sh — SessionEnd hook. Writes an end-of-session working-tree
# summary so the next session (and the operator) can see what state was left
# behind — open stashes, uncommitted work — per AGENTS.md #27 (stash hygiene).
#
# Non-blocking by contract: always exits 0.
#
set -uo pipefail

git rev-parse --git-dir >/dev/null 2>&1 || exit 0
dir=".claude/state"
mkdir -p "$dir" 2>/dev/null || true

{
  echo "## Session-end working-tree state"
  echo
  branch=$(git branch --show-current 2>/dev/null || echo detached)
  dirty=$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')
  echo "- Branch \`${branch}\`, ${dirty} uncommitted path(s)"
  st=$(git stash list 2>/dev/null || true)
  if [ -n "$st" ]; then
    echo "- Open stashes (resolve or hand off — AGENTS.md #27):"
    printf '%s\n' "$st" | sed 's/^/    /'
  else
    echo "- No open stashes."
  fi
} 2>/dev/null | tee "$dir/last-session-end.md" 2>/dev/null

exit 0
