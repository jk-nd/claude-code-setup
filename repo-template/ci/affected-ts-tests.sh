#!/bin/bash
# Run TypeScript/JavaScript tests affected by the diff against $BASE_REF (default origin/main).
#
# Uses the runner's own impact analysis — `vitest related` / `jest --findRelatedTests` — because
# both resolve the real import graph. There is deliberately no filename-based fallback: guessing
# which test covers a module reports green while skipping the test that would have failed. If no
# supported runner is detected, this runs the full suite.
#
# Usage: ci/affected-ts-tests.sh [base-ref]
# Env:   PKG_MANAGER (auto-detected), TEST_SCRIPT (default "test")
set -euo pipefail

base="${1:-origin/main}"
test_script="${TEST_SCRIPT:-test}"
merge_base=$(git merge-base "$base" HEAD 2>/dev/null || echo "$base")

pm="${PKG_MANAGER:-}"
if [ -z "$pm" ]; then
  if   [ -f pnpm-lock.yaml ];     then pm=pnpm
  elif [ -f yarn.lock ];          then pm=yarn
  elif [ -f bun.lockb ];          then pm=bun
  else                                 pm=npm
  fi
fi
run_full() { echo "running full suite via $pm"; exec "$pm" run "$test_script"; }

# --no-renames so a moved module shows its old path too.
changed=$(git diff --no-renames --name-only "$merge_base" HEAD \
  -- '*.ts' '*.tsx' '*.js' '*.jsx' '*.mts' '*.cts' '*.mjs' '*.cjs' '*.vue' '*.svelte' \
     'package.json' '**/package.json' 'pnpm-lock.yaml' 'package-lock.json' 'yarn.lock' 'bun.lockb' \
     'tsconfig*.json' '**/tsconfig*.json')

if [ -z "$changed" ]; then
  echo "no TS/JS changes — skipping tests"
  exit 0
fi

# Manifest / lockfile / tsconfig changes can affect anything — matched at any depth so a monorepo
# package's own package.json counts, not just the root one.
if echo "$changed" | grep -qE '(^|/)(package\.json|pnpm-lock\.yaml|package-lock\.json|yarn\.lock|bun\.lockb|tsconfig[^/]*\.json)$'; then
  echo "manifest/lockfile/tsconfig changed — running everything"
  run_full
fi

# Only pass files that still exist: a deleted path makes both runners error out.
existing=()
while IFS= read -r f; do
  [ -n "$f" ] && [ -f "$f" ] && existing+=("$f")
done <<< "$changed"

if [ ${#existing[@]} -eq 0 ]; then
  echo "all changed files were deleted — running everything"
  run_full
fi

echo "changed source files (${#existing[@]}):"
printf '  %s\n' "${existing[@]}"

has_vitest=false
for c in vitest.config.ts vitest.config.js vitest.config.mts vitest.config.mjs vite.config.ts vite.config.js; do
  [ -f "$c" ] && { has_vitest=true; break; }
done
grep -q '"vitest"' package.json 2>/dev/null && has_vitest=true

has_jest=false
for c in jest.config.js jest.config.ts jest.config.mjs jest.config.cjs jest.config.json; do
  [ -f "$c" ] && { has_jest=true; break; }
done
grep -q '"jest"' package.json 2>/dev/null && has_jest=true

if [ "$has_vitest" = true ]; then
  echo "vitest: running tests related to the changed files"
  exec npx --no-install vitest related --run "${existing[@]}"
fi

if [ "$has_jest" = true ]; then
  echo "jest: running tests related to the changed files"
  exec npx --no-install jest --findRelatedTests --passWithNoTests "${existing[@]}"
fi

echo "no vitest or jest detected — not guessing which tests cover these files"
run_full
