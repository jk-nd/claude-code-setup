#!/bin/bash
# SessionStart: give the model a bounded snapshot of working-tree state so no session starts blind.
# SessionStart stdout is NOT injected into context — the model only sees text returned via
# hookSpecificOutput.additionalContext, so emit JSON. Lifecycle hook: always exit 0.
set -uo pipefail

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0

branch=$(git branch --show-current 2>/dev/null || echo "?")
dirty=$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')
worktrees=$(git worktree list 2>/dev/null | tail -n +2 | wc -l | tr -d ' ')
stashes=$(git stash list 2>/dev/null | head -5)

ctx="Working tree: branch=${branch}, uncommitted files=${dirty}, extra worktrees=${worktrees}."
if [ -n "$stashes" ]; then
  ctx="${ctx}
Open stashes (own or hand them off before the session ends; tag new ones with -m):
${stashes}"
fi

if command -v jq >/dev/null 2>&1; then
  jq -n --arg ctx "$ctx" '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx}}'
else
  python3 - "$ctx" <<'PY' 2>/dev/null || true
import json, sys
print(json.dumps({"hookSpecificOutput": {"hookEventName": "SessionStart",
                                         "additionalContext": sys.argv[1]}}))
PY
fi
exit 0
