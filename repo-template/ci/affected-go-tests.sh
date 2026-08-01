#!/bin/bash
# Run Go tests only for packages affected by the diff against $BASE_REF (default origin/main):
# changed packages plus every package whose build OR TEST depends on them.
#
# Uses `go list -test`, which materializes test binaries as packages whose .Deps include
# test-only imports. Plain `go list .Deps` omits them, which silently skips the tests that
# most directly exercise a changed package.
#
# Usage: ci/affected-go-tests.sh [base-ref]   Env: GOTESTFLAGS (default "-race")
set -euo pipefail

base="${1:-origin/main}"
flags="${GOTESTFLAGS:--race}"

merge_base=$(git merge-base "$base" HEAD)
changed_files=$(git diff --name-only "$merge_base" HEAD -- '*.go' 'go.mod' 'go.sum')
if [ -z "$changed_files" ]; then
  echo "no Go changes — skipping tests"
  exit 0
fi
if echo "$changed_files" | grep -qE '^go\.(mod|sum)$'; then
  echo "go.mod/go.sum changed — running full suite"
  exec go test $flags ./...
fi

# Changed packages: map each changed file's directory to its import path. Deleted files leave
# a directory that may no longer exist or no longer be a package — skip those quietly.
changed_pkgs=$(echo "$changed_files" | xargs -n1 dirname | sort -u \
  | while read -r d; do [ -d "$d" ] && go list "./$d" 2>/dev/null || true; done | sort -u)
if [ -z "$changed_pkgs" ]; then
  echo "changed files map to no current package (deletions only) — running full suite"
  exec go test $flags ./...
fi

# A package is affected if it is changed, or if its package OR its test binary depends on a
# changed package. Test-binary entries appear as "<pkg>.test" and "<pkg> [<pkg>.test]" —
# normalize both back to the base import path.
affected=$(go list -test -f '{{.ImportPath}} {{join .Deps " "}}' ./... 2>/dev/null \
  | awk -v changed="$changed_pkgs" '
      BEGIN { n = split(changed, c, "\n"); for (i = 1; i <= n; i++) if (c[i] != "") set[c[i]] = 1 }
      {
        base = $1
        sub(/\.test$/, "", base)
        sub(/\[.*/, "", base)
        gsub(/[ \t]+$/, "", base)
        for (i = 1; i <= NF; i++) {
          dep = $i
          sub(/\.test$/, "", dep)
          sub(/\[.*/, "", dep)
          if (dep in set) { print base; next }
        }
      }' | sort -u)

[ -z "$affected" ] && { echo "no affected packages"; exit 0; }
echo "affected packages ($(echo "$affected" | wc -l | tr -d ' ')):"
echo "$affected"
echo "$affected" | xargs go test $flags
