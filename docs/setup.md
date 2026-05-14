# Setup — operator's guide

This is the operator's reference for everything `scripts/bootstrap.sh` configures, plus the manual steps the script cannot do.

See [`README.md`](../README.md) for the one-paragraph overview and [`AGENTS.md`](../AGENTS.md) for the orchestrator's operating contract.

## What bootstrap does

1. Detects owner + repo from `gh repo view`.
2. Prompts for `WATCHED_PATHS` (compliance-sensitive paths).
3. Prompts for `ceremony_level` (`foundation` | `demo` | `iterate-fast`).
4. Substitutes placeholders into the always-renamed template files (`ci.yml`, `CODEOWNERS`).
5. Prompts for opt-in template renames: docs-audit, dependabot, govulncheck, nightly, `.claude/settings.json`, dependabot-automerge, dependabot-rebase-stale, main-broken-sentinel, smoke-test playbook.
6. Creates labels: `compliance-review`, `doc-stale`, `coverage-skip`, `automerge`, `dependabot:major-review-needed`, `main-broken`, `agentic-review:degraded`.
7. Optionally installs the strict-recipe pre-push git hook.
8. Optionally configures branch protection on `main`.
9. Optionally enables GitHub merge queue on `main`.

The script is idempotent — re-running it is safe.

## Ceremony level

`AGENTS.md` carries a top-of-file `ceremony_level:` field. Bootstrap writes it during instantiation; you can change it later by editing the line.

- **`foundation`** (default) — full architect → spec → planner → plan-reviewer → implementer → adversary → doc-keeper loop. Use for product foundations and anything compliance-routed.
- **`demo`** — approach + spec collapsed; planner optional; plan-reviewer optional. Use for visible-but-not-foundational pilots.
- **`iterate-fast`** — single doc per slice; implementer + adversary + doc-keeper only. Use for demos and quick-iterate sandboxes.

Agent definitions consult the field; skipped agents emit a one-line note instead of running.

## Coverage gate

Opt-in. Ship the `cmd/coverage-gate/` binary, `ops/coverage-baseline.json` (per-package floor), and uncomment the `coverage-gate:` block in `.github/workflows/ci.yml`.

The v3 gate uses a **three-band** evaluation per claude-code-setup#6 Section G:

| Measured vs. threshold | Status | Effect |
| --- | --- | --- |
| ≥ threshold − epsilon (0.05) | PASS | exit 0 |
| threshold − warnBand (0.3) ≤ measured < threshold − epsilon | WARN | logged + step summary; exit 0 |
| < threshold − warnBand | FAIL | exit 1 |

WARN-band lets the baseline tolerate gentle drift (e.g., a single defensive-coverage addition) without forcing a follow-up baseline-update PR. Real regressions (more than 0.3 below the floor) still FAIL the gate.

To override a FAIL: apply the `coverage-skip` label to the PR + open a follow-up `ci(baseline-update)` PR documenting the rationale.

Local invocation:

```bash
go test -coverprofile=cov.out -short ./...
go build -o /tmp/coverage-gate ./cmd/coverage-gate
/tmp/coverage-gate --baseline=ops/coverage-baseline.json --profile=cov.out
```

## Pre-push hook

`scripts/install-pre-push-hook.sh` writes `.git/hooks/pre-push` with the strict recipe: dirty-tree check, `go build`, `go vet`, `go test`, `go mod tidy`, `git diff --exit-code go.mod go.sum`. Catches the agent-side pre-push failure mode where the verification ran on uncommitted changes and the post-commit state diverged.

Bypass: `git push --no-verify` (use sparingly; agents must not).

## Paths filter pattern

`ci.yml.template` ships a `paths:` job using `dorny/paths-filter@v3`. Downstream jobs (e2e, coverage-gate, fuzz, oscal-check) consume `needs.paths.outputs.<filter-name>` in a `if:` clause to skip when their inputs didn't change. The default template wires the `workflows:` filter to gate `actionlint` and lists Go paths under `go:` for project use. Add new filters as your project grows.

## Branch protection

Bootstrap applies a sensible default via the native branches-protection API: required checks (`build-and-test`, `lint`, `trust-boundary-gate`), 1 approval, `dismiss_stale_reviews`, `require_code_owner_reviews`, `required_linear_history: true`.

### Maintainer-identity allowlist (v3)

The native API does not support author-identity-conditional approval directly — that lives in GitHub **Repository Rulesets** (Settings → Rules → Rulesets → New ruleset).

The shape v3 recommends (claude-code-setup#7):

- Required-approvals rule with `1` reviewer, EXCEPT when the PR author's identity is in the maintainer-identity allowlist (`dependabot[bot]`, `cursor[bot]`, `github-actions[bot]`, plus any project-specific bot/agent identities).
- For those allowlisted authors, a non-author approval is required.
- For other authors (a solo maintainer creating + merging their own PR), the approval requirement is relaxed.

Bootstrap saves the allowlist as a documentation reference; you apply the rule via the UI because the underlying Rulesets API call requires permission scopes beyond what `gh auth` typically provides for a fresh repo.

Reference: [GitHub Rulesets — restrict contributors](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/creating-rulesets-for-a-repository).

## GitHub merge queue

Bootstrap offers to enable merge queue via `gh api -X POST /repos/{owner}/{repo}/branches/main/required_merge_queue` (default: yes).

Once enabled:

- Required checks must react to `merge_group: { types: [checks_requested] }` as well as `pull_request`. The template's `ci.yml.template` and `trust-boundary.yml` already carry the `merge_group:` trigger.
- The queue re-runs CI against each PR rebased onto post-previous-merge `main`, eliminating the merge-cascade collision pattern (#21 in `docs/operating.md`).
- No more manual `@dependabot rebase` pings for stale PRs.

Disable via Settings → Branches → main → Edit → Require merge queue (uncheck).

## Dependabot

Opt-in. `.github/dependabot.yml.template` ships a default config (weekly batches, `open-pull-requests-limit: 5`, grouped patch+minor for github-actions). Rename by bootstrap.

### Auto-merge for patch / minor

Opt-in (depends on Dependabot being on). `dependabot-automerge.yml.template` auto-merges patch + minor bumps once CI passes; majors are labelled `dependabot:major-review-needed` for human review.

Activate by:

1. Renaming the workflow template (bootstrap does this when you opt in).
2. Setting the `DEPENDABOT_AUTOMERGE_ENABLED` repo variable: `gh variable set DEPENDABOT_AUTOMERGE_ENABLED -b true`.
3. Confirming branch protection allows `dependabot[bot]` to merge (or configure the maintainer-identity allowlist bypass).

Override per-PR: remove the `automerge` label before CI completes, or comment `@dependabot ignore this minor version`.

### Auto-rebase stale dependabot PRs

Opt-in (depends on Dependabot being on). `dependabot-rebase-stale.yml.template` runs nightly (04:00 UTC) and posts `@dependabot rebase` to any open dependabot PR in `CONFLICTING` state. Eliminates the "every dependabot PR sits stale for hours waiting for a manual ping" failure mode.

## Main-broken sentinel

Opt-in. `main-broken-sentinel.yml.template` runs a quick verify (default: `go build ./...`) on every push to `main` and files a `main-broken` issue + comments on the offending PR if it fails. Catches merge-cascade collisions when merge queue isn't enabled.

Replace the `go build ./...` line in the workflow with your project's quick-verify command (target: ≤30s).

## ANTHROPIC_API_KEY and agentic-review

v3's default `adversary` subagent runs locally via the orchestrator's Claude Code session (using your Max/Ultra OAuth) and does NOT require `ANTHROPIC_API_KEY` as a repo secret.

If your project re-introduces a CI-side LLM review (v1's `cmd/agentic-review/` pattern):

1. Set `ANTHROPIC_API_KEY` as a repo secret. Configure a budget cap on the [Anthropic console](https://console.anthropic.com/).
2. Opt in to `agentic-review-degraded-label.yml.template` so degraded runs (missing key, quota hit) get the `agentic-review:degraded` label applied automatically.
3. Optionally make the label's absence a required check via branch protection.

See `docs/agentic-review.md` for the contract.

## Smoke-test playbook

Opt-in. `templates/smoke-test-playbook.md.template` ships a generic shape (preflight / flow N / offline / rough edges / per-run report). Bootstrap prompts for the install path (default `docs/SMOKE_TEST.md`).

Per [AGENTS.md operating clarification #20](../AGENTS.md#smoke-test-playbook-contract):

- The playbook stays in sync with user-facing flows.
- PRs that touch user-facing surfaces but leave the playbook unchanged are flagged by `adversary`'s **Smoke-test sync** dimension at MEDIUM.
- Stale entries are a doc bug.

## Calibration log

`docs/research/agent-team-calibration.md` ships in the template as a stub. The orchestrator appends drift entries as they're noticed; patterns that recur across entries are candidates for upstream amendment.

Single-line entries are one of the exhaustive direct-to-`main` exceptions in the merge policy (see AGENTS.md). Multi-line entries flow through `doc-keeper` + PR.

## What bootstrap does NOT do

- Replace the placeholder paths in `.github/workflows/trust-boundary.yml` with your project's actual compliance paths. Edit the file manually after bootstrap.
- Edit `.github/CODEOWNERS` to reference real team handles. Bootstrap fills the owner placeholder; team handles must already exist in your org.
- Replace the Go-flavoured `ci.yml` with your stack's toolchain. The job shape (paths-filter / build-and-test / lint / actionlint) carries over; replace per-language `run:` lines.
- Apply Repository Rulesets (only basic branch protection). Use the GitHub UI for the maintainer-identity allowlist rule.
