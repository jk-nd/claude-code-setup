# claude-code-setup (v3)

> Opinionated template for running a specialised agent team — `architect`, `spec-writer`, `test-author`, `planner`, `plan-reviewer`, `implementer`, `adversary`, `doc-keeper`, `conductor` — against a single GitHub repository. The human (you) makes decisions at the spec / plan / architecture layer; the team handles implementation, internal review, doc maintenance, and merge.

## TL;DR

|  |  |
| --- | --- |
| What you get | 9 subagent definitions, plan-mission template, trust-boundary CI gate, Gemini + Opus plan-review pipeline, weekly docs audit, lean CI defaults, merge-queue triggers, dependabot auto-merge + rebase-stale + main-broken sentinel templates, smoke-test playbook starter, agent-team calibration log, three-band coverage gate, ceremony-level switch |

| What you bring | A language-specific `ci.yml`, team handles, branch-protection / Rulesets settings, a Google AI Studio API key (free) |
| How to start | Click **Use this template** on GitHub (use the `v3` branch when published), then `scripts/bootstrap.sh` |
| Required keys | `GOOGLE_AI_STUDIO_API_KEY` env var (free tier) for plan second opinions. Claude Code login (Max/Ultra via OAuth) for everything else. No per-PR LLM cost. No `ANTHROPIC_API_KEY` (v3 does NOT bring back the v1 CI-side review). |
| Where the human is | Architectural-shape gates (approach / spec / plan-mission / compliance-routed PRs) — not every individual decision the architect surfaces, not on every PR, not in code review. |

## The operating model in one paragraph

The orchestrator is your Claude Code session running in the project directory. You give it an idea; it dispatches `architect` (one-page approach), then `spec-writer` (testable spec), then `test-author` (red tests from spec) in parallel with `planner` (sequenced plan-mission). The plan is critiqued by Gemini *and* Opus via `plan-reviewer` before you approve it. Once approved, `implementer` instances spawn on git worktrees per task (every edit-making subagent runs on a worktree in v3), with `adversary` running pre-PR review (different model class than the implementer) and `doc-keeper` ensuring docs ship with the code. The orchestrator opens and merges PRs when adversary passes and CI is green. Compliance-routed PRs — those touching `WATCHED_PATHS` — still require your label or approval via the trust-boundary gate. A `conductor` subagent produces a morning digest from the plan-mission's living state.

You decide at four points: approach, spec, plan, and compliance-routed PRs. You do **not** review code. The architect applies a [decide-vs-ask threshold](AGENTS.md#9-decide-rather-than-ask-on-mechanical-questions) and surfaces only load-bearing questions; mechanical-operational decisions get recorded with a "push back if wrong" note rather than gated on confirmation.

> Issues are the protocol between repos; PRs are the protocol within a repo; plan-mission docs are the protocol within a mission.

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
                  CI (async backstop) + merge queue (if enabled)
                       │
                  ┌────┴───────────────────────┐
                  ▼ non-watched path           ▼ watched path
              orchestrator merges          USER merges via
                                          trust-boundary gate
```

Multiple missions run their loops in parallel when they don't share watched paths or contended files. The orchestrator dispatches every non-user-blocking next step opportunistically — see [AGENTS.md operating clarifications #5 and #10](AGENTS.md#5-parallel-tracks-are-allowed).

## The team

```
.claude/agents/
  architect.md      idea → approach doc  (worktree)
  spec-writer.md    approach → testable spec  (worktree)
  test-author.md    spec → red tests (implementation-blind)  (worktree)
  planner.md        spec → sequenced plan-mission  (worktree)
  plan-reviewer.md  plan → Gemini + Opus critiques appended  (worktree)
  implementer.md    one task → code + docs + tests green  (worktree)
  adversary.md      diff → pass / fail / needs-clarification  (main tree, read-only)
  doc-keeper.md     diff or repo → doc updates / doc-stale issues  (worktree)
  conductor.md      live state → morning digest  (main tree, read-only)
```

Each agent is project-scoped (lives under `.claude/agents/` in the repo). Their tool allowlists are tuned for unattended (overnight) operation: `implementer` and `test-author` can run without permission prompts; `adversary` uses Opus by default for a different-model-class adversarial review of the Sonnet-class `implementer` work.

**v3 default: every edit-making subagent runs on its own git worktree.** This supersedes the v2 doctrine that only `implementer` ran on a worktree; the parallelism principle (multiple missions concurrent) makes isolation the safe default for upstream agents too.

## How to use

1. Click **Use this template** on GitHub (pick the `v3` branch once published), or push a fresh clone of `v3` to your new repo's `main`.
2. Clone the new repo locally.
3. Run `scripts/bootstrap.sh`. It will:
   - Detect owner/name from `gh repo view`.
   - Prompt for `WATCHED_PATHS` (defaults include `.github/workflows/`, `go.mod`, `go.sum`, `.github/CODEOWNERS` plus your project-specific compliance paths).
   - Prompt for `ceremony_level` (`foundation` / `demo` / `iterate-fast`).
   - Substitute placeholders and rename `*.template` files.
   - Create labels: `compliance-review`, `doc-stale`, `coverage-skip`, `automerge`, `dependabot:major-review-needed`, `main-broken`, `dependencies`.
   - Optionally configure branch protection / Rulesets on `main`.
   - Optionally enable GitHub merge queue on `main`.
4. Edit `.github/CODEOWNERS` to reference real team handles once they exist.
5. Replace the Go-flavoured `.github/workflows/ci.yml` with one for your stack (the bootstrap renames the `.template`; the contents are the placeholder you need to swap).
6. Set `GOOGLE_AI_STUDIO_API_KEY` in your shell env (free key at https://aistudio.google.com).
7. Start the orchestrator: `cd <repo> && claude`.
8. Tell it what to build. Approve at the four gates as work proceeds.

See [`docs/setup.md`](docs/setup.md) for the full operator reference and [`docs/operating.md`](docs/operating.md) for day-to-day recipes.

## What's in the box

| Path | Purpose |
| --- | --- |
| `AGENTS.md` | Orchestrator operating contract (v3). Read this first. |
| `.claude/agents/*.md` | The 9 subagent definitions (project-scoped). |
| `templates/claude-settings.json.template` | Curated permissions allowlist with v3 Bash auto-allowlist (git, go, make, second-opinion.py). Bootstrap copies to `.claude/settings.json`. |
| `templates/smoke-test-playbook.md.template` | (Opt-in) Starter shape for a versioned UI smoke-test manual. |
| `scripts/second-opinion.py` | Calls Gemini (AI Studio free tier) or Opus (via local `claude --print`) for plan critiques. |
| `scripts/install-pre-push-hook.sh` | Standalone installer for the strict pre-push hook. |
| `docs/templates/plan-mission.md` | Living-artifact format `planner` writes from. |
| `docs/research/agent-team-calibration.md` | Orchestrator's drift log; entries propagate as v3+ amendment candidates. |
| `docs/setup.md` | Operator's reference for everything bootstrap configures + manual steps. |
| `docs/operating.md` | Day-to-day operating recipes (merge-cascade, parallel tracks, recovery patterns). |
| `docs/agentic-review.md` | `adversary` review dimensions + opt-in CI-side LLM review notes. |
| `.github/workflows/ci.yml.template` | Go-flavoured CI example with paths-filter, actionlint gate, merge-queue trigger. Replace per-language. |
| `.github/workflows/trust-boundary.yml` | Compliance gate keyed off watched paths + label / approval, with merge-queue trigger. |
| `.github/workflows/docs-audit.yml.template` | (Opt-in) Weekly cron opens a `doc-stale` audit issue for the orchestrator. |
| `.github/workflows/govulncheck.yml.template` | (Opt-in) Weekly Go vulnerability scan. |
| `.github/workflows/nightly.yml.template` | (Opt-in) Slow tests + fuzz. **Only enable if your project has fuzz / slow surfaces.** Default for pilots: leave off. |
| `.github/workflows/dependabot-automerge.yml.template` | (Opt-in) Patch/minor auto-merge; major routed to human review. |
| `.github/workflows/dependabot-rebase-stale.yml.template` | (Opt-in) Nightly cron to `@dependabot rebase` conflicting PRs. |
| `.github/workflows/main-broken-sentinel.yml.template` | (Opt-in) Post-merge build sentinel; files `main-broken` issue on failure. |
| `.github/dependabot.yml.template` | (Opt-in) Weekly dependency bumps. |
| `.github/CODEOWNERS.template` | Skeleton with `${WATCHED_PATHS}` placeholders. |
| `.github/ISSUE_TEMPLATE/` | Six archetypes: epic, sub-issue, hardening, testing, ci, doc-stale. |
| `.github/PULL_REQUEST_TEMPLATE.md` | Summary / test plan / boundaries / closes. |
| `cmd/coverage-gate/` | (Opt-in) Three-band coverage baseline enforcement (PASS / WARN / FAIL). |
| `scripts/bootstrap.sh` | Idempotent setup script. |

## What's not

- A migration guide from v1 or v2. v3 is for new repos and for v2 repos willing to re-bootstrap.
- A language-specific build pipeline. `ci.yml.template` is Go-flavoured as a starting point; swap it for your stack.
- Pre-populated team handles. The bootstrap fills in `${OWNER}`; the `compliance-review` team must be created in your org.
- Branch protection pre-applied. Bootstrap offers to do it.
- Repository Rulesets pre-applied. The maintainer-identity allowlist for branch protection requires the GitHub UI; bootstrap saves the allowlist as a documentation reference and prints the next steps.
- An always-on CI-side agentic PR review. v1 had one (`cmd/agentic-review/`); empirical audit showed near-zero useful signal. v2 + v3 move review **upstream** into the `adversary` subagent (pre-PR, full orchestrator context, opt-out impossible by design).

## Differences from v2

v3 folds in operating-model recalibrations from running v2 on `jk-nd/noah-2` (Agentic Microkernel rebuild) and `jk-nd/go-mcp-gw` (parallel-agent operating-days). Detailed in [`AGENTS.md § Operating clarifications (v3)`](AGENTS.md#operating-clarifications-v3).

- **Decision discipline.** Architect applies an explicit decide-vs-ask threshold (target ratio 3:1 decide:ask on established approach docs); records mechanical decisions in a new `## Decisions made by architect (push back if wrong)` section. One question at a time, AskUserQuestion-style — no walls of text. Decisions-walk-on-revision when a previously-closed gate re-opens.
- **Ceremony calibration.** New `ceremony_level: foundation | demo | iterate-fast` field at the top of `AGENTS.md`. Bootstrap prompts. Agents consult the field.
- **Parallelism + isolation triple.** Parallel tracks are sanctioned; opportunistic dispatch is required; worktree default for every edit-making subagent. The v2 doctrine that upstream agents work in the main tree is superseded.
- **Dispatch over self.** Default to subagent dispatch; orchestrator direct work limited to PR open/merge, task-list state, and single-line calibration-log entries. Doc work routes to `doc-keeper`, not `architect`, unless the change is an architectural-shape supersession.
- **Feasibility check between architect and spec-writer.** Architect runs a stub-compile / stub-build pass for approaches that name specific imports / types / build-tooling, records the outcome in `## Risks`.
- **Bash auto-allowlist** for subagent operations (git status/diff/add/commit, go build/test/vet, make, second-opinion.py). Prevents the silent failure mode where Bash denial bounced work back to the orchestrator.
- **Worktree cleanup respects uncommitted changes.** The orchestrator preserves worktrees with uncommitted edits; subagents surface Bash denials in their return value rather than silently exiting.
- **Ticket-size norm** (~50–200 LoC per task) + aggressive implementer fan-out on dependency satisfaction.
- **PR ceremony for every change.** Direct-to-`main` is reserved for a tightly bounded allow-list (bootstrap, plan-mission status markers, single-line calibration-log entries). Everything else flows through `doc-keeper` + worktree + PR.
- **Smoke-test playbook contract** — `adversary` adds a Smoke-test sync dimension; bootstrap offers a starter playbook.
- **Calibration log** — `docs/research/agent-team-calibration.md` ships as a stub; orchestrator appends drift entries; recurring patterns surface upstream.
- **Autonomy-gap closures.** `merge_group:` triggers on CI workflows; dependabot auto-merge + rebase-stale templates; main-broken sentinel; bootstrap prompts for branch protection + maintainer-identity allowlist + merge queue.
- **Three-band coverage gate.** PASS / WARN (within 0.3 of threshold) / FAIL. Avoids the v2 friction where every defensive-coverage addition forced a follow-up baseline PR.

## Differences from v1 (carried from v2)

- **No CI-side agentic review.** `cmd/agentic-review/` and `.github/workflows/agentic-review.yml` removed. Replaced by the `adversary` subagent running pre-PR with full context.
- **Agent team with specialised roles.** v1 had a single "subagent" pattern; v2/v3 ship 9 distinct roles with narrow allowlists and clear hand-offs.
- **Plan-for-plan with two critics.** Gemini + Opus critiques on every plan.
- **Doc-keeper as a first-class role.**
- **Lean CI by default.**
- **The human checkpoint moves upstream.** v1 said "never merge from an agent" and put the human at every PR. v2/v3 place the human at approach / spec / plan / compliance-routed PRs only — and at *architectural-shape gates* within those, not at every individual decision.

If you have v1 repos in flight, leave them on v1. v2 repos can re-bootstrap from v3, or stay where they are. v3 is recommended for new pilots.

## Origin

This template is distilled from operating practice on [`jk-nd/go-mcp-gw`](https://github.com/jk-nd/go-mcp-gw) (v1) and the operating-model refactor of May 2026 that produced v2, then the recalibrations from running v2 on [`jk-nd/noah-2`](https://github.com/jk-nd/noah-2) (Agentic Microkernel rebuild) and continued go-mcp-gw parallel-agent operating-days that produced v3. The mental model is opinionated: spec-driven, plan-mission-driven, agent-team-driven, parallel where safe, human-only-at-architectural-shape-gates, always-respect-the-trust-boundary.

## License

Apache 2.0. See [`LICENSE`](LICENSE).
