#!/usr/bin/env bash
# bootstrap.sh (v3) — one-shot, idempotent setup for a repo instantiated
# from claude-code-setup.
#
# What it does:
#   1. Detect owner + name from `gh repo view`.
#   2. Prompt for the primary stack (go | python | rego | other). This
#      drives language-aware defaults: whether the Go CI is activated,
#      the WATCHED_PATHS default, and the required branch-protection check.
#   3. Prompt for the comma-separated WATCHED_PATHS (compliance-sensitive
#      paths). The default includes infrastructure paths plus, for Go,
#      the dependency manifests (go.mod, go.sum); non-Go stacks omit them.
#   4. Prompt for ceremony_level (foundation | demo | iterate-fast).
#   5. Substitute ${OWNER}, ${REPO}, ${WATCHED_PATHS},
#      ${WATCHED_PATHS_AS_CODEOWNER_LINES}, ${CEREMONY_LEVEL} placeholders
#      and rename the always-renamed *.template files (CODEOWNERS). The Go
#      ci.yml.template is activated as ci.yml only for Go projects; for
#      other stacks it is left in place as a marked reference stub.
#   6. Prompt-rename the opt-in *.template files: dependabot, govulncheck,
#      nightly, docs-audit, .claude/settings.json, dependabot-automerge,
#      dependabot-rebase-stale, main-broken-sentinel, release,
#      smoke-test playbook.
#   7. Create labels: compliance-review, doc-stale, coverage-skip,
#      automerge, dependabot:major-review-needed, main-broken,
#      dependencies, watched-path, for-orchestrator, for-navigator,
#      audit, tech-debt. (Descriptions are capped at GitHub's 100-char
#      limit.)
#   8. Optionally scaffold 'Phase N' build milestones + phase-N labels.
#   9. Optionally install the strict-recipe pre-push git hook.
#  10. Optionally configure branch protection on `main` with a
#      maintainer-identity allowlist (solo-author = merger stays
#      unblocked; bot/agent identities trigger non-author approval).
#  11. Optionally enable GitHub merge queue on `main` via gh graphql.
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

prompt_choice() {
    # prompt_choice "Prompt" "default" "opt1" "opt2" "opt3"
    local prompt="$1"
    local default="$2"
    shift 2
    local opts=("$@")
    local i=1
    echo "$prompt" >&2
    for o in "${opts[@]}"; do
        echo "  $i) $o" >&2
        i=$((i + 1))
    done
    local reply
    printf "Choice [%s]: " "$default" >&2
    read -r reply
    reply="${reply:-$default}"
    # If reply is a number, map it back to the option text; if it's a
    # name that matches an option, accept it directly.
    if [[ "$reply" =~ ^[0-9]+$ ]] && [ "$reply" -ge 1 ] && [ "$reply" -le "${#opts[@]}" ]; then
        echo "${opts[$((reply - 1))]}"
        return
    fi
    for o in "${opts[@]}"; do
        if [ "$o" = "$reply" ]; then
            echo "$o"
            return
        fi
    done
    # Fall back to default.
    echo "$default"
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
    local ceremony_level="${6:-foundation}"

    local tmp
    tmp=$(mktemp)

    OWNER="$owner" REPO="$repo" WATCHED_PATHS="$watched_paths" \
        WATCHED_PATHS_AS_CODEOWNER_LINES="$codeowner_lines" \
        CEREMONY_LEVEL="$ceremony_level" \
        python3 - "$file" "$tmp" <<'PYEOF'
import os, sys
src, dst = sys.argv[1], sys.argv[2]
with open(src, "r", encoding="utf-8") as f:
    body = f.read()
for k in ("OWNER", "REPO", "WATCHED_PATHS", "WATCHED_PATHS_AS_CODEOWNER_LINES", "CEREMONY_LEVEL"):
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
    substitute_placeholders "$dst" "$OWNER" "$REPO" "$WATCHED_PATHS" "$CODEOWNER_LINES" "$CEREMONY_LEVEL"
    rm -f "$src"
    echo "  -> ${dst#"${REPO_ROOT}"/}"
}

create_label() {
    local name="$1"
    local color="$2"
    local description="$3"

    # GitHub rejects label descriptions longer than 100 chars with HTTP
    # 422. Cap defensively so a long description degrades to a truncated
    # one instead of a hard failure.
    if [ "${#description}" -gt 100 ]; then
        description="${description:0:100}"
    fi

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

create_milestone() {
    local title="$1"

    echo "Creating milestone '$title'..."
    if gh api -X POST "/repos/$OWNER/$REPO/milestones" \
        -f title="$title" >/dev/null 2>&1; then
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

echo "claude-code-setup bootstrap (v3)"
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
echo "Primary language / stack. This sets language-aware defaults: which CI"
echo "pipeline is activated, the watched-paths default, and the required"
echo "branch-protection check."
echo "  go     — activate the Go CI pipeline; Go watched paths (turnkey)."
echo "  python — Python project; Go CI left as a reference stub to replace."
echo "  rego   — OPA/Rego policy project; Go CI left as a reference stub."
echo "  other  — any other stack; Go CI left as a reference stub."
echo
STACK=$(prompt_choice "Pick the primary stack" "go" "go" "python" "rego" "other")

echo
echo "WATCHED_PATHS configure both:"
echo "  - the trust-boundary CI gate (.github/workflows/trust-boundary.yml)"
echo "  - CODEOWNERS routing (.github/CODEOWNERS)"
echo
echo "The default includes infrastructure paths so the orchestrator cannot"
echo "auto-merge changes to workflows or codeowners themselves. For Go"
echo "projects it also includes the dependency manifests (go.mod, go.sum);"
echo "for other stacks those are dropped (add your own manifest below)."
echo
# Language-aware default: Go pins the dependency manifests; other stacks
# start without them so a non-Go repo isn't told go.mod/go.sum are
# compliance-sensitive when they don't exist.
if [ "$STACK" = "go" ]; then
    DEFAULT_WATCHED=".github/workflows/,go.mod,go.sum,.github/CODEOWNERS"
else
    DEFAULT_WATCHED=".github/workflows/,.github/CODEOWNERS"
fi
echo "Add your project's compliance-sensitive paths after the comma, e.g.:"
echo "  ${DEFAULT_WATCHED},internal/policy/,internal/auth/"
echo
WATCHED_PATHS=$(prompt_default "Watched paths" "$DEFAULT_WATCHED")

echo
echo "Repo ceremony level (per AGENTS.md operating clarification #4 / #19):"
echo "  foundation   — full architect → spec → planner → plan-reviewer loop."
echo "                 Used for product foundations and compliance-routed work."
echo "  demo         — approach + spec collapsed; planner optional;"
echo "                 plan-reviewer optional. Visible-but-not-foundational."
echo "  iterate-fast — single doc per slice; implementer + adversary +"
echo "                 doc-keeper only. Demos and quick-iterate sandboxes."
echo
CEREMONY_LEVEL=$(prompt_choice "Pick a ceremony level" "foundation" "foundation" "demo" "iterate-fast")

CODEOWNER_LINES=$(build_codeowner_lines "$OWNER" "$WATCHED_PATHS")

echo
echo "Configuration:"
echo "  OWNER:           $OWNER"
echo "  REPO:            $REPO"
echo "  WATCHED_PATHS:   $WATCHED_PATHS"
echo "  CEREMONY_LEVEL:  $CEREMONY_LEVEL"
echo "  CODEOWNER_LINES:"
echo "$CODEOWNER_LINES" | sed 's/^/    /'
echo

# -----------------------------------------------------------------
# Update AGENTS.md ceremony_level field if it's a placeholder.
# -----------------------------------------------------------------

if [ -f "$REPO_ROOT/AGENTS.md" ]; then
    if grep -q '^ceremony_level: foundation' "$REPO_ROOT/AGENTS.md"; then
        # Default already matches; substitute only if non-default chosen.
        if [ "$CEREMONY_LEVEL" != "foundation" ]; then
            python3 - "$REPO_ROOT/AGENTS.md" "$CEREMONY_LEVEL" <<'PYEOF'
import sys, re
path, level = sys.argv[1], sys.argv[2]
with open(path, "r", encoding="utf-8") as f:
    body = f.read()
body = re.sub(r'^ceremony_level: \w+', f'ceremony_level: {level}', body, count=1, flags=re.MULTILINE)
with open(path, "w", encoding="utf-8") as f:
    f.write(body)
PYEOF
            echo "AGENTS.md: ceremony_level set to $CEREMONY_LEVEL"
        fi
    fi
fi

# -----------------------------------------------------------------
# Always-renamed *.template
# -----------------------------------------------------------------

echo "Substituting placeholders + renaming always-renamed *.template files..."

ALWAYS_RENAME_TEMPLATES=(
    ".github/CODEOWNERS.template"
)

for src in "${ALWAYS_RENAME_TEMPLATES[@]}"; do
    if [ ! -f "$src" ]; then
        continue
    fi
    dst="${src%.template}"
    rename_template "$src" "$dst"
done

# CI pipeline: the template ships a Go reference pipeline. Activate it as
# ci.yml only for Go projects. For other stacks, leave the *.template in
# place (only *.yml files run, so it stays inert) with its banner, so a
# non-Go repo never silently ships a Go pipeline as if it were its own.
if [ -f ".github/workflows/ci.yml.template" ]; then
    if [ "$STACK" = "go" ]; then
        rename_template ".github/workflows/ci.yml.template" ".github/workflows/ci.yml"
    else
        echo "  .github/workflows/ci.yml.template LEFT AS A REFERENCE STUB (stack: $STACK)."
        echo "    It is a Go pipeline and is NOT active (only *.yml runs). Replace its"
        echo "    build/test/lint steps with your $STACK toolchain, then rename it to"
        echo "    .github/workflows/ci.yml. The job-shape (paths-filter -> gated jobs ->"
        echo "    ci-pass aggregator) carries over unchanged."
    fi
fi

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
DEPENDABOT_ENABLED="n"
if [ -f ".github/dependabot.yml.template" ]; then
    if prompt_yn "Enable Dependabot weekly dependency bumps?" "n"; then
        rename_template ".github/dependabot.yml.template" ".github/dependabot.yml"
        DEPENDABOT_ENABLED="y"
    else
        echo "  Skipped."
    fi
fi

# Dependabot auto-merge — only meaningful if dependabot is on.
if [ "$DEPENDABOT_ENABLED" = "y" ] && [ -f ".github/workflows/dependabot-automerge.yml.template" ]; then
    if prompt_yn "Enable dependabot auto-merge workflow for patch/minor (major routed to human review)?" "y"; then
        rename_template ".github/workflows/dependabot-automerge.yml.template" ".github/workflows/dependabot-automerge.yml"
        echo "  Set the DEPENDABOT_AUTOMERGE_ENABLED repo variable to enable: gh variable set DEPENDABOT_AUTOMERGE_ENABLED -b true"
    else
        echo "  Skipped."
    fi
fi

# Dependabot rebase-stale — only meaningful if dependabot is on.
if [ "$DEPENDABOT_ENABLED" = "y" ] && [ -f ".github/workflows/dependabot-rebase-stale.yml.template" ]; then
    if prompt_yn "Enable nightly auto-rebase of stale (CONFLICTING) dependabot PRs?" "y"; then
        rename_template ".github/workflows/dependabot-rebase-stale.yml.template" ".github/workflows/dependabot-rebase-stale.yml"
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

# Release workflow (publishes artifacts + creates GitHub Release on tag push).
if [ -f ".github/workflows/release.yml.template" ]; then
    echo "  release.yml publishes images/binaries (project-specific stubs) AND"
    echo "  creates a GitHub Release object on every tag push, sourcing the"
    echo "  body from docs/releases/<tag>.md. The Release-create step is the"
    echo "  template invariant; build/push steps are commented stubs you edit."
    if prompt_yn "Enable release workflow?" "y"; then
        rename_template ".github/workflows/release.yml.template" ".github/workflows/release.yml"
        mkdir -p docs/releases
        # .gitkeep so the directory exists in git even before the first tag.
        if [ ! -f "docs/releases/.gitkeep" ]; then
            : > docs/releases/.gitkeep
        fi
        echo "  -> docs/releases/ created."
        if [ -f "templates/release-notes.md.template" ]; then
            if prompt_yn "Seed docs/releases/v0.1.0.md from the starter template?" "y"; then
                if [ -f "docs/releases/v0.1.0.md" ]; then
                    echo "  docs/releases/v0.1.0.md already exists; leaving in place."
                    rm -f templates/release-notes.md.template
                else
                    cp templates/release-notes.md.template docs/releases/v0.1.0.md
                    # Substitute ${OWNER}, ${REPO}, ${TAG} placeholders.
                    OWNER="$OWNER" REPO="$REPO" TAG="v0.1.0" \
                        python3 - "docs/releases/v0.1.0.md" <<'PYEOF'
import os, sys
path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    body = f.read()
for k in ("OWNER", "REPO", "TAG"):
    body = body.replace("${" + k + "}", os.environ.get(k, ""))
with open(path, "w", encoding="utf-8") as f:
    f.write(body)
PYEOF
                    rm -f templates/release-notes.md.template
                    echo "  -> docs/releases/v0.1.0.md (starter notes)"
                fi
            else
                echo "  Skipped seeding v0.1.0.md. templates/release-notes.md.template stays available."
            fi
        fi
    else
        echo "  Skipped."
    fi
fi

# main-broken sentinel — post-merge build sentinel (issue #21).
if [ -f ".github/workflows/main-broken-sentinel.yml.template" ]; then
    echo "  main-broken-sentinel.yml runs a quick verify on every push to main"
    echo "  and files an issue if main is broken. Recommended for projects that"
    echo "  have NOT enabled GitHub merge queue. Cheap to keep on either way."
    if prompt_yn "Enable main-broken sentinel workflow?" "y"; then
        rename_template ".github/workflows/main-broken-sentinel.yml.template" ".github/workflows/main-broken-sentinel.yml"
    else
        echo "  Skipped."
    fi
fi

# Smoke-test playbook (issue #20).
if [ -f "templates/smoke-test-playbook.md.template" ]; then
    if prompt_yn "Install starter smoke-test playbook (recommended for projects with a UI / SPA / interactive demo)?" "n"; then
        SMOKE_DEFAULT_PATH="docs/SMOKE_TEST.md"
        SMOKE_PATH=$(prompt_default "Playbook path" "$SMOKE_DEFAULT_PATH")
        if [ -f "$SMOKE_PATH" ]; then
            echo "  $SMOKE_PATH already exists; leaving in place (re-run safe)."
            rm -f templates/smoke-test-playbook.md.template
        else
            rename_template "templates/smoke-test-playbook.md.template" "$SMOKE_PATH"
        fi
    else
        echo "  Skipped. templates/smoke-test-playbook.md.template stays available."
    fi
fi

# Agent-team calibration log (issue #20 amendment).
if [ -f "docs/research/agent-team-calibration.md" ]; then
    echo "  docs/research/agent-team-calibration.md (calibration drift log) already in tree; no action."
fi

# -----------------------------------------------------------------
# Labels
# -----------------------------------------------------------------

echo
create_label "compliance-review"              "b60205" "Trust-boundary gate cleared by an authorised compliance reviewer"
create_label "doc-stale"                      "fbca04" "Documentation drift discovered by doc-keeper or per-merge adversary check"
create_label "coverage-skip"                  "ededed" "Bypass per-package coverage gate; expected to be paired with a follow-up baseline-update PR"
create_label "automerge"                      "0e8a16" "Dependabot patch/minor PR — auto-merge after CI green"
create_label "dependabot:major-review-needed" "d93f0b" "Dependabot major bump — human review required"
create_label "main-broken"                    "b60205" "Post-merge sentinel detected main fails quick verify; merge cascade likely"
create_label "dependencies"                   "0e8a16" "Tracks a cross-repo dependency surfaced by another repo's orchestrator (per AGENTS.md)"
create_label "watched-path"                   "5319e7" "Touches a compliance-sensitive watched path; trust-boundary gate applies"
create_label "for-orchestrator"               "1d76db" "In the orchestrator session's lane (multi-session pickup channel)"
create_label "for-navigator"                  "c5def5" "In the navigator session's lane (multi-session pickup channel)"
create_label "audit"                          "d4c5f9" "Surfaced by an audit (docs, security, coverage) for follow-up"
create_label "tech-debt"                       "e99695" "Known shortcut or deferred cleanup to revisit"

# -----------------------------------------------------------------
# Build-phase milestones (optional)
# -----------------------------------------------------------------

echo
echo "Build-phase milestones mirror the architecture doc's build phases."
echo "This creates 'Phase N' milestones plus matching phase-N labels the"
echo "orchestrator filters on. You can rename or add more later. 0 to skip."
PHASE_COUNT=$(prompt_default "Number of build phases to scaffold" "0")
if [[ "$PHASE_COUNT" =~ ^[0-9]+$ ]] && [ "$PHASE_COUNT" -gt 0 ]; then
    phase_i=1
    while [ "$phase_i" -le "$PHASE_COUNT" ]; do
        create_milestone "Phase $phase_i"
        create_label "phase-$phase_i" "ededed" "Work in build Phase $phase_i (mirrors the 'Phase $phase_i' milestone)"
        phase_i=$((phase_i + 1))
    done
else
    echo "  Skipped milestone scaffolding."
fi

# -----------------------------------------------------------------
# Pre-push hook (optional)
# -----------------------------------------------------------------

echo
if [ "$STACK" != "go" ]; then
    echo "Note: the pre-push hook recipe is Go-specific (build + vet + test +"
    echo "go mod tidy). For a $STACK project, adapt scripts/install-pre-push-hook.sh"
    echo "to your toolchain before installing it."
fi
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
# Branch protection (optional) — v3 maintainer-identity allowlist
# -----------------------------------------------------------------

echo
if prompt_yn "Configure initial branch protection on 'main'?" "n"; then
    echo
    echo "v3 branch protection uses a maintainer-identity allowlist so the solo-"
    echo "maintainer human-author = merger case stays unblocked, while bot/agent"
    echo "identities trigger the non-author-approval requirement. The allowlist"
    echo "is a comma-separated list of GitHub usernames."
    echo
    DEFAULT_BOT_ALLOWLIST="dependabot[bot],cursor[bot],github-actions[bot]"
    BOT_ALLOWLIST=$(prompt_default "Bot/agent identity allowlist" "$DEFAULT_BOT_ALLOWLIST")

    # Required status checks are language-aware. The Go jobs (build-and-
    # test, lint) are path-gated and skip on non-Go PRs, so they cannot be
    # required directly — a skipped *required* check leaves the PR pending
    # forever. Go projects require the fail-closed `ci-pass` aggregator
    # instead; other stacks require only the trust-boundary gate until
    # their own pipeline exists.
    if [ "$STACK" = "go" ]; then
        REQUIRED_CONTEXTS='"ci-pass", "trust-boundary-gate"'
    else
        REQUIRED_CONTEXTS='"trust-boundary-gate"'
        echo "  Stack is $STACK: required checks set to trust-boundary-gate only."
        echo "  Add your CI's overall check to branch protection once it exists."
    fi

    echo "Creating branch protection on main..."
    # The native branches-protection API does not support author-identity
    # conditional approval directly; that's a Rulesets capability. The
    # protection rule we apply here is a sensible default — required
    # checks + 1 approval + linear history. To get the conditional
    # author-identity behaviour, apply a Repository Ruleset via the
    # GitHub UI (Settings → Rules → Rulesets → New ruleset → "Restrict
    # contributors") and reference the allowlist there. See
    # docs/setup.md §Branch protection.
    BP_PAYLOAD=$(cat <<JSON
{
  "required_status_checks": {
    "strict": true,
    "contexts": [${REQUIRED_CONTEXTS}]
  },
  "enforce_admins": false,
  "required_pull_request_reviews": {
    "required_approving_review_count": 1,
    "dismiss_stale_reviews": true,
    "require_code_owner_reviews": true
  },
  "required_linear_history": true,
  "restrictions": null
}
JSON
)
    if echo "$BP_PAYLOAD" | gh api -X PUT \
        "/repos/$OWNER/$REPO/branches/main/protection" \
        --input - >/dev/null 2>&1; then
        echo "  ok"
        echo "  bot/agent allowlist saved as a documentation reference; configure"
        echo "  the conditional approval rule via Settings → Rules → Rulesets,"
        echo "  using this list: $BOT_ALLOWLIST"
        echo "  See docs/setup.md §Branch protection for the ruleset shape."
    else
        echo "  error: could not apply branch protection. Apply manually via" >&2
        echo "  GitHub Settings → Branches, or re-run with appropriate gh auth scopes." >&2
    fi
else
    echo "Skipped. Configure via GitHub Settings → Branches when ready."
fi

# -----------------------------------------------------------------
# GitHub merge queue (optional)
# -----------------------------------------------------------------

echo
if prompt_yn "Enable GitHub merge queue on 'main' (recommended for parallel-agent throughput)?" "y"; then
    # Enable merge queue via REST PUT to branch protection — set the
    # required_merge_queue settings to defaults. The native REST shape
    # for merge queue lives under
    # /repos/{owner}/{repo}/branches/{branch}/protection/required_status_checks
    # and a separate /required_merge_queue object on the protection.
    # GitHub's preferred enable path is via the UI ("Require merge queue"
    # checkbox under branch-protection-rules) — the API equivalent is:
    #
    #   gh api -X POST /repos/$OWNER/$REPO/branches/main/required_merge_queue
    #
    # We attempt that here and report on the outcome. If branch protection
    # is not yet configured, the call will fail — and that's fine; the
    # user can re-run after branch protection is applied.
    if gh api -X POST "/repos/$OWNER/$REPO/branches/main/required_merge_queue" >/dev/null 2>&1; then
        echo "  ok — merge queue is enabled on main"
        echo "  Required checks now run via merge_group: triggers (already in"
        echo "  the template's ci.yml and trust-boundary.yml). See AGENTS.md"
        echo "  merge-cascade clarification."
    else
        echo "  error: could not enable merge queue via API. Enable manually via" >&2
        echo "  Settings → Branches → main → Edit → Require merge queue." >&2
    fi
else
    echo "Skipped. Enable later via Settings → Branches → main → Require merge queue."
fi

# -----------------------------------------------------------------
# Footer
# -----------------------------------------------------------------

if [ "$STACK" = "go" ]; then
    CI_NEXT_STEP="Review .github/workflows/ci.yml (Go pipeline, active for this repo)."
else
    CI_NEXT_STEP="Replace the Go reference .github/workflows/ci.yml.template with your ${STACK} pipeline, then rename it to ci.yml. The job-shape carries over."
fi

cat <<EOF

Bootstrap complete.

Stack: $STACK

Next steps:
  1. Set GOOGLE_AI_STUDIO_API_KEY in your shell env (free key at
     https://aistudio.google.com). The plan-reviewer subagent uses it.
  2. $CI_NEXT_STEP
  3. Edit .github/CODEOWNERS to reference real team handles once they
     exist in your org.
  4. Start the orchestrator: cd <repo> && claude.
  5. Tell it what to build. Approve at the four gates: approach, spec,
     plan-mission, compliance-routed PRs.

Reusable skills ship in .claude/skills/ (ci-watch, prune-worktrees,
domain-adversary-checklist) — see docs/skills.md. Built-in skills
(code-review, verify, deep-research) are available too.

Re-running this script is safe — it is idempotent.
EOF
