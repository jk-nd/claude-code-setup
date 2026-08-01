#!/bin/bash
# PreToolUse[Bash] guard: blocks a short list of catastrophic commands. Exit 2 = block.
# Deliberately narrow — a guard that false-positives trains the agent to route around it.
set -uo pipefail

cmd=$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("tool_input",{}).get("command",""))' 2>/dev/null) || exit 0
[ -z "$cmd" ] && exit 0

block() { echo "guard-catastrophic: blocked: $1" >&2; exit 2; }

case "$cmd" in
  *"rm -rf"*|*"rm -fr"*)
    # allow only under tmp/scratch paths
    echo "$cmd" | grep -qE 'rm -[rf]{2} +("?/(private/)?tmp/|"?\$TMPDIR|"?~/\.cache/)' || block "rm -rf outside tmp"
    ;;
esac
echo "$cmd" | grep -qE 'git push[^|;]*(--force|[^-]-f)( |$)' && block "force push"
echo "$cmd" | grep -qE 'git clean[^|;]*-[a-zA-Z]*f' && block "git clean -f"
echo "$cmd" | grep -qE 'chmod +(-R +)?777' && block "chmod 777"
echo "$cmd" | grep -qE '(mkfs|dd +[^|;]*of=/dev/)' && block "raw device write"
echo "$cmd" | grep -qF ':(){ :|:& };:' && block "fork bomb"

exit 0
