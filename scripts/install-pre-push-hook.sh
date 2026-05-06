#!/usr/bin/env bash
# install-pre-push-hook.sh — drop-in installer for the strict-recipe
# pre-push gate.
#
# What it does:
#
#   Writes `.git/hooks/pre-push` (and chmods it +x) with a hook that
#   refuses the push when the working tree is dirty AND re-runs the
#   strict verification recipe (build + vet + short-test + go mod tidy
#   diff) against the to-be-pushed commit. This addresses two failure
#   modes that ate hours during the 2026-04-26/27 operating-day:
#
#     1. Agent verifies on uncommitted working-tree changes, then
#        commits an OLDER snapshot and pushes — CI catches the divergence
#        post-push instead of pre-push. The dirty-tree check makes that
#        impossible: you commit first, the hook then verifies the
#        committed state.
#
#     2. Agent skips `go mod tidy && git diff --exit-code go.mod go.sum`
#        and pushes a PR that's red on CI immediately. The hook runs
#        the same check pre-push so the failure surfaces at push time.
#
# The hook is local — it lives in `.git/hooks/`, which is NOT committed
# to the repo. Each developer / agent must run this installer once.
# Templates / setup scripts can chain into it; this script is what they
# call.
#
# Usage:
#
#   ./scripts/install-pre-push-hook.sh
#
# Re-running is safe — the script overwrites the existing hook.
#
# To uninstall:
#
#   rm .git/hooks/pre-push
#
# The recipe below is Go-flavoured (matches the template's example
# `ci.yml.template`). Adapt the `set -e ...` line for your project's
# language / test runner if you replaced the example CI; the dirty-tree
# check at the top is language-agnostic and worth keeping verbatim.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
HOOKS_DIR="$REPO_ROOT/.git/hooks"
HOOK_PATH="$HOOKS_DIR/pre-push"

if [ ! -d "$REPO_ROOT/.git" ]; then
    echo "error: $REPO_ROOT/.git does not exist; this is not a git repo." >&2
    exit 1
fi

mkdir -p "$HOOKS_DIR"

cat > "$HOOK_PATH" <<'HOOK'
#!/usr/bin/env bash
# pre-push — strict-recipe verification gate.
#
# Refuses the push when:
#   1. The working tree has uncommitted changes (porcelain non-empty).
#   2. `go build ./...` fails.
#   3. `go vet ./...` fails.
#   4. Short tests fail.
#   5. `go mod tidy` produces a diff to `go.mod` / `go.sum`.
#
# The dirty-tree check at the top is the most important — it forces the
# user to commit before verifying, eliminating the failure mode where
# verification ran on an older snapshot than the one being pushed.
#
# Bypass (use sparingly):
#   git push --no-verify
#
# Adapt for non-Go stacks: replace the `go ...` lines with your build /
# test / lint commands. Keep the dirty-tree check verbatim.

set -e

if [ -n "$(git status --porcelain)" ]; then
    echo "pre-push: uncommitted changes; commit first then push" >&2
    git status --short >&2
    exit 1
fi

# Skip if there is no Go code in the repo (template-instantiation
# checkpoint where the operator has not yet written Go). The hook still
# enforces the dirty-tree check above.
if ! ls **/*.go 2>/dev/null | head -1 >/dev/null && ! ls *.go 2>/dev/null | head -1 >/dev/null; then
    echo "pre-push: no .go files detected; skipping Go-specific gates"
    exit 0
fi

go build ./...
go vet ./...
go test -short -timeout=300s -count=1 ./...
go mod tidy
git diff --exit-code go.mod go.sum
HOOK

chmod +x "$HOOK_PATH"

echo "pre-push hook installed at: $HOOK_PATH"
echo
echo "On the next 'git push' the hook will:"
echo "  1. Refuse if working tree is dirty (commit first)."
echo "  2. Run go build / vet / short test against committed state."
echo "  3. Run 'go mod tidy' and reject if go.mod / go.sum diverge."
echo
echo "Bypass (use sparingly): git push --no-verify"
echo "Uninstall: rm $HOOK_PATH"
