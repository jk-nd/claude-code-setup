#!/bin/bash
# PreToolUse[Edit|Write] guard. Blocks two classes of edit:
#   1. quality-gate configs — so a failing check can't be made to pass by relaxing the check;
#   2. contract artifacts (acceptance/**, rubrics/**) — so the agent being measured cannot edit the
#      thing measuring it.
#
# (2) is gated on WHO is calling. A PreToolUse payload carries `agent_type` when the call comes
# from a subagent, so criteria-author — whose entire job is to write the contract — is allowed,
# while implementer, reviewer, and the main session are not. Blocking criteria-author outright is
# not a safe default: it pushes the agent into writing files elsewhere and copying them in, which
# is indistinguishable from evasion and trips the very alarms this guard exists to raise.
#
# Escape hatch: GW_ALLOW_CONFIG_EDIT=1. Read from the environment the `claude` process was STARTED
# with — not per tool call — so export it at launch or put it in the `env` block in settings.
# Debug what the hook actually receives: GW_GUARD_DEBUG=1 appends payloads to /tmp/gw-guard.log
#
# Honest limits: this matches the Edit|Write TOOLS. A shell redirect, `sed -i`, or `tee` from Bash
# is not covered — a matcher cannot see inside a command string. The backstops that can: the
# pre-commit hook (sees the staged tree however it got there), CI (runs the tagged acceptance
# suite), and the reviewer (reports a diff that touched its own contract).
set -uo pipefail

[ "${GW_ALLOW_CONFIG_EDIT:-0}" = "1" ] && exit 0

payload=$(cat)
[ "${GW_GUARD_DEBUG:-0}" = "1" ] && printf '%s\n' "$payload" >> /tmp/gw-guard.log

read -r path agent <<EOF
$(printf '%s' "$payload" | python3 -c '
import json, sys
try: d = json.load(sys.stdin)
except Exception: print(" "); raise SystemExit
p = (d.get("tool_input") or {}).get("file_path", "") or "-"
# agent_type is present only for subagent calls; may be plugin-scoped ("groundwork:criteria-author")
a = d.get("agent_type") or "-"
print(p, a.split(":")[-1])
' 2>/dev/null)
EOF

[ -z "${path:-}" ] || [ "${path:-}" = "-" ] && exit 0

block() { echo "guard-config: $1" >&2; exit 2; }

case "$path" in
  */acceptance/*|acceptance/*|*/rubrics/*|rubrics/*)
    if [ "${agent:-}" = "criteria-author" ]; then
      exit 0        # the contract's author, working before an implementation exists
    fi
    block "'$path' is a contract artifact — the definition of done this change is measured
against, and you are not criteria-author. If the contract is wrong, that is a criteria change:
return needs-clarification with the failing test output and let criteria-author judge whether the
behaviour or only the wording was off. Do NOT write it elsewhere and copy it in: that is the same
edit with the evidence removed." ;;
esac

case "${path##*/}" in
  .golangci.yml|.golangci.yaml|.golangci.toml|\
  .eslintrc*|eslint.config.*|.prettierrc*|\
  ruff.toml|.flake8|setup.cfg|tox.ini|\
  .editorconfig|.markdownlint.json|coverage-baseline.json)
    block "'${path##*/}' is a quality gate. If this edit is legitimate (not relaxing a check to
make it pass), re-launch with GW_ALLOW_CONFIG_EDIT=1 exported and say so in the PR." ;;
esac
exit 0
