# Agentic review — v3

v3's code-review path is the `adversary` subagent (pre-PR, full orchestrator context, opt-out impossible by design — see `.claude/agents/adversary.md`).

This supersedes v1's CI-side `cmd/agentic-review/` workflow, which the v2 audit showed produced near-zero useful signal because it ran post-PR with truncated context. v2 removed the binary + workflow entirely; v3 keeps it out. There is **no opt-in path** in v3 to bring back the CI-side review — the v2 decision stands.

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

## What changed from v1 / v2

- **v1**: `cmd/agentic-review/` CI workflow, opt-out via env var, near-zero useful signal in practice. Audited and disabled mid-2026.
- **v2**: `adversary` subagent replaces v1; six review dimensions; pre-PR with full orchestrator context; OAuth-based, no API key secret needed. CI-side path removed entirely.
- **v3**: `adversary` adds the **Smoke-test sync** dimension. v3 does NOT bring back the v1 CI-side path — the v2 decision stands. If a project insists on a CI-side LLM review on top of `adversary`, that's a project-local concern and lives outside this template.
