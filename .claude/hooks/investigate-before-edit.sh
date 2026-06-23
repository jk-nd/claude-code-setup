#!/usr/bin/env bash
#
# investigate-before-edit.sh — EXPERIMENTAL, OFF BY DEFAULT. PreToolUse guard
# (Edit|Write|MultiEdit). On the first edit to a given file (per checkout) it
# blocks once with a reminder to investigate the file's importers / callers /
# data flow, then allows the retry. Encodes "investigate before you touch it."
#
# Costs one extra round-trip the first time each file is edited; enable
# deliberately. Disable at runtime with ECC_INVESTIGATE_GATE=off.
#
# Protocol: exit 0 = allow; exit 2 = block (stderr fed back to the model).
#
set -uo pipefail

[ "${ECC_INVESTIGATE_GATE:-on}" = "off" ] && exit 0
git rev-parse --git-dir >/dev/null 2>&1 || exit 0

path=$(cat | python3 -c "import sys,json
try: print(json.load(sys.stdin).get('tool_input',{}).get('file_path',''))
except Exception: print('')" 2>/dev/null)
[ -n "$path" ] || exit 0

dir=".claude/state"
mkdir -p "$dir" 2>/dev/null || exit 0
seen="$dir/investigated.txt"
touch "$seen" 2>/dev/null || exit 0

if grep -qxF "$path" "$seen" 2>/dev/null; then
  exit 0
fi
echo "$path" >> "$seen"
echo "investigate-before-edit: first edit to $path this checkout." >&2
echo "Before changing it, confirm you've checked who imports/calls it, what data flows through it, and which tests cover it. Re-issue the edit to proceed (this gate won't fire again for this file)." >&2
exit 2
