# Setup

> Bootstrap walkthrough for a repo instantiated from `claude-code-setup`.

## Prereqs

| Requirement | Why |
| --- | --- |
| `gh` CLI authenticated to your GitHub account | The bootstrap script reads repo metadata, sets secrets, creates labels, and (optionally) configures branch protection via `gh api`. |
| A GitHub repo created from this template | Click **Use this template** on `https://github.com/jk-nd/claude-code-setup`. |
| `bash` 4+ (POSIX-compatible shells work) | `scripts/bootstrap.sh` is plain bash. |
| (Optional) `ANTHROPIC_API_KEY` | Required only if you want agentic PR review to be live; the workflow degrades gracefully when the secret is missing. **There are three auth choices** (paid key / `anthropics/claude-code-action` / skip review entirely) — see [README §Authentication](../README.md#authentication) for the trade-offs before you pick. |

## Step 1 — instantiate the template

1. Navigate to `https://github.com/jk-nd/claude-code-setup`.
2. Click **Use this template** → **Create a new repository**.
3. Choose owner and name. Keep the default branch as `main`.
4. Clone locally:

   ```sh
   git clone https://github.com/<YOUR_OWNER>/<YOUR_REPO>
   cd <YOUR_REPO>
   ```

## Step 2 — run the bootstrap script

```sh
./scripts/bootstrap.sh
```

The script will:

1. Detect owner + name from `gh repo view`.
2. Prompt for the comma-separated list of compliance-sensitive paths (e.g. `internal/policy/,internal/audit/`).
3. Substitute `${OWNER}`, `${REPO}`, `${WATCHED_PATHS}`, `${WATCHED_PATHS_AS_CODEOWNER_LINES}` placeholders across the always-rename `*.template` files.
4. Rename always-rename `*.template` files to their final names: `ci.yml.template` → `ci.yml`, `CODEOWNERS.template` → `CODEOWNERS`.
5. Prompt for the **opt-in** templates (separately, one prompt each):
   - `templates/claude-settings.json.template` → `.claude/settings.json` (curated permissions allowlist for Claude Code subagents).
   - `.github/dependabot.yml.template` → `.github/dependabot.yml`.
   - `.github/workflows/govulncheck.yml.template` → `.github/workflows/govulncheck.yml`.
   - `.github/workflows/nightly.yml.template` → `.github/workflows/nightly.yml`.
6. Prompt for `ANTHROPIC_API_KEY` and set it via `gh secret set` (skip with empty input).
7. Create labels: `compliance-review`, `agentic-review:skip`, `agentic-review:degraded`, `coverage-skip`.
8. Optionally install the strict-recipe pre-push git hook (`scripts/install-pre-push-hook.sh`).
9. Optionally create initial branch protection on `main`.

The script is idempotent — re-running it after editing `${WATCHED_PATHS}` regenerates the substituted files. Templates already renamed are skipped on subsequent runs.

## Step 3 — replace the example CI

The shipped `.github/workflows/ci.yml` (after bootstrap renames it from `.template`) is a Go example with a few extras built in:

| Feature | Purpose |
| --- | --- |
| `paths` job + `dorny/paths-filter@v3` | Per-job path filtering for downstream jobs. The default jobs (build-and-test, lint, actionlint) don't need filtering — they're cheap enough to run unconditionally. Use the `paths` job's outputs to gate project-specific jobs (e2e, fuzz, examples) you add later. |
| `actionlint` job | Lints workflow YAML on `.github/workflows/**` changes. Catches the `matrix.<key>` in job-level `if:` class of bug pre-merge. |
| Concurrency cancellation | `cancel-in-progress: true` on the same ref. Saves CI minutes during agent-driven workflows. |
| Commented-out `e2e:` example | Shows the paths-filter pattern for a downstream job. Uncomment + adapt. |
| Commented-out `coverage-gate:` example | Shows the wiring for the (opt-in) coverage gate. See **Coverage gate** below. |

If your project uses a different toolchain:

- Replace `setup-go` with the equivalent setup action for your language (`setup-node`, `setup-python`, `setup-rust`, etc.).
- Replace the Go-specific `run:` steps with your build / test / vet / lint commands.
- Keep the **`concurrency`** block, the **`paths`** job (for the `workflows` filter), and the **`actionlint`** job — they're language-agnostic.

The agentic-review and trust-boundary workflows are language-agnostic; they need no change.

## Coverage gate

The template ships a Go binary at `cmd/coverage-gate/` that enforces a per-package coverage baseline against a JSON file (`ops/coverage-baseline.json`). It's **opt-in** — you flip it on by populating the baseline file and uncommenting the `coverage-gate:` job in `.github/workflows/ci.yml`.

### How the gate decides

| Status | Condition |
| --- | --- |
| **PASS** | Measured coverage ≥ threshold (with a 0.05pp float-comparison slack) for every baselined package. |
| **FAIL** | A baselined package regressed below threshold — the job exits 1, the PR check goes red. |
| **WARN** | An unbaselined package is below 50% coverage — annotation only, never blocks. |

### Operator procedure

1. **Pick compliance-critical packages.** Anything in your project that an external assessor (ISO / SOC / GDPR) would care about: policy, audit, auth, admin-listener, the MCP/API surface. Don't list everything; that turns the gate into noise.

2. **Populate the baseline file.** Copy `ops/coverage-baseline.json.example` to `ops/coverage-baseline.json` and edit the `thresholds` map:

   ```json
   {
     "thresholds": {
       "github.com/<OWNER>/<REPO>/internal/policy": 84.9,
       "github.com/<OWNER>/<REPO>/internal/audit":  87.5
     }
   }
   ```

   Set values to the **measured-current** coverage at the time you instantiate (run `go test -coverprofile=cov.out ./...` then `go tool cover -func=cov.out` to read per-package numbers; round down to the tenth to leave a tiny float slack).

3. **Uncomment the `coverage-gate:` job in `.github/workflows/ci.yml`.** The block is shipped commented-out so the template doesn't ship a job that fails on day one.

4. **Confirm `coverage-skip` label exists.** The bootstrap script creates it; if you ran bootstrap before the coverage-gate baseline was in place, just re-run bootstrap. Or create manually:

   ```sh
   gh label create coverage-skip --color fbca04 \
     --description "Bypass per-package coverage gate; expected to be paired with a follow-up baseline-update PR"
   ```

5. **Open a PR that touches a baselined package.** The `coverage-gate` job runs, writes a markdown summary to `$GITHUB_STEP_SUMMARY`, and exits 0 / 1.

### When a regression is legitimate

For permanent drops (deleting a module, restructuring packages), file a **separate baseline-update PR** that re-measures and lowers the threshold to the new measured-current floor. Do this BEFORE the dependent change PR.

For temporary drops (in-flight refactor, doc-only PR with measurement noise on an unrelated package), apply the **`coverage-skip` label** to the PR. The gate logs every PASS/FAIL/WARN line and writes the step summary, but exits 0. The label is auditable in the PR timeline.

The decision lens: **temporary** dips get the label; **permanent** dips get a baseline-update PR. Mixing the two — applying the label AND quietly editing the baseline in the same PR — defeats the audit-trail purpose of both.

### Running the gate locally

```sh
go test -coverprofile=cov.out -short -timeout=300s ./...
go run ./cmd/coverage-gate --baseline=ops/coverage-baseline.json --profile=cov.out
```

Exit 0 means every baselined package meets threshold. Exit 1 means at least one regressed (the workflow output names which one).

## Pre-push hook

The bootstrap script offers to install `scripts/install-pre-push-hook.sh`, which writes `.git/hooks/pre-push` with a strict-recipe gate. The hook:

1. **Refuses the push when the working tree has uncommitted changes.** This addresses the "agent verifies on uncommitted changes, then pushes an older commit" failure mode that surfaced repeatedly during agentic operating-days.
2. Runs `go build ./...`, `go vet ./...`, `go test -short -timeout=300s -count=1 ./...`.
3. Runs `go mod tidy` and rejects if `go.mod` / `go.sum` would diverge.

Install / re-install:

```sh
./scripts/install-pre-push-hook.sh
```

Bypass for a single push (e.g. work-in-progress to a personal branch):

```sh
git push --no-verify
```

Uninstall:

```sh
rm .git/hooks/pre-push
```

The hook is local — `.git/hooks/` is not committed. Each developer / agent must install it once. The bootstrap script's pre-push prompt is the simplest path; agents and human operators can also call the installer directly.

## Step 4 — verify

Open a draft PR that touches a non-sensitive file (e.g. README). Watch:

| Workflow | Expected behaviour |
| --- | --- |
| `CI / build-and-test` | Runs your build / test / vet / lint pipeline. |
| `CI / lint` | Runs golangci-lint (or your stack's linter). |
| `CI / actionlint` | Skipped (no `.github/workflows/**` changes). |
| `agentic-review` | Skipped (PR is a draft). Once you mark ready-for-review, posts a sticky comment. |
| `trust-boundary-gate` | Reports "no compliance-sensitive paths touched; skipping." |

Then open a second PR that touches one of the watched paths you configured. Watch:

| Workflow | Expected behaviour |
| --- | --- |
| `trust-boundary-gate` | Posts a sticky comment listing the touched paths. Status is **PENDING** until the `compliance-review` label is applied or an APPROVED review on HEAD is registered. |

To verify `actionlint` triggers, push a commit that edits any file under `.github/workflows/`:

| Workflow | Expected behaviour |
| --- | --- |
| `CI / actionlint` | Runs and reports any YAML / context-scope errors. |

## Step 5 — ongoing

- Replace placeholder team handles in `.github/CODEOWNERS` with your real ones once teams exist in your org.
- Adjust `SENSITIVE_PATHS` env var in `.github/workflows/agentic-review.yml` to mirror the trust-boundary watched paths (so the agentic review surfaces the same architectural-invariants signal).
- Read `AGENTS.md` and adjust the operating principles to match your team's conventions.
- (If you opted in to nightly) edit the `matrix.include` block in `.github/workflows/nightly.yml` to point at your project's fuzz targets and slow-test packages.

## Troubleshooting

| Symptom | Diagnosis | Fix |
| --- | --- | --- |
| `agentic-review` workflow skipped on every PR | PR is in draft state, or has the `agentic-review:skip` label, or `AGENTIC_REVIEW_ENABLED` repo variable is unset / not `'true'` | Mark PR ready-for-review, remove the label, or set the variable. |
| `agentic-review` posts "Status: degraded — ANTHROPIC_API_KEY secret is not set" | Secret missing | Re-run `scripts/bootstrap.sh` and supply the key, or set it manually via `gh secret set ANTHROPIC_API_KEY`. |
| `trust-boundary-gate` says "no compliance-sensitive paths touched" but you expected it to fire | Watched paths in the workflow do not match the touched files | Check the `paths:` block under `on.pull_request` in `.github/workflows/trust-boundary.yml` and the `watched` array inside the script step; they must match. |
| `CI / actionlint` fails with a context-scope error on a `matrix.<key>` reference in a job-level `if:` | The matrix context is not in scope for `jobs.<id>.if` | Move the `matrix.<key>` reference into the job's `steps[*].if`. The matrix context is available there. |
| `coverage-gate` fails on a PR you expect to be unrelated | Coverage measurement noise on an unrelated package, or a baselined package was renamed | Apply the `coverage-skip` label for noise; file a baseline-update PR for renames. See **Coverage gate** above. |
| `gh secret set` fails with "Resource not accessible by integration" | The CLI auth lacks `admin:repo_hook` / secrets scope | Run `gh auth refresh -s admin:repo_hook,write:repo_hook` or set the secret via the GitHub UI. |
| CODEOWNERS lines reference a team that does not exist | Team has not been created in the org yet | Create the team in your GitHub org settings, or remove the team reference until it does. |
| Pre-push hook rejects push: "uncommitted changes; commit first" | Working tree is dirty when invoking `git push` | Commit or stash the changes; the hook ensures verification runs against the committed state, not the dirty tree. |
