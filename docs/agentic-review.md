# Agentic review — v3

v3's default code-review path is the `adversary` subagent (pre-PR, full orchestrator context, opt-out impossible by design — see `.claude/agents/adversary.md`). This supersedes the v1 CI-side `cmd/agentic-review/` workflow, which the v2 audit showed produced near-zero useful signal because it ran post-PR with truncated context.

This doc covers:

1. The `adversary` review dimensions (the in-flight contract).
2. The opt-in `agentic-review-degraded-label.yml.template` workflow for projects that DO re-introduce a CI-side LLM review.
3. The smoke-test sync dimension added in v3.

## What `adversary` reviews

Run pre-PR against the implementer's diff. Adversarial framing: find what's wrong. Different model class than the implementer (default: Opus reviewing Sonnet work).

Seven dimensions:

| # | Dimension | What it checks |
| --- | --- | --- |
| 1 | Spec-coverage | Does the diff satisfy every behavior the spec section names? |
| 2 | Test-coverage | Do `test-author`'s tests actually exercise the path the implementer wrote? |
| 3 | Unstated assumptions | Input shape, ordering, concurrency, lifetimes, errors, env not guaranteed by the spec. |
| 4 | Side effects | New globals, file/network/env IO, mutex/goroutine spawns not sanctioned. |
| 5 | Stale claims | Commit message / PR description matches the diff. |
| 6 | Doc-freshness | User-facing surface touched → matching doc update in the same diff. |
| 7 | **Smoke-test sync** (v3) | User-facing surface touched + smoke-test playbook exists → playbook updated. |

Verdict: `pass` / `fail` / `needs-clarification`. Each entry cites file:line evidence.

## Smoke-test sync dimension (v3)

If the diff touches paths matching `web/`, `static/`, `frontend/`, `ui/`, or `cmd/<binary>` whose name contains `tui` / `cli` / `web`, AND a smoke-test playbook exists in the repo (`*_SMOKE_TEST.md` or `e2e/MANUAL.md`), `adversary` checks whether the playbook was also updated in the PR.

If not, the dimension surfaces as a Concern at **MEDIUM** severity with the relevant file paths cited.

The check is conservative: a false positive (flagging a PR that doesn't actually need a playbook update) is recoverable; a false negative (missing a stale-playbook gap) is the failure mode this dimension exists to prevent.

Recovery: see [`docs/operating.md` § When `adversary` flags Smoke-test sync](operating.md#when-adversary-flags-smoke-test-sync).

## Opt-in CI-side LLM review

Some projects re-introduce a CI-side LLM review on top of `adversary` (e.g., for diversity of opinion, or for compliance-routed PRs where a separate evidence trail is required). For those, v3 ships:

- `.github/workflows/agentic-review-degraded-label.yml.template` — auto-applies the `agentic-review:degraded` label when the upstream review workflow finishes in any non-success state. Auto-removes the label on a successful re-run.
- The `agentic-review:degraded` label itself (created by bootstrap).
- A documented contract for `ANTHROPIC_API_KEY` as a repo secret with a budget cap.

### Wiring

1. Bootstrap-opt-in: when prompted, accept `Enable agentic-review degraded-mode label workflow?`. The template renames to `.yml`.
2. Edit the workflow's `workflows: [<your-review-job>]` line to name your CI-side review workflow.
3. Add `if: failure() || steps.<your-step>.outputs.degraded == 'true'` branches at the relevant detection points in your review workflow.
4. (Optional) Configure branch protection to treat the `agentic-review:degraded` label as a required-absent label.
5. Set `ANTHROPIC_API_KEY` as a repo secret. Configure a budget cap on the Anthropic console.

### Why v3 default does NOT enable this

`adversary`'s OAuth-based local invocation does not have a CI-side degraded mode in the same way: it uses the orchestrator's existing Claude subscription, not a secret-stored API key, and runs locally rather than in a GitHub Actions job. If `adversary` can't run, the orchestrator surfaces it directly to the user — no silent-degraded-pass failure mode to label around.

The label workflow is shipped for completeness; projects that don't add a CI-side review can ignore it.

## What changed from v1 / v2

- **v1**: `cmd/agentic-review/` CI workflow, opt-out via env var, near-zero useful signal in practice. Audited and disabled mid-2026.
- **v2**: `adversary` subagent replaces v1; six review dimensions; pre-PR with full orchestrator context; OAuth-based, no API key secret needed. CI-side path removed entirely.
- **v3**: `adversary` adds the **Smoke-test sync** dimension. The `agentic-review-degraded-label.yml.template` ships for projects that re-introduce a CI-side LLM review on top of `adversary`. v3 does not bring back the v1 binary.
