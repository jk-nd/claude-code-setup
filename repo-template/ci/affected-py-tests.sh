#!/bin/bash
# Run Python tests affected by the diff against $BASE_REF (default origin/main).
#
# Design note — why there is no filename heuristic here: matching `utils.py` to `test_utils.py`
# looks like impact analysis but isn't. `test_api.py` may import utils and never run, so the suite
# reports green having skipped the test that would have failed. Silent under-verification is worse
# than a slow CI job. Python has no cheap sound closure the way `go list -test` gives one, so this
# script uses pytest-testmon when it is available and RUNS EVERYTHING when it is not.
#
# Usage: ci/affected-py-tests.sh [base-ref]
# Env:   PYTEST (default "pytest"), PYTEST_ARGS
set -euo pipefail

base="${1:-origin/main}"
pytest_cmd="${PYTEST:-pytest}"
extra="${PYTEST_ARGS:-}"

merge_base=$(git merge-base "$base" HEAD 2>/dev/null || echo "$base")

# --no-renames so a moved module shows its old path too.
changed=$(git diff --no-renames --name-only "$merge_base" HEAD \
  -- '*.py' 'pyproject.toml' 'setup.py' 'setup.cfg' 'requirements*.txt' \
     'Pipfile.lock' 'poetry.lock' 'uv.lock' 'tox.ini' 'conftest.py' '**/conftest.py')

if [ -z "$changed" ]; then
  echo "no Python changes — skipping tests"
  exit 0
fi

# Dependency, config, or conftest changes can affect anything: run everything. Matched anywhere in
# the tree, not just at the root, so a monorepo package's pyproject.toml still triggers it.
if echo "$changed" | grep -qE '(^|/)(pyproject\.toml|setup\.py|setup\.cfg|tox\.ini|conftest\.py|requirements[^/]*\.txt|Pipfile\.lock|poetry\.lock|uv\.lock)$'; then
  echo "dependency/config/conftest changed — running full suite"
  exec $pytest_cmd $extra
fi

echo "changed Python files ($(echo "$changed" | wc -l | tr -d ' ')):"
echo "$changed"

# testmon tracks which tests execute which lines, so it selects a sound subset. It needs its
# .testmondata database to be restored between CI runs (cache it, keyed on the base commit);
# with no database it simply runs everything and builds one, which is correct but not faster.
if $pytest_cmd --help 2>/dev/null | grep -q -- '--testmon'; then
  if [ -f .testmondata ]; then
    echo "running pytest with testmon impact analysis"
  else
    echo "running pytest with testmon (no database yet — this run is a full run that builds it;"
    echo "cache .testmondata between CI runs to get selection on subsequent runs)"
  fi
  exec $pytest_cmd --testmon $extra
fi

echo "pytest-testmon not installed — running the full suite."
echo "  (Install it for real impact analysis: pip install pytest-testmon)"
exec $pytest_cmd $extra
