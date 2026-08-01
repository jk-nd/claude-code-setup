#!/bin/bash
# SessionStart: inject a bounded snapshot of working-tree state so no session starts blind.
# Lifecycle hook — always exit 0.
set -uo pipefail

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0

branch=$(git branch --show-current 2>/dev/null || echo "?")
dirty=$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')
stashes=$(git stash list 2>/dev/null | head -5)
worktrees=$(git worktree list 2>/dev/null | tail -n +2 | wc -l | tr -d ' ')

echo "Working tree: branch=${branch}, uncommitted=${dirty}, extra worktrees=${worktrees}"
if [ -n "$stashes" ]; then
  echo "Open stashes (own or hand off before session end; tag new ones with -m):"
  echo "$stashes"
fi
exit 0
