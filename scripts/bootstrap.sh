#!/usr/bin/env bash
# bootstrap.sh — one-shot (and idempotent) setup script for a repo
# instantiated from claude-code-setup.
#
# What it does:
#   1. Detect owner + name from `gh repo view`.
#   2. Prompt for the comma-separated list of compliance-sensitive
#      paths (e.g. internal/policy/,internal/audit/).
#   3. Substitute ${OWNER}, ${REPO}, ${WATCHED_PATHS},
#      ${WATCHED_PATHS_AS_CODEOWNER_LINES} placeholders across
#      *.template files and inline placeholders.
#   4. Rename *.template -> their non-template name.
#   5. Prompt for ANTHROPIC_API_KEY and set via `gh secret set`
#      (empty input skips this step).
#   6. Create the `compliance-review` label via `gh api`.
#   7. Optionally create initial branch protection on `main`.
#
# The script is safe to re-run. On re-run, *.template files have
# already been renamed away; the script handles this gracefully and
# only re-applies steps where the underlying state has changed.

set -euo pipefail

# ---------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------

prompt_default() {
    local prompt="$1"
    local default="${2:-}"
    local reply
    if [ -n "$default" ]; then
        printf "%s [%s]: " "$prompt" "$default"
    else
        printf "%s: " "$prompt"
    fi
    read -r reply
    echo "${reply:-$default}"
}

prompt_yn() {
    local prompt="$1"
    local default="${2:-n}"
    local reply
    while true; do
        if [ "$default" = "y" ]; then
            printf "%s [Y/n]: " "$prompt"
        else
            printf "%s [y/N]: " "$prompt"
        fi
        read -r reply
        reply="${reply:-$default}"
        case "$reply" in
            [Yy]*) return 0 ;;
            [Nn]*) return 1 ;;
            *) echo "Please answer y or n." ;;
        esac
    done
}

require_gh() {
    if ! command -v gh >/dev/null 2>&1; then
        echo "error: gh CLI not found. Install from https://cli.github.com/." >&2
        exit 1
    fi
    if ! gh auth status >/dev/null 2>&1; then
        echo "error: gh CLI is not authenticated. Run \`gh auth login\` first." >&2
        exit 1
    fi
}

# Substitute placeholders in a file. Placeholders use the ${NAME}
# shell-syntax form. We use sed with a per-replacement argument list
# so values containing newlines (CODEOWNERS lines) are handled by
# breaking the newline into the sed replacement explicitly.
substitute_placeholders() {
    local file="$1"
    local owner="$2"
    local repo="$3"
    local watched_paths="$4"
    local codeowner_lines="$5"

    local tmp
    tmp=$(mktemp)

    # Use python for the substitution to avoid sed portability traps
    # around multi-line replacements and special characters.
    OWNER="$owner" REPO="$repo" WATCHED_PATHS="$watched_paths" \
        WATCHED_PATHS_AS_CODEOWNER_LINES="$codeowner_lines" \
        python3 - "$file" "$tmp" <<'PYEOF'
import os, sys
src, dst = sys.argv[1], sys.argv[2]
with open(src, "r", encoding="utf-8") as f:
    body = f.read()
for k in ("OWNER", "REPO", "WATCHED_PATHS", "WATCHED_PATHS_AS_CODEOWNER_LINES"):
    v = os.environ.get(k, "")
    body = body.replace("${" + k + "}", v)
with open(dst, "w", encoding="utf-8") as f:
    f.write(body)
PYEOF
    mv "$tmp" "$file"
}

# Build the CODEOWNERS lines from a comma-separated list of watched
# paths. Each path becomes a line of the form:
#
#     /<path>             @<owner> @<owner>/compliance-review
#
# We pad the path column for readability.
build_codeowner_lines() {
    local owner="$1"
    local watched_csv="$2"

    if [ -z "$watched_csv" ]; then
        echo "# (no watched paths configured)"
        return
    fi

    local IFS=','
    # shellcheck disable=SC2206
    local paths=($watched_csv)
    local out=""
    for p in "${paths[@]}"; do
        # Trim whitespace.
        p="${p#"${p%%[![:space:]]*}"}"
        p="${p%"${p##*[![:space:]]}"}"
        if [ -z "$p" ]; then
            continue
        fi
        # Ensure leading slash and trailing slash for directory globs.
        case "$p" in
            /*) ;;
            *) p="/$p" ;;
        esac
        case "$p" in
            */) ;;
            *) p="$p/" ;;
        esac
        out+="${p}             @${owner} @${owner}/compliance-review"$'\n'
    done
    # Trim trailing newline.
    printf "%s" "${out%$'\n'}"
}

# ---------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------

require_gh

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "$REPO_ROOT"

echo "claude-code-setup bootstrap"
echo "==========================="
echo "Repo root: $REPO_ROOT"
echo

# Detect owner + repo from `gh repo view`. The user may override.
DEFAULT_OWNER=""
DEFAULT_REPO=""
if gh repo view --json owner,name >/tmp/cc-setup-repo.json 2>/dev/null; then
    DEFAULT_OWNER=$(python3 -c "import json,sys; print(json.load(open('/tmp/cc-setup-repo.json'))['owner']['login'])")
    DEFAULT_REPO=$(python3 -c "import json,sys; print(json.load(open('/tmp/cc-setup-repo.json'))['name'])")
    rm -f /tmp/cc-setup-repo.json
fi

OWNER=$(prompt_default "GitHub owner / org" "$DEFAULT_OWNER")
REPO=$(prompt_default "GitHub repo name" "$DEFAULT_REPO")

if [ -z "$OWNER" ] || [ -z "$REPO" ]; then
    echo "error: owner and repo are required." >&2
    exit 1
fi

echo
echo "Compliance-sensitive paths configure both:"
echo "  - the trust-boundary CI gate (.github/workflows/trust-boundary.yml)"
echo "  - CODEOWNERS routing (.github/CODEOWNERS)"
echo "Provide as a comma-separated list, e.g. internal/policy/,internal/audit/."
echo "Leave empty if you have none yet (you can re-run this script later)."
WATCHED_PATHS=$(prompt_default "Watched paths" "")

# Build the CODEOWNERS lines once; reuse for the substitution.
CODEOWNER_LINES=$(build_codeowner_lines "$OWNER" "$WATCHED_PATHS")

echo
echo "Configuration:"
echo "  OWNER:                 $OWNER"
echo "  REPO:                  $REPO"
echo "  WATCHED_PATHS:         ${WATCHED_PATHS:-<none>}"
echo "  CODEOWNER_LINES:"
echo "$CODEOWNER_LINES" | sed 's/^/    /'
echo

# -----------------------------------------------------------------
# Step: substitute placeholders + rename *.template files
# -----------------------------------------------------------------

echo "Substituting placeholders + renaming *.template files..."

# Process every *.template file currently in the tree.
while IFS= read -r -d '' f; do
    target="${f%.template}"
    cp "$f" "$target"
    substitute_placeholders "$target" "$OWNER" "$REPO" "$WATCHED_PATHS" "$CODEOWNER_LINES"
    rm -f "$f"
    echo "  -> ${target#${REPO_ROOT}/}"
done < <(find . -type f -name "*.template" -print0)

# Also substitute placeholders inline in non-template files that
# reference ${OWNER}, ${REPO}, etc. (currently none ship with such
# placeholders, but keep the call in for forward-compat).
INLINE_TARGETS=()
# Add explicit inline targets here as the template grows. None today.
for t in "${INLINE_TARGETS[@]}"; do
    if [ -f "$t" ]; then
        substitute_placeholders "$t" "$OWNER" "$REPO" "$WATCHED_PATHS" "$CODEOWNER_LINES"
        echo "  inline: $t"
    fi
done

# -----------------------------------------------------------------
# Step: ANTHROPIC_API_KEY secret
# -----------------------------------------------------------------

echo
echo "ANTHROPIC_API_KEY enables the agentic-review workflow."
echo "Leave empty to skip (the workflow will degrade gracefully)."
printf "Anthropic API key (input hidden): "
# Read with -s if supported (bash). Fall back to plain read otherwise.
if [ -n "${BASH_VERSION:-}" ]; then
    read -r -s ANTHROPIC_KEY
    echo
else
    read -r ANTHROPIC_KEY
fi

if [ -n "$ANTHROPIC_KEY" ]; then
    echo "Setting secret ANTHROPIC_API_KEY on $OWNER/$REPO..."
    if printf '%s' "$ANTHROPIC_KEY" | gh secret set ANTHROPIC_API_KEY --repo "$OWNER/$REPO" --body -; then
        echo "  ok"
    else
        echo "  error: failed to set secret. You can set it later via:" >&2
        echo "    gh secret set ANTHROPIC_API_KEY --repo $OWNER/$REPO" >&2
    fi
else
    echo "Skipped. Set later with:"
    echo "  gh secret set ANTHROPIC_API_KEY --repo $OWNER/$REPO"
fi

# -----------------------------------------------------------------
# Step: compliance-review label
# -----------------------------------------------------------------

echo
echo "Creating 'compliance-review' label..."
if gh api -X POST "/repos/$OWNER/$REPO/labels" \
    -f name="compliance-review" \
    -f color="b60205" \
    -f description="Trust-boundary gate cleared by an authorised compliance reviewer" >/dev/null 2>&1; then
    echo "  ok"
else
    # 422 Unprocessable Entity = label already exists. Treat as success.
    echo "  already exists (or could not be created — check repo permissions)"
fi

# Also create the agentic-review:skip label so operators can opt out.
echo "Creating 'agentic-review:skip' label..."
if gh api -X POST "/repos/$OWNER/$REPO/labels" \
    -f name="agentic-review:skip" \
    -f color="ededed" \
    -f description="Skip the read-only agentic PR review for this PR" >/dev/null 2>&1; then
    echo "  ok"
else
    echo "  already exists (or could not be created)"
fi

# -----------------------------------------------------------------
# Step: branch protection (optional)
# -----------------------------------------------------------------

echo
if prompt_yn "Configure initial branch protection on 'main'?" "n"; then
    echo "Creating branch protection on main..."
    # Required status checks: CI's build-and-test + lint, plus the
    # trust-boundary-gate. The agentic review is intentionally NOT
    # required (it must never block merges).
    BP_PAYLOAD=$(cat <<JSON
{
  "required_status_checks": {
    "strict": true,
    "contexts": ["build-and-test", "lint", "trust-boundary-gate"]
  },
  "enforce_admins": false,
  "required_pull_request_reviews": {
    "required_approving_review_count": 1,
    "dismiss_stale_reviews": true,
    "require_code_owner_reviews": true
  },
  "restrictions": null
}
JSON
)
    if echo "$BP_PAYLOAD" | gh api -X PUT \
        "/repos/$OWNER/$REPO/branches/main/protection" \
        --input - >/dev/null 2>&1; then
        echo "  ok"
    else
        echo "  error: could not apply branch protection. You can apply it manually via" >&2
        echo "  GitHub Settings -> Branches, or re-run with appropriate gh auth scopes." >&2
    fi
else
    echo "Skipped. Configure via GitHub Settings -> Branches when ready."
fi

# -----------------------------------------------------------------
# Footer
# -----------------------------------------------------------------

cat <<EOF

Bootstrap complete.

Next steps:
  1. Replace the Go-flavoured CI (.github/workflows/ci.yml) with one
     for your stack. The job-shape and concurrency block carry over.
  2. Edit .github/CODEOWNERS to reference real team handles once they
     exist in your org.
  3. Open a PR. Watch agentic-review post a sticky comment, and
     trust-boundary-gate fire if you touch a watched path.
  4. Read docs/setup.md for verification steps and troubleshooting.

Re-running this script is safe — it is idempotent.
EOF
