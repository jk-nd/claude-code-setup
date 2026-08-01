#!/bin/bash
# PreToolUse[Edit|Write] guard: blocks edits to quality-gate configs so checks can't be relaxed to
# force a pass. Escape hatch for legitimate work: GW_ALLOW_CONFIG_EDIT=1. Exit 2 = block.
set -uo pipefail

[ "${GW_ALLOW_CONFIG_EDIT:-0}" = "1" ] && exit 0

path=$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("tool_input",{}).get("file_path",""))' 2>/dev/null) || exit 0
[ -z "$path" ] && exit 0

base=$(basename "$path")
case "$base" in
  .golangci.yml|.golangci.yaml|.golangci.toml|\
  .eslintrc*|eslint.config.*|.prettierrc*|\
  ruff.toml|.flake8|setup.cfg|tox.ini|\
  .editorconfig|.markdownlint.json|coverage-baseline.json)
    echo "guard-config: '$base' is a quality gate. If this edit is legitimate (not relaxing a check to pass), re-run with GW_ALLOW_CONFIG_EDIT=1 and say so in the PR." >&2
    exit 2
    ;;
esac
exit 0
