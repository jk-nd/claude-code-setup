#!/usr/bin/env bash
# bootstrap.sh (v2) — one-shot, idempotent setup for a repo instantiated
# from claude-code-setup.
#
# What it does:
#   1. Detect owner + name from `gh repo view`.
#   2. Prompt for the comma-separated WATCHED_PATHS (compliance-sensitive
#      paths). Suggests the v2 default infrastructure paths
#      (.github/workflows/, go.mod, go.sum, .github/CODEOWNERS) plus any
#      project-specific compliance paths.
#   3. Substitute ${OWNER}, ${REPO}, ${WATCHED_PATHS},
#      ${WATCHED_PATHS_AS_CODEOWNER_LINES} placeholders across the
#      always-rename *.template files (ci.yml, CODEOWNERS).
#   4. Rename always-renamed *.template -> their non-template name.
#   5. Prompt-rename the opt-in *.template files: dependabot, govulncheck,
#      nightly, docs-audit, .claude/settings.json.
#   6. Create labels: compliance-review, doc-stale, coverage-skip.
#   7. Optionally install the strict-recipe pre-push git hook.
#   8. Optionally configure branch protection on `main`.
#
# Safe to re-run; only re-applies steps whose underlying state changed.

set -euo pipefail

# ---------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------

prompt_default() {
    local prompt="$1"
    local default="${2:-}"
    local reply
    if [ -n "$default" ]; then
        printf "%s [%s]: " "$prompt" "$default" >&2
    else
        printf "%s: " "$prompt" >&2
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
            printf "%s [Y/n]: " "$prompt" >&2
        else
            printf "%s [y/N]: " "$prompt" >&2
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
        p="${p#"${p%%[![:space:]]*}"}"
        p="${p%"${p##*[![:space:]]}"}"
        if [ -z "$p" ]; then
            continue
        fi
        case "$p" in
            /*) ;;
            *) p="/$p" ;;
        esac
        # If the path looks like a directory (no extension), ensure trailing slash.
        case "$p" in
            */) ;;
            *.* ) ;;  # likely a file (go.mod, CODEOWNERS, etc.) — leave as-is
            *) p="$p/" ;;
        esac
        out+="${p}             @${owner} @${owner}/compliance-review"$'\n'
    done
    printf "%s" "${out%$'\n'}"
}

rename_template() {
    local src="$1"
    local dst="$2"

    if [ ! -f "$src" ]; then
        return 0
    fi

    local dst_dir
    dst_dir="$(dirname "$dst")"
    mkdir -p "$dst_dir"

    cp "$src" "$dst"
    substitute_placeholders "$dst" "$OWNER" "$REPO" "$WATCHED_PATHS" "$CODEOWNER_LINES"
    rm -f "$src"
    echo "  -> ${dst#${REPO_ROOT}/}"
}

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

echo "claude-code-setup bootstrap (v2)"
echo "================================"
echo "Repo root: $REPO_ROOT"
echo

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
echo "WATCHED_PATHS configure both:"
echo "  - the trust-boundary CI gate (.github/workflows/trust-boundary.yml)"
echo "  - CODEOWNERS routing (.github/CODEOWNERS)"
echo
echo "v2 defaults to include infrastructure paths so the orchestrator cannot"
echo "auto-merge changes to workflows, dependencies, or codeowners themselves:"
echo "  .github/workflows/, go.mod, go.sum, .github/CODEOWNERS"
echo
echo "Add your project's compliance-sensitive paths after the comma, e.g.:"
echo "  .github/workflows/,go.mod,go.sum,.github/CODEOWNERS,internal/policy/,internal/auth/"
echo
DEFAULT_WATCHED=".github/workflows/,go.mod,go.sum,.github/CODEOWNERS"
WATCHED_PATHS=$(prompt_default "Watched paths" "$DEFAULT_WATCHED")

CODEOWNER_LINES=$(build_codeowner_lines "$OWNER" "$WATCHED_PATHS")

echo
echo "Configuration:"
echo "  OWNER:           $OWNER"
echo "  REPO:            $REPO"
echo "  WATCHED_PATHS:   $WATCHED_PATHS"
echo "  CODEOWNER_LINES:"
echo "$CODEOWNER_LINES" | sed 's/^/    /'
echo

# -----------------------------------------------------------------
# Always-renamed *.template
# -----------------------------------------------------------------

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
# Opt-in *.template renames
# -----------------------------------------------------------------

echo
echo "Optional template features:"
echo

# .claude/settings.json — curated permissions allowlist for the agent team.
if [ -f "templates/claude-settings.json.template" ]; then
    if prompt_yn "Install curated .claude/settings.json (permissions allowlist for the agent team)?" "y"; then
        rename_template "templates/claude-settings.json.template" ".claude/settings.json"
    else
        echo "  Skipped. Copy templates/claude-settings.json.template → .claude/settings.json later if you change your mind."
    fi
fi

# docs-audit — weekly cron opens a doc-stale audit issue for the orchestrator.
if [ -f ".github/workflows/docs-audit.yml.template" ]; then
    if prompt_yn "Enable weekly docs-audit workflow (opens a doc-stale issue every Monday)?" "y"; then
        rename_template ".github/workflows/docs-audit.yml.template" ".github/workflows/docs-audit.yml"
    else
        echo "  Skipped."
    fi
fi

# Dependabot — weekly dependency bumps.
if [ -f ".github/dependabot.yml.template" ]; then
    if prompt_yn "Enable Dependabot weekly dependency bumps?" "n"; then
        rename_template ".github/dependabot.yml.template" ".github/dependabot.yml"
    else
        echo "  Skipped."
    fi
fi

# govulncheck.
if [ -f ".github/workflows/govulncheck.yml.template" ]; then
    if prompt_yn "Enable govulncheck workflow (weekly Go vulnerability scan)?" "n"; then
        rename_template ".github/workflows/govulncheck.yml.template" ".github/workflows/govulncheck.yml"
    else
        echo "  Skipped."
    fi
fi

# nightly — only if project actually has fuzz / slow-test surfaces.
if [ -f ".github/workflows/nightly.yml.template" ]; then
    echo "  nightly.yml runs slow-tests + fuzz harnesses. Only enable if your"
    echo "  project has fuzz targets or a slow-test build tag. Pilot work usually skips."
    if prompt_yn "Enable nightly workflow?" "n"; then
        rename_template ".github/workflows/nightly.yml.template" ".github/workflows/nightly.yml"
        echo "  WARNING: edit .github/workflows/nightly.yml's matrix.include before merging — the placeholders will not compile against your code."
    else
        echo "  Skipped."
    fi
fi

# -----------------------------------------------------------------
# Labels
# -----------------------------------------------------------------

echo
create_label "compliance-review"  "b60205" "Trust-boundary gate cleared by an authorised compliance reviewer"
create_label "doc-stale"          "fbca04" "Documentation drift discovered by doc-keeper or per-merge adversary check"
create_label "coverage-skip"      "ededed" "Bypass per-package coverage gate; expected to be paired with a follow-up baseline-update PR"

# -----------------------------------------------------------------
# Pre-push hook (optional)
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
# Branch protection (optional)
# -----------------------------------------------------------------

echo
if prompt_yn "Configure initial branch protection on 'main'?" "n"; then
    echo "Creating branch protection on main..."
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
        echo "  error: could not apply branch protection. Apply manually via" >&2
        echo "  GitHub Settings → Branches, or re-run with appropriate gh auth scopes." >&2
    fi
else
    echo "Skipped. Configure via GitHub Settings → Branches when ready."
fi

# -----------------------------------------------------------------
# Footer
# -----------------------------------------------------------------

cat <<EOF

Bootstrap complete.

Next steps:
  1. Set GOOGLE_AI_STUDIO_API_KEY in your shell env (free key at
     https://aistudio.google.com). The plan-reviewer subagent uses it.
  2. Replace the Go-flavoured CI (.github/workflows/ci.yml) with one for
     your stack. The job-shape and concurrency block carry over.
  3. Edit .github/CODEOWNERS to reference real team handles once they
     exist in your org.
  4. Start the orchestrator: cd <repo> && claude.
  5. Tell it what to build. Approve at the four gates: approach, spec,
     plan-mission, compliance-routed PRs.

Re-running this script is safe — it is idempotent.
EOF
