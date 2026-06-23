#!/usr/bin/env bash
#
# safety-guard.sh — PreToolUse guard for Bash. Blocks a small, conservative set
# of unambiguously catastrophic commands as a runtime backstop to the static
# deny-list in settings.json — for unattended/overnight operation.
#
# Deliberately narrow: it only blocks commands that are never legitimate in the
# operating loop, so it cannot derail normal autonomous work. (The orchestrator
# DOES legitimately run `git reset --hard origin/main` to sync — that is NOT
# blocked.)
#
# Protocol: exit 0 = allow; exit 2 = block (stderr fed back to the model).
#
set -uo pipefail

cmd=$(cat | python3 -c "import sys,json
try: print(json.load(sys.stdin).get('tool_input',{}).get('command',''))
except Exception: print('')" 2>/dev/null)
[ -n "$cmd" ] || exit 0

block() {
  echo "safety-guard: blocked — $1" >&2
  echo "Command: $cmd" >&2
  echo "If this is genuinely intended, run it yourself; the agent must not." >&2
  exit 2
}

# rm -rf / -fr of anything that is NOT under a temp/scratch dir.
if printf '%s' "$cmd" | grep -qE '\brm\b[[:space:]]+-[a-zA-Z]*[rf][a-zA-Z]*[rf]?'; then
  if ! printf '%s' "$cmd" | grep -qE '(/tmp/|/private/tmp/|scratchpad|\$TMPDIR)'; then
    block "rm -rf outside a temp directory"
  fi
fi

printf '%s' "$cmd" | grep -qE '\bgit[[:space:]]+push\b.*(--force([^-]|$)|[[:space:]]-f([[:space:]]|$))' \
  && block "git push --force (history rewrite on a shared branch)"
printf '%s' "$cmd" | grep -qE '\bgit[[:space:]]+clean\b[[:space:]]+-[a-zA-Z]*f' \
  && block "git clean -f (deletes untracked files irreversibly)"
printf '%s' "$cmd" | grep -qE '\bchmod\b[[:space:]]+-R[[:space:]]+0?777' \
  && block "chmod -R 777"
printf '%s' "$cmd" | grep -qE '\bmkfs\b|\bdd\b[[:space:]].*\bof=/dev/' \
  && block "filesystem/device write"
printf '%s' "$cmd" | grep -qE ':\(\)[[:space:]]*\{[[:space:]]*:[[:space:]]*\|[[:space:]]*:' \
  && block "fork bomb"

exit 0
