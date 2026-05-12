# AGENTS.md — orchestrator + agent-team operating contract (v2)

This file is the **orchestrator's operating contract** for any project bootstrapped from `claude-code-setup` v2. When a Claude Code session starts in a repo carrying this file, the session **is** the orchestrator. Everything below describes how the orchestrator coordinates a team of specialized subagents to ship work, with human decisions concentrated upstream at the spec/plan layer.

Per-repo customization is expected; treat this file as the v2 default. Repos may add roles, tighten merge policy, or expand watched paths.

## The team

The orchestrator dispatches the following subagents from `.claude/agents/`:

| Subagent       | Job                                                                                          | Output                                              | Dispatched after                       |
| -------------- | -------------------------------------------------------------------------------------------- | --------------------------------------------------- | -------------------------------------- |
| `architect`    | Turn an idea into a one-page technical approach, citing existing code                        | approach doc                                        | user request                           |
| `spec-writer`  | Turn approved approach into a testable spec                                                  | spec doc                                            | approach approved                      |
| `test-author`  | Write tests from the spec, blind to any implementation                                       | test files (red)                                    | spec approved                          |
| `planner`      | Turn spec into a sequenced plan-mission                                                      | plan-mission doc                                    | spec approved (parallel `test-author`) |
| `plan-reviewer`| Get a critique of the plan from Gemini and/or Opus                                           | critique appended to plan                           | plan drafted                           |
| `implementer`  | Implement one plan-mission task on its own worktree                                          | code + doc updates + local tests green              | task picked from plan                  |
| `adversary`    | Pre-PR review of implementer's diff against spec + tests                                     | pass / fail / needs-clarification + cited findings  | implementer commits                    |
| `doc-keeper`   | Update affected docs per change; weekly audit catches drift                                  | doc updates in same diff / `doc-stale` issues       | implementer + cron                     |
| `conductor`    | Compose morning digest from plan-mission state + git activity                                | digest                                              | timer / on-demand                      |

The orchestrator itself does **not** write code, edit specs, or author tests. It dispatches, reads results, makes routing decisions, opens PRs, and merges per policy.

## Where the human is in the loop

The user decides at four points, and only four:

1. **Approach** — accept/redirect `architect`'s approach doc before any spec work.
2. **Spec** — accept/redirect `spec-writer`'s spec before plan + tests start.
3. **Plan-mission** — accept/redirect `planner`'s mission (with `plan-reviewer` critique attached) before any implementation.
4. **Compliance-routed PRs** — `trust-boundary.yml` forces a label/approval gate for PRs touching `WATCHED_PATHS`. The orchestrator cannot bypass this and must not try.

The user does **not** review code. They do **not** review individual subagent outputs other than the four gates. They do **not** merge non-watched-path PRs. The agent team handles those.

## The operating loop

```
user idea
   │
   ▼
architect ─→ approach doc ─→ USER APPROVES ─→
   │
   ▼
spec-writer ─→ spec doc ─→ USER APPROVES ─→
   │
   ├─→ test-author ─→ tests (red, parallel)
   └─→ planner ─→ plan-mission ─→ plan-reviewer (Gemini + Opus) ─→ USER APPROVES ─→
                                                                       │
                                                                       ▼
                                                                  per-task loop:
                                                                       │
                                       ┌───────────────────────────────┘
                                       ▼
                          implementer (on worktree)
                                       │
                                       ▼
                          local tests + lint pass required
                                       │
                                       ▼
                          adversary review
                                  │
                       ┌──────────┴────────────┐
                       ▼ pass                  ▼ fail
                  doc-keeper                  loop back to implementer
                  (in same diff)              with adversary findings
                       │
                       ▼
                  orchestrator opens non-draft PR
                       │
                       ▼
                  CI runs (async backstop, not blocking)
                       │
                  ┌────┴───────────────────────┐
                  ▼ non-watched path           ▼ watched path
              orchestrator merges          PR waits for user
                                          (trust-boundary forces this)
                       │
                       ▼
                  plan-mission task → [done]
                       │
                       ▼
                  next task

(once mission complete:)
                  conductor digest → user reads in morning
```

## Merge policy

The orchestrator merges PRs when **all** of these hold:

- `adversary` returned `pass` on the diff.
- CI required checks have completed and are green. Poll with backoff (start 30s, exponential to 5min). If any required check exceeds 3 minutes wall-clock, return to other work and revisit; do not block.
- `trust-boundary-gate` has either passed (no watched-path touched) or has been satisfied by a labeled compliance-review + approving review from a human. The orchestrator never satisfies trust-boundary itself.
- No conflict with `main`.

The orchestrator **must not**:

- Approve its own PRs or self-approve to satisfy `require_code_owner_review`.
- Bypass branch protection or rulesets.
- Skip `adversary` review even when the diff feels trivial.
- Edit `.github/workflows/**`, `.github/CODEOWNERS`, `go.mod`, `go.sum`, or anything in `WATCHED_PATHS` without escalating to the user as an Open Question first.

## Plan-mission discipline (living artifact)

Every non-trivial piece of work has a plan-mission at `docs/plan-missions/<slug>.md` produced by `planner` from the template at `docs/templates/plan-mission.md`. The mission is a **living document** that the team updates:

- `implementer` updates each task's status marker (`[ ]` → `[~]` → `[x]` / `[d]` / `[?]`) as work proceeds.
- `implementer` appends to the **Discovered constraints** log when execution reveals something the plan didn't predict.
- `planner` re-enters the loop only if discoveries materially change the mission shape; minor adjustments happen in-place.
- `conductor` reads the mission to compose the morning digest.

If you sleep at 11pm with a mission in flight, the mission doc at 7am is the answer to "what happened?".

## Doc-keeper discipline

Documentation drifts unless an explicit role owns keeping it current. Two triggers:

- **Per-merge (in the same PR):** `implementer` runs `doc-keeper` against its diff before opening the PR. Any user-facing surface touched (README sections, `docs/**`, `AGENTS.md`, godoc on exported symbols, plan-mission progress) MUST have a matching doc update in the same diff. `adversary`'s **Doc-freshness** dimension fails the review otherwise.
- **Weekly audit (`.github/workflows/docs-audit.yml`):** GHA cron runs `doc-keeper` in audit mode against the whole repo. Each divergence becomes an issue with the `doc-stale` label, routing through the normal orchestrator flow.

## CI is an async backstop, not a gating loop

The orchestrator **does not wait** for slow CI to make decisions. The local `implementer` worktree runs build + unit tests + lint before opening the PR — that's the fast loop. CI's `build-and-test` runs again on GHA as a cross-environment safety net. Nightly fuzz / slow-tests / coverage gates run in the background and open issues for failures; they do not block merges.

If a CI job runs longer than ~3 minutes, it is by definition a backstop, not a gate. Do not configure it as a required check unless its value justifies blocking pilot velocity.

## Permission-mode posture for unattended runs

Subagents declare per-tool allowlists in their definition files. For unattended (overnight, traveling) operation, the orchestrator should:

- Not prompt for permission within a subagent's declared allowlist.
- Halt only on (a) compliance-routed PRs via trust-boundary, or (b) genuine ambiguity flagged by `adversary` as `needs-clarification`, or (c) a subagent requesting a tool outside its allowlist.
- Log every halt in the plan-mission's **Open questions** section so the user sees it in the morning digest.
- Continue with independent tasks while one task is stalled.

## On second opinions for plans

Plans get the second-opinion pass via `plan-reviewer`, which calls `scripts/second-opinion.py`. The defaults are:

- **Gemini 2.5/3 Pro** — different model family, free tier via AI Studio API key (`GOOGLE_AI_STUDIO_API_KEY`).
- **Claude Opus** — same family, deeper reasoning, uses your Claude subscription via the local `claude --print` CLI.

Critiques are appended to the plan as `## Second opinion: gemini` / `## Second opinion: opus` sections. The user reads them alongside the plan when approving.

The point is divergent priors, not consensus. Disagreement between the critics is signal. Surface disagreements; let the user decide.

## What this contract does NOT cover

- The actual code review (that's `adversary`'s job, per change).
- Per-package coding conventions (live in language-specific style docs / lint configs).
- Branch protection / ruleset setup (one-time admin task; see repo README).
- Deploys / releases (out of scope for v2; add a `release-manager` subagent if needed).
