#!/usr/bin/env bash
#
# session-start.sh — SessionStart hook. Loads a bounded snapshot of operating
# state so the orchestrator starts each session already aware of in-flight
# work, instead of relying on memory or re-discovery. Its stdout is injected
# as session context by Claude Code.
#
# Non-blocking by contract: always exits 0 and never errors the session.
#
# Env:
#   ECC_SESSION_START_CONTEXT=off   disable entirely
#   ECC_SESSION_START_MAX_CHARS=N   cap injected context (default 4000)
#
set -uo pipefail

[ "${ECC_SESSION_START_CONTEXT:-on}" = "off" ] && exit 0
git rev-parse --git-dir >/dev/null 2>&1 || exit 0
MAX=${ECC_SESSION_START_MAX_CHARS:-4000}

{
  echo "## Operating context (auto-loaded by session-start hook)"
  echo
  branch=$(git branch --show-current 2>/dev/null)
  echo "- Branch: \`${branch:-detached}\` @ $(git rev-parse --short HEAD 2>/dev/null || echo '?')"
  dirty=$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')
  echo "- Working tree: ${dirty} uncommitted path(s)"
  stashes=$(git stash list 2>/dev/null | wc -l | tr -d ' ')
  [ "${stashes:-0}" -gt 0 ] && echo "- Stashes: ${stashes} open (see \`git stash list\`; resolve or hand off — AGENTS.md #27)"

  if [ -d docs/plan-missions ]; then
    missions=$(grep -rlE '\[[ ~]\]' docs/plan-missions --include='*.md' 2>/dev/null | grep -v '/done/' | head -10 || true)
    if [ -n "${missions}" ]; then
      echo "- In-flight plan-missions (canonical for live state — AGENTS.md #23):"
      while IFS= read -r m; do
        [ -n "$m" ] || continue
        todo=$(grep -cE '^\s*-?\s*\[ \]' "$m" 2>/dev/null || echo 0)
        prog=$(grep -cE '^\s*-?\s*\[~\]' "$m" 2>/dev/null || echo 0)
        echo "  - \`$m\` — ${todo} open, ${prog} in-progress"
      done <<< "$missions"
    fi
  fi

  if [ -f .claude/state/last-session-end.md ]; then
    echo "- Last session ended: see \`.claude/state/last-session-end.md\`"
  fi
  echo
  echo "_Re-read the plan-mission docs before acting; this snapshot is lossy (AGENTS.md #7)._"
} 2>/dev/null | head -c "$MAX"

exit 0
