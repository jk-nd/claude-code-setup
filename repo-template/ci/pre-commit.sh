#!/bin/bash
# Local tripwire: refuse to commit changes that weaken the thing measuring the change.
#
# This is the backstop for what the PreToolUse guard structurally cannot cover. That guard matches
# the Edit/Write TOOLS, so a shell redirect, `sed -i`, another editor, or another agent bypasses it.
# A commit hook sees the staged tree regardless of how the change got there.
#
# Blocks:
#   1. acceptance/**, rubrics/** — the contract; edits route through criteria-author.
#   2. quality-gate configs — so a failing check isn't made to pass by relaxing the check.
#   3. DELETING or EMPTYING a test file — the "make the failing test disappear" move.
#      Editing and adding tests stays allowed: an implementer must be able to write its own unit
#      tests, and consolidating cases into a table-driven test is a normal refactor. Only removal
#      of the file, or gutting it to zero test functions, is treated as evasion.
#
# Install (from the repo root):
#   ln -sf ../../ci/pre-commit.sh .git/hooks/pre-commit
# Escape (per command, and the right move when a feature is genuinely being removed):
#   GW_ALLOW_CONFIG_EDIT=1 git commit -m "..."
set -uo pipefail

[ "${GW_ALLOW_CONFIG_EDIT:-0}" = "1" ] && exit 0

is_test_file() {
  case "${1##*/}" in
    *_test.go|test_*.py|*_test.py|*.test.ts|*.test.tsx|*.test.js|*.test.jsx|\
    *.spec.ts|*.spec.tsx|*.spec.js|*.spec.jsx) return 0 ;;
  esac
  return 1
}

# Count test functions in text on stdin, by extension.
count_tests() {
  case "$1" in
    *.go)              grep -cE '^func (Test|Benchmark|Fuzz|Example)[A-Z_]' ;;
    *.py)              grep -cE '^[[:space:]]*(async[[:space:]]+)?def test' ;;
    *.ts|*.tsx|*.js|*.jsx) grep -cE '\b(it|test)[[:space:]]*\(' ;;
    *)                 grep -c '' ;;
  esac
}

blocked=()
while IFS= read -r -d '' st && IFS= read -r -d '' f; do
  [ -z "$f" ] && continue

  case "$f" in
    acceptance/*|*/acceptance/*|rubrics/*|*/rubrics/*)
      blocked+=("$f  — contract artifact"); continue ;;
  esac

  case "${f##*/}" in
    .golangci.yml|.golangci.yaml|.golangci.toml|\
    .eslintrc*|eslint.config.*|.prettierrc*|\
    ruff.toml|.flake8|setup.cfg|tox.ini|\
    .editorconfig|.markdownlint.json|coverage-baseline.json)
      blocked+=("$f  — quality gate"); continue ;;
  esac

  if is_test_file "$f"; then
    if [ "$st" = "D" ]; then
      blocked+=("$f  — deleting a test file")
    elif [ "$st" = "M" ]; then
      # `grep -c` prints 0 AND exits 1 on no match, so a `|| echo 0` fallback would append a
      # second line and break the numeric test. Take the first line and keep only digits.
      before=$(git show "HEAD:$f" 2>/dev/null | count_tests "$f" | head -1 | tr -dc '0-9')
      after=$(git show ":$f"      2>/dev/null | count_tests "$f" | head -1 | tr -dc '0-9')
      if [ "${before:-0}" -gt 0 ] && [ "${after:-0}" -eq 0 ]; then
        blocked+=("$f  — emptying a test file (${before} test functions -> 0)")
      fi
    fi
  fi
done < <(git diff --cached --no-renames --name-status -z)

[ ${#blocked[@]} -eq 0 ] && exit 0

{
  echo
  echo "pre-commit: refusing to commit — this change weakens what measures it:"
  printf '  %s\n' "${blocked[@]}"
  echo
  echo "  A failing test is information, not an obstacle. Deleting or emptying it makes the signal"
  echo "  disappear, not the defect. Acceptance tests and rubrics define what 'done' means, so an"
  echo "  implementation that edits its own contract proves nothing; relaxing a quality gate is a"
  echo "  decision, not a fixup."
  echo
  echo "  Editing and adding tests is fine — only removal is blocked here."
  echo "  If the removal is legitimate (the feature is genuinely gone):"
  echo "      GW_ALLOW_CONFIG_EDIT=1 git commit ...      (and say why in the PR)"
  echo
} >&2
exit 1
