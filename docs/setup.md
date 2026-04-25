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
3. Substitute `${OWNER}`, `${REPO}`, `${WATCHED_PATHS}`, `${WATCHED_PATHS_AS_CODEOWNER_LINES}` placeholders across `.template` files.
4. Rename `*.template` files to their final names (`ci.yml.template` → `ci.yml`, `CODEOWNERS.template` → `CODEOWNERS`).
5. Prompt for `ANTHROPIC_API_KEY` and set it via `gh secret set` (skip with empty input).
6. Create the `compliance-review` label via `gh api`.
7. Optionally create initial branch protection on `main` (prompts).

The script is idempotent — re-running it after editing `${WATCHED_PATHS}` regenerates the substituted files.

## Step 3 — replace the example CI

The shipped `.github/workflows/ci.yml` (after bootstrap renames it from `.template`) is a Go example. If your project uses a different toolchain:

- Replace `setup-go` with the equivalent setup action for your language (`setup-node`, `setup-python`, `setup-rust`, etc.).
- Replace the Go-specific `run:` steps with your build / test / vet / lint commands.
- Keep the **`concurrency`** block as-is — it cancels in-flight runs on the same ref when a fresh push lands. This is a key efficiency win during agent-driven workflows.

The agentic-review and trust-boundary workflows are language-agnostic; they need no change.

## Step 4 — verify

Open a draft PR that touches a non-sensitive file (e.g. README). Watch:

| Workflow | Expected behaviour |
| --- | --- |
| `CI` | Runs your build / test / vet / lint pipeline. |
| `agentic-review` | Skipped (PR is a draft). Once you mark ready-for-review, posts a sticky comment. |
| `trust-boundary-gate` | Reports "no compliance-sensitive paths touched; skipping." |

Then open a second PR that touches one of the watched paths you configured. Watch:

| Workflow | Expected behaviour |
| --- | --- |
| `trust-boundary-gate` | Posts a sticky comment listing the touched paths. Status is **PENDING** until the `compliance-review` label is applied or an APPROVED review on HEAD is registered. |

## Step 5 — ongoing

- Replace placeholder team handles in `.github/CODEOWNERS` with your real ones once teams exist in your org.
- Adjust `SENSITIVE_PATHS` env var in `.github/workflows/agentic-review.yml` to mirror the trust-boundary watched paths (so the agentic review surfaces the same architectural-invariants signal).
- Read `AGENTS.md` and adjust the operating principles to match your team's conventions.

## Troubleshooting

| Symptom | Diagnosis | Fix |
| --- | --- | --- |
| `agentic-review` workflow skipped on every PR | PR is in draft state, or has the `agentic-review:skip` label | Mark PR ready-for-review, or remove the label |
| `agentic-review` posts "Status: degraded — ANTHROPIC_API_KEY secret is not set" | Secret missing | Re-run `scripts/bootstrap.sh` and supply the key, or set it manually via `gh secret set ANTHROPIC_API_KEY` |
| `trust-boundary-gate` says "no compliance-sensitive paths touched" but you expected it to fire | Watched paths in the workflow do not match the touched files | Check the `paths:` block under `on.pull_request` in `.github/workflows/trust-boundary.yml` and the `watched` array inside the script step; they must match |
| `gh secret set` fails with "Resource not accessible by integration" | The CLI auth lacks `admin:repo_hook` / secrets scope | Run `gh auth refresh -s admin:repo_hook,write:repo_hook` or set the secret via the GitHub UI |
| CODEOWNERS lines reference a team that does not exist | Team has not been created in the org yet | Create the team in your GitHub org settings, or remove the team reference until it does |
