#!/bin/bash
# Run Go tests only for packages affected by the diff against $BASE_REF (default origin/main):
# changed packages plus everything that imports them (reverse dependency closure).
# Usage: ci/affected-go-tests.sh [base-ref]   Env: GOTESTFLAGS (default "-race")
set -euo pipefail

base="${1:-origin/main}"
flags="${GOTESTFLAGS:--race}"
module=$(go list -m)

changed_files=$(git diff --name-only "$(git merge-base "$base" HEAD)" HEAD -- '*.go' 'go.mod' 'go.sum')
if [ -z "$changed_files" ]; then
  echo "no Go changes — skipping tests"
  exit 0
fi
if echo "$changed_files" | grep -qE '^go\.(mod|sum)$'; then
  echo "go.mod/go.sum changed — running full suite"
  exec go test $flags ./...
fi

changed_pkgs=$(echo "$changed_files" | xargs -n1 dirname | sort -u \
  | while read -r d; do go list "./$d" 2>/dev/null || true; done | sort -u)
[ -z "$changed_pkgs" ] && { echo "changed files map to no packages — skipping"; exit 0; }

# One pass over the module: keep packages that are changed or depend on a changed package.
affected=$(go list -f '{{.ImportPath}} {{join .Deps " "}}' ./... \
  | awk -v changed="$changed_pkgs" '
      BEGIN { n = split(changed, c, "\n"); for (i = 1; i <= n; i++) set[c[i]] = 1 }
      { for (i = 1; i <= NF; i++) if ($i in set) { print $1; next } }' \
  | sort -u)

echo "affected packages ($(echo "$affected" | wc -l | tr -d ' ')):"
echo "$affected"
echo "$affected" | xargs go test $flags
