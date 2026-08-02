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

# How involved does this operator want to be? Read it from disk, or make the session ask once.
# Without this the default is silence: a long run front-loads its questions into the design phase
# and then goes dark for hours, which is right for some operators and wrong for others.
mode_file=".claude/involvement"
if [ -f "$mode_file" ]; then
  mode=$(head -1 "$mode_file" | tr -d '[:space:]')
  case "$mode" in
    gated)      ctx="${ctx}
Operator involvement: GATED. Stop for approval at the approach, at the criteria, and before every
merge. Surface decisions rather than recording them for later." ;;
    checkpoint) ctx="${ctx}
Operator involvement: CHECKPOINT. Approval at the approach and the criteria; after that report at
each phase boundary (criteria written, build green, review returned) and continue without waiting.
Stop mid-phase only for a decision that is hard to reverse." ;;
    autonomous) ctx="${ctx}
Operator involvement: AUTONOMOUS. Approval at the approach only, then run. Surface each decision
the operator may want to reverse AT THE TIME you make it, in one line — not only in the final
report. Stop for anything irreversible, security-relevant, or outside the agreed scope." ;;
    *)          ctx="${ctx}
Operator involvement: '${mode}' is not a recognised mode (gated|checkpoint|autonomous). Ask the
operator which they want and rewrite ${mode_file}." ;;
  esac
else
  ctx="${ctx}
Operator involvement is NOT SET. Before starting the first substantial piece of work, ask the
operator how involved they want to be — gated (approve approach, criteria, and every merge),
checkpoint (approve approach and criteria, then reports at phase boundaries), or autonomous
(approve the approach, then run and surface reversible decisions as they happen). Write the single
word to ${mode_file} so later sessions inherit it. Ask once; do not re-ask every session."
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
