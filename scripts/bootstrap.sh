#!/usr/bin/env bash
# bootstrap.sh — one-shot (and idempotent) setup script for a repo
# instantiated from claude-code-setup.
#
# What it does:
#   1. Detect owner + name from `gh repo view`.
#   2. Prompt for the comma-separated list of compliance-sensitive
#      paths (e.g. internal/policy/,internal/audit/).
#   3. Substitute ${OWNER}, ${REPO}, ${WATCHED_PATHS},
#      ${WATCHED_PATHS_AS_CODEOWNER_LINES} placeholders across the
#      always-rename *.template files (ci.yml, CODEOWNERS).
#   4. Rename always-renamed *.template -> their non-template name.
#   5. Prompt-rename the opt-in *.template files: dependabot config,
#      govulncheck workflow, nightly workflow, .claude/settings.json.
#   6. Prompt for ANTHROPIC_API_KEY and set via `gh secret set`
#      (empty input skips this step).
#   7. Create labels: compliance-review, agentic-review:skip,
#      agentic-review:degraded, coverage-skip.
#   8. Optionally install the strict-recipe pre-push git hook.
#   9. Optionally configure branch protection on `main`.
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
# shell-syntax form. We use python for the substitution to avoid sed
# portability traps around multi-line replacements.
substitute_placeholders() {
    local file="$1"
    local owner="$2"
    local repo="$3"
    local watched_paths="$4"
    local codeowner_lines="$5"

    local tmp
    tmp=$(mktemp)

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

# Conditional rename helper: copy a *.template file to its target name
# (after substitution) and remove the source. No-op if source is missing
# (idempotent re-run path).
rename_template() {
    local src="$1"
    local dst="$2"

    if [ ! -f "$src" ]; then
        return 0
    fi

    # Ensure parent directory of destination exists.
    local dst_dir
    dst_dir="$(dirname "$dst")"
    mkdir -p "$dst_dir"

    cp "$src" "$dst"
    substitute_placeholders "$dst" "$OWNER" "$REPO" "$WATCHED_PATHS" "$CODEOWNER_LINES"
    rm -f "$src"
    echo "  -> ${dst#${REPO_ROOT}/}"
}

# Create a label idempotently; treat 422 (already exists) as success.
create_label() {
    local name="$1"
    local color="$2"
    local description="$3"

    echo "Creating '$name' label..."
    if gh api -X POST "/repos/$OWNER/$REPO/labels" \
        -f name="$name" \
        -f color="$color" \
        -f description="$description" >/dev/null 2>&1; then
        echo "  ok"
    else
        echo "  already exists (or could not be created — check repo permissions)"
    fi
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
# Step: substitute placeholders + rename always-renamed *.template
# -----------------------------------------------------------------
#
# These templates ALWAYS get renamed on bootstrap (the operator wants
# them on; they're the foundation of the setup). The opt-in templates
# (dependabot, govulncheck, nightly, .claude settings) get a separate
# prompted step below.

echo "Substituting placeholders + renaming always-renamed *.template files..."

ALWAYS_RENAME_TEMPLATES=(
    ".github/workflows/ci.yml.template"
    ".github/CODEOWNERS.template"
)

for src in "${ALWAYS_RENAME_TEMPLATES[@]}"; do
    if [ ! -f "$src" ]; then
        continue
    fi
    dst="${src%.template}"
    rename_template "$src" "$dst"
done

# -----------------------------------------------------------------
# Step: opt-in *.template renames
# -----------------------------------------------------------------

echo
echo "Optional template features:"
echo

# .claude/settings.json — curated permissions allowlist for Claude Code
# subagents working in this repo.
if [ -f "templates/claude-settings.json.template" ]; then
    if prompt_yn "Install curated .claude/settings.json (permissions allowlist for Claude Code subagents)?" "y"; then
        rename_template "templates/claude-settings.json.template" ".claude/settings.json"
    else
        echo "  Skipped. The template lives at templates/claude-settings.json.template — copy to .claude/settings.json when ready."
    fi
fi

# Dependabot — weekly dependency bumps for Go modules + GitHub Actions.
if [ -f ".github/dependabot.yml.template" ]; then
    if prompt_yn "Enable Dependabot weekly dependency bumps?" "n"; then
        rename_template ".github/dependabot.yml.template" ".github/dependabot.yml"
    else
        echo "  Skipped. Re-run later or rename the .template manually."
    fi
fi

# govulncheck — Go vulnerability scan workflow.
if [ -f ".github/workflows/govulncheck.yml.template" ]; then
    if prompt_yn "Enable govulncheck workflow (weekly Go vulnerability scan + on go.mod PRs)?" "n"; then
        rename_template ".github/workflows/govulncheck.yml.template" ".github/workflows/govulncheck.yml"
    else
        echo "  Skipped."
    fi
fi

# nightly — slow-tests + extended fuzz harness.
if [ -f ".github/workflows/nightly.yml.template" ]; then
    if prompt_yn "Enable nightly workflow template (slow-tests + extended fuzz; project-specific matrix needs editing)?" "n"; then
        rename_template ".github/workflows/nightly.yml.template" ".github/workflows/nightly.yml"
        echo "  WARNING: edit .github/workflows/nightly.yml's matrix.include before merging — the placeholders won't compile against your code."
    else
        echo "  Skipped."
    fi
fi

# -----------------------------------------------------------------
# Step: agentic-review opt-in (variable + secret)
# -----------------------------------------------------------------

echo
echo "Agentic review (read-only Claude PR review) is OFF by default."
printf "Enable it for this repo? [y/N] "
read -r ENABLE_AGENTIC_REVIEW
case "$ENABLE_AGENTIC_REVIEW" in
    [yY]|[yY][eE][sS]) ENABLE_AGENTIC_REVIEW="yes" ;;
    *) ENABLE_AGENTIC_REVIEW="no" ;;
esac

if [ "$ENABLE_AGENTIC_REVIEW" = "yes" ]; then
    echo "Setting variable AGENTIC_REVIEW_ENABLED=true on $OWNER/$REPO..."
    if gh variable set AGENTIC_REVIEW_ENABLED --repo "$OWNER/$REPO" --body "true" >/dev/null 2>&1; then
        echo "  ok"
    else
        # Fall back to REST if the gh subcommand is unavailable.
        if gh api -X POST "/repos/$OWNER/$REPO/actions/variables" \
            -f name=AGENTIC_REVIEW_ENABLED -f value=true >/dev/null 2>&1; then
            echo "  ok (via REST)"
        else
            echo "  error: failed to set variable. Set it later via:" >&2
            echo "    gh variable set AGENTIC_REVIEW_ENABLED --repo $OWNER/$REPO --body true" >&2
        fi
    fi

    echo
    echo "ANTHROPIC_API_KEY is required for the workflow to call Claude."
    echo "Leave empty to defer (the workflow will degrade gracefully)."
    printf "Anthropic API key (input hidden): "
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
            echo "  error: failed to set secret. Set it later via:" >&2
            echo "    gh secret set ANTHROPIC_API_KEY --repo $OWNER/$REPO" >&2
        fi
    else
        echo "Skipped. Set later with:"
        echo "  gh secret set ANTHROPIC_API_KEY --repo $OWNER/$REPO"
    fi
else
    echo "Agentic review left disabled. Enable it later with:"
    echo "  gh variable set AGENTIC_REVIEW_ENABLED --repo $OWNER/$REPO --body true"
    echo "  gh secret set   ANTHROPIC_API_KEY     --repo $OWNER/$REPO"
fi

# -----------------------------------------------------------------
# Step: labels
# -----------------------------------------------------------------

echo
create_label "compliance-review"        "b60205" "Trust-boundary gate cleared by an authorised compliance reviewer"
create_label "agentic-review:skip"      "ededed" "Skip the read-only agentic PR review for this PR"
create_label "agentic-review:degraded"  "e4b400" "Agentic review ran in degraded mode (e.g. missing API key); merge with caution"
create_label "coverage-skip"            "fbca04" "Bypass per-package coverage gate; expected to be paired with a follow-up baseline-update PR"

# -----------------------------------------------------------------
# Step: pre-push hook (optional)
# -----------------------------------------------------------------

echo
if prompt_yn "Install strict-recipe pre-push git hook (recommended for agent-driven workflows)?" "n"; then
    if [ -x "$REPO_ROOT/scripts/install-pre-push-hook.sh" ]; then
        "$REPO_ROOT/scripts/install-pre-push-hook.sh"
    else
        echo "  error: $REPO_ROOT/scripts/install-pre-push-hook.sh not found or not executable" >&2
    fi
else
    echo "Skipped. Install later with: ./scripts/install-pre-push-hook.sh"
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
  3. (If you opted in to coverage-gate) populate ops/coverage-baseline.json
     from ops/coverage-baseline.json.example and uncomment the
     coverage-gate block in .github/workflows/ci.yml. See docs/setup.md
     §Coverage gate.
  4. Open a PR. Watch agentic-review post a sticky comment, and
     trust-boundary-gate fire if you touch a watched path.
  5. Read docs/setup.md for verification steps and troubleshooting.

Re-running this script is safe — it is idempotent.
EOF
