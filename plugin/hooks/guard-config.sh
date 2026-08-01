#!/bin/bash
# PreToolUse[Edit|Write] guard. Blocks edits to two classes of file:
#   1. quality-gate configs — so a failing check can't be made to pass by relaxing the check;
#   2. contract artifacts (acceptance tests, rubrics) — so the agent being measured can't edit
#      the thing measuring it. Changing those is a criteria change, routed to criteria-author.
#
# Escape hatch: GW_ALLOW_CONFIG_EDIT=1. It is read from the environment the `claude` process was
# STARTED with — not per tool call — so use it by launching a session with the var exported, or by
# adding it to the `env` block in settings. criteria-author is exempt automatically: it works on
# its own worktree before an implementation exists, and its writes land via that dispatch.
#
# Honest limits: this matches Edit|Write only. A shell redirect, `sed -i`, or `tee` from Bash is
# not covered — a matcher cannot see inside a command string. CI is the backstop that does:
# acceptance tests run tagged in their own job, and the reviewer checks whether the diff touched
# the contract. Treat this as a tripwire against accident, not a barrier against intent.
set -uo pipefail

[ "${GW_ALLOW_CONFIG_EDIT:-0}" = "1" ] && exit 0

path=$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("tool_input",{}).get("file_path",""))' 2>/dev/null) || exit 0
[ -z "$path" ] && exit 0

block() {
  echo "guard-config: $1" >&2
  exit 2
}

case "$path" in
  */acceptance/*|acceptance/*)
    block "'$path' is an acceptance test — the contract this change is measured against. If it is
wrong, that is a criteria change: return needs-clarification with the failing output and let
criteria-author judge behavior-vs-wording." ;;
  */rubrics/*|rubrics/*)
    block "'$path' is a rubric — the definition of done. Only criteria-author edits it." ;;
esac

case "$(basename "$path")" in
  .golangci.yml|.golangci.yaml|.golangci.toml|\
  .eslintrc*|eslint.config.*|.prettierrc*|\
  ruff.toml|.flake8|setup.cfg|tox.ini|\
  .editorconfig|.markdownlint.json|coverage-baseline.json)
    block "'$(basename "$path")' is a quality gate. If this edit is legitimate (not relaxing a
check to make it pass), re-launch with GW_ALLOW_CONFIG_EDIT=1 exported and say so in the PR." ;;
esac
exit 0
