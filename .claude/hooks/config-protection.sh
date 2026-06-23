#!/usr/bin/env bash
#
# config-protection.sh — PreToolUse guard for Edit/Write/MultiEdit.
#
# Blocks edits to quality-gate config files (linters, formatters, coverage
# baselines). The failure mode this prevents: an agent relaxing the linter or
# coverage gate to make a red check pass, instead of fixing the code.
#
# Protocol: exit 0 = allow; exit 2 = block (stderr is fed back to the model).
# Escape hatch: set ECC_ALLOW_CONFIG_EDIT=1 for a deliberate config change.
#
set -uo pipefail

[ "${ECC_ALLOW_CONFIG_EDIT:-0}" = "1" ] && exit 0

path=$(cat | python3 -c "import sys,json
try: print(json.load(sys.stdin).get('tool_input',{}).get('file_path',''))
except Exception: print('')" 2>/dev/null)
[ -n "$path" ] || exit 0

base=$(basename "$path")
case "$base" in
  .golangci.yml|.golangci.yaml|.eslintrc|.eslintrc.*|.prettierrc|.prettierrc.*|\
ruff.toml|.ruff.toml|.editorconfig|.markdownlint.json|setup.cfg|tox.ini|.flake8)
    blocked=1 ;;
  *) blocked=0 ;;
esac
case "$path" in */ops/coverage-baseline.json) blocked=1 ;; esac

if [ "$blocked" = "1" ]; then
  echo "config-protection: editing a quality-gate config ($base) is blocked." >&2
  echo "Fix the code rather than relaxing the gate. If this is a deliberate, reviewed config change, set ECC_ALLOW_CONFIG_EDIT=1 and retry." >&2
  exit 2
fi
exit 0
