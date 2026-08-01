#!/bin/bash
# Local tripwire: refuse to commit changes to the contract artifacts or the quality gates.
#
# This is the backstop for what the PreToolUse guard structurally cannot cover. That guard matches
# the Edit/Write TOOLS, so a shell redirect, `sed -i`, another editor, or another agent bypasses it.
# A commit hook sees the staged tree regardless of how the change got there.
#
# Blocks acceptance/**, rubrics/**, and quality-gate configs — including deletions and renames,
# since moving the contract out of the way is worse than editing it.
#
# Install (from the repo root):
#   ln -sf ../../ci/pre-commit.sh .git/hooks/pre-commit
# Escape (per command, unlike the PreToolUse guard):
#   GW_ALLOW_CONFIG_EDIT=1 git commit -m "..."
set -uo pipefail

[ "${GW_ALLOW_CONFIG_EDIT:-0}" = "1" ] && exit 0

blocked=()
# --no-renames: a rename shows both source and destination, so moving a file OUT of acceptance/
# is caught. -z + read -d '': paths containing spaces or quotes are handled correctly.
while IFS= read -r -d '' f; do
  [ -z "$f" ] && continue
  case "$f" in
    acceptance/*|*/acceptance/*|rubrics/*|*/rubrics/*)
      blocked+=("$f  — contract artifact"); continue ;;
  esac
  # basename, so nested configs are caught too, and the list matches guard-config.sh exactly.
  case "${f##*/}" in
    .golangci.yml|.golangci.yaml|.golangci.toml|\
    .eslintrc*|eslint.config.*|.prettierrc*|\
    ruff.toml|.flake8|setup.cfg|tox.ini|\
    .editorconfig|.markdownlint.json|coverage-baseline.json)
      blocked+=("$f  — quality gate") ;;
  esac
done < <(git diff --cached --no-renames --name-only -z)

[ ${#blocked[@]} -eq 0 ] && exit 0

{
  echo
  echo "pre-commit: refusing to commit changes to the contract or the quality gates:"
  printf '  %s\n' "${blocked[@]}"
  echo
  echo "  Acceptance tests and rubrics define what 'done' means. An implementation that edits its"
  echo "  own contract proves nothing — a wrong acceptance test is a criteria change, routed back"
  echo "  through criteria-author. Relaxing a quality gate is a decision, not a fixup."
  echo
  echo "  If this edit is legitimate:"
  echo "      GW_ALLOW_CONFIG_EDIT=1 git commit ...      (and say why in the PR)"
  echo
} >&2
exit 1
