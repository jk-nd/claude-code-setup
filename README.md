# claude-code-setup (v2)

> Opinionated template for running a specialised agent team — `architect`, `spec-writer`, `test-author`, `planner`, `plan-reviewer`, `implementer`, `adversary`, `doc-keeper`, `conductor` — against a single GitHub repository. The human (you) makes decisions at the spec / plan / architecture layer; the team handles implementation, internal review, doc maintenance, and merge.

## TL;DR

|  |  |
| --- | --- |
| What you get | 9 subagent definitions, plan-mission template, trust-boundary CI gate, Gemini + Opus plan-review pipeline, weekly docs audit, lean CI defaults |
| What you bring | A language-specific `ci.yml`, team handles, branch-protection settings, a Google AI Studio API key (free) |
| How to start | Click **Use this template** on GitHub (use the `v2` branch), then `scripts/bootstrap.sh` |
| Required keys | `GOOGLE_AI_STUDIO_API_KEY` env var (free tier) for plan second opinions. Claude Code login (Max/Ultra via OAuth) for everything else. No per-PR LLM cost. |
| Where the human is | Approach, spec, plan-mission, compliance-routed PRs. Not on every PR. Not in code review. |

## The operating model in one paragraph

The orchestrator is your Claude Code session running in the project directory. You give it an idea; it dispatches `architect` (one-page approach), then `spec-writer` (testable spec), then `test-author` (red tests from spec) in parallel with `planner` (sequenced plan-mission). The plan is critiqued by Gemini *and* Opus via `plan-reviewer` before you approve it. Once approved, `implementer` instances spawn on git worktrees per task, with `adversary` running pre-PR review (different model class than the implementer) and `doc-keeper` ensuring docs ship with the code. The orchestrator opens and merges PRs when adversary passes and CI is green. Compliance-routed PRs — those touching `WATCHED_PATHS` — still require your label or approval via the trust-boundary gate. A `conductor` subagent produces a morning digest from the plan-mission's living state.

You decide at four points: approach, spec, plan, and compliance-routed PRs. You do **not** review code.

See [`AGENTS.md`](AGENTS.md) for the full operating contract.

## The flow

```
user idea
   │
   ▼
architect ─→ approach doc ─→ USER APPROVES ─→
   │
   ▼
spec-writer ─→ spec ─→ USER APPROVES ─→
   │
   ├─→ test-author ─→ red tests
   └─→ planner ─→ plan-mission ─→ plan-reviewer (Gemini + Opus) ─→ USER APPROVES ─→
                                                                       │
                                                                       ▼
                                                              per-task loop:
                                       ┌───────────────────────────────┘
                                       ▼
                          implementer (on worktree)
                                       │
                                       ▼
                          adversary review
                                  │
                       ┌──────────┴───────────┐
                       ▼ pass                  ▼ fail
                  doc-keeper                  loop back to implementer
                  (same diff)
                       │
                       ▼
                  orchestrator opens PR
                       │
                       ▼
                  CI (async backstop)
                       │
                  ┌────┴───────────────────────┐
                  ▼ non-watched path           ▼ watched path
              orchestrator merges          USER merges via
                                          trust-boundary gate
```

## The team

```
.claude/agents/
  architect.md      idea → approach doc
  spec-writer.md    approach → testable spec
  test-author.md    spec → red tests (implementation-blind)
  planner.md        spec → sequenced plan-mission
  plan-reviewer.md  plan → Gemini + Opus critiques appended
  implementer.md    one task → code + docs + tests green on worktree
  adversary.md      diff → pass / fail / needs-clarification
  doc-keeper.md     diff or repo → doc updates / doc-stale issues
  conductor.md      live state → morning digest
```

Each agent is project-scoped (lives under `.claude/agents/` in the repo). Their tool allowlists are tuned for unattended (overnight) operation: `implementer` and `test-author` can run without permission prompts; `adversary` uses Opus by default for a different-model-class adversarial review of the Sonnet-class `implementer` work.

## How to use

1. Click **Use this template** on GitHub (pick the `v2` branch), or push a fresh clone of `v2` to your new repo's `main`.
2. Clone the new repo locally.
3. Run `scripts/bootstrap.sh`. It will:
   - Detect owner/name from `gh repo view`.
   - Prompt for `WATCHED_PATHS` (defaults include `.github/workflows/`, `go.mod`, `go.sum`, `.github/CODEOWNERS` plus your project-specific compliance paths).
   - Substitute placeholders and rename `*.template` files.
   - Create labels: `compliance-review`, `doc-stale`.
   - Optionally configure branch protection / ruleset on `main`.
4. Edit `.github/CODEOWNERS` to reference real team handles once they exist.
5. Replace the Go-flavoured `.github/workflows/ci.yml` with one for your stack (the bootstrap renames the `.template`; the contents are the placeholder you need to swap).
6. Set `GOOGLE_AI_STUDIO_API_KEY` in your shell env (free key at https://aistudio.google.com).
7. Start the orchestrator: `cd <repo> && claude`.
8. Tell it what to build. Approve at the four gates as work proceeds.

## What's in the box

| Path | Purpose |
| --- | --- |
| `AGENTS.md` | Orchestrator operating contract. Read this first. |
| `.claude/agents/*.md` | The 9 subagent definitions (project-scoped). |
| `templates/claude-settings.json.template` | Curated permissions allowlist. Bootstrap copies to `.claude/settings.json`. |
| `scripts/second-opinion.py` | Calls Gemini (AI Studio free tier) or Opus (via local `claude --print`) for plan critiques. |
| `docs/templates/plan-mission.md` | Living-artifact format `planner` writes from. |
| `.github/workflows/ci.yml.template` | Go-flavoured CI example. Replace with your stack's toolchain. |
| `.github/workflows/trust-boundary.yml` | Compliance gate keyed off watched paths + label / approval. |
| `.github/workflows/docs-audit.yml.template` | (Opt-in) Weekly cron opens a `doc-stale` audit issue for the orchestrator. |
| `.github/workflows/govulncheck.yml.template` | (Opt-in) Weekly Go vulnerability scan. |
| `.github/workflows/nightly.yml.template` | (Opt-in) Slow tests + fuzz. **Only enable if your project has fuzz / slow surfaces.** Default for pilots: leave off. |
| `.github/dependabot.yml.template` | (Opt-in) Weekly dependency bumps. |
| `.github/CODEOWNERS.template` | Skeleton with `${WATCHED_PATHS}` placeholders. |
| `.github/ISSUE_TEMPLATE/` | Six archetypes: epic, sub-issue, hardening, testing, ci, doc-stale. |
| `.github/PULL_REQUEST_TEMPLATE.md` | Summary / test plan / boundaries / closes. |
| `cmd/coverage-gate/` | (Opt-in) Per-package coverage baseline enforcement. |
| `scripts/bootstrap.sh` | Idempotent setup script. |
| `scripts/install-pre-push-hook.sh` | Standalone installer for the strict pre-push hook. |

## What's not

- A migration guide from v1. v2 is for new repos. v1 repos stay on the `main` branch's previous state.
- A language-specific build pipeline. `ci.yml.template` is Go-flavoured as a starting point; swap it for your stack.
- Pre-populated team handles. The bootstrap fills in `${OWNER}`; the `compliance-review` team must be created in your org.
- Branch protection pre-applied. Bootstrap offers to do it.
- An always-on agentic PR review. v1 had one (`cmd/agentic-review/`); empirical audit showed it produced near-zero useful signal. v2 moves review **upstream** into the `adversary` subagent (pre-PR, full orchestrator context, opt-out impossible by design).

## Differences from v1

- **No CI-side agentic review.** `cmd/agentic-review/` and `.github/workflows/agentic-review.yml` removed. Replaced by the `adversary` subagent running pre-PR with full context.
- **Agent team with specialised roles.** v1 had a single "subagent" pattern; v2 ships 9 distinct roles with narrow allowlists and clear hand-offs.
- **Plan-for-plan with two critics.** v2 ships `plan-reviewer` + `second-opinion.py` for Gemini + Opus critiques on every plan.
- **Doc-keeper as a first-class role.** v1 left documentation drift unowned; v2 makes `doc-keeper` run per-merge and weekly.
- **Lean CI by default.** v1's bootstrap heavily promoted agentic-review and slow-test workflows; v2 defaults to `ci.yml` + `trust-boundary.yml` + `govulncheck.yml.template` (opt-in) only.
- **The human checkpoint moves upstream.** v1 said "never merge from an agent" and put the human at every PR. v2 places the human at approach / spec / plan / compliance-routed PRs only. The agent team merges the rest, gated by `adversary` and CI.

If you have v1 repos in flight, leave them on v1. v2 is for new pilots.

## Origin

This template is distilled from operating practice on [`jk-nd/go-mcp-gw`](https://github.com/jk-nd/go-mcp-gw) (v1) and the operating-model refactor of May 2026 that produced v2. The mental model is opinionated: spec-driven, plan-mission-driven, agent-team-driven, human-only-where-the-stakes-justify-it, always-respect-the-trust-boundary.

## License

Apache 2.0. See [`LICENSE`](LICENSE).
