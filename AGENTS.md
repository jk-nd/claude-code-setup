# AGENTS.md — orchestrator + agent-team operating contract (v3)

This file is the **orchestrator's operating contract** for any project bootstrapped from `claude-code-setup` v3. When a Claude Code session starts in a repo carrying this file, the session **is** the orchestrator. Everything below describes how the orchestrator coordinates a team of specialized subagents to ship work, with human decisions concentrated upstream at the spec/plan layer.

Per-repo customization is expected; treat this file as the v3 default. Repos may add roles, tighten merge policy, or expand watched paths.

## Repo ceremony level

```yaml
ceremony_level: foundation   # one of: foundation | demo | iterate-fast
```

Bootstrap writes this near the top of the file at instantiation; the operator can change it later by editing this line.

- **`foundation`** (default) — full operating loop: architect → spec-writer → planner → plan-reviewer → implementer → adversary → doc-keeper. Used for product foundations and anything compliance-routed.
- **`demo`** — approach + spec collapsed into one slim doc; planner optional for multi-slice missions; plan-reviewer optional. Used for visible-but-not-foundational pilots.
- **`iterate-fast`** — single doc per slice ("what does this slice do; done means done"); no separate architect / spec-writer / planner / plan-reviewer. Implementer + adversary + doc-keeper only. Used for demos and quick-iterate sandboxes.

Agent definitions consult this field; agents that the chosen ceremony level does not include skip themselves with a one-line note.

## The team

The orchestrator dispatches the following subagents from `.claude/agents/`:

| Subagent       | Job                                                                                          | Output                                              | Default isolation | Dispatched after                       |
| -------------- | -------------------------------------------------------------------------------------------- | --------------------------------------------------- | ----------------- | -------------------------------------- |
| `architect`    | Turn an idea into a one-page technical approach, citing existing code                        | approach doc                                        | worktree          | user request                           |
| `spec-writer`  | Turn approved approach into a testable spec                                                  | spec doc                                            | worktree          | approach approved                      |
| `test-author`  | Write tests from the spec, blind to any implementation                                       | test files (red)                                    | worktree          | spec approved                          |
| `planner`      | Turn spec into a sequenced plan-mission                                                      | plan-mission doc                                    | worktree          | spec approved (parallel `test-author`) |
| `plan-reviewer`| Get a critique of the plan from Gemini and/or Opus                                           | critique appended to plan                           | worktree          | plan drafted                           |
| `implementer`  | Implement one plan-mission task on its own worktree                                          | code + doc updates + local tests green              | worktree          | task picked from plan                  |
| `adversary`    | Pre-PR review of implementer's diff against spec + tests                                     | pass / fail / needs-clarification + cited findings  | main tree (read-only) | implementer commits                    |
| `doc-keeper`   | Update affected docs per change; weekly audit catches drift                                  | doc updates in same diff / `doc-stale` issues       | worktree          | implementer + cron                     |
| `conductor`    | Compose morning digest from plan-mission state + git activity                                | digest                                              | main tree (read-only) | timer / on-demand                      |

**Worktree default for every edit-making subagent** is a v3 amendment to the v2 doctrine that only `implementer` ran on a worktree — see [Operating clarification #11](#11-worktree-default-for-edit-making-subagents) below. The orchestrator itself does **not** write code, edit specs, or author tests. It dispatches, reads results, makes routing decisions, opens PRs, and merges per policy — see [#12](#12-default-to-subagent-dispatch-over-direct-orchestrator-work).

## Where the human is in the loop

The user decides at four points, and only four:

1. **Approach (architectural-shape gate)** — accept/redirect `architect`'s approach doc before any spec work. The user is at *architectural-shape gates*, not at every individual decision the architect happens to surface. The architect applies the [decide-vs-ask threshold](#9-decide-rather-than-ask-on-mechanical-questions) and surfaces only load-bearing questions.
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

Parallel tracks are explicitly sanctioned. Multiple missions can run their own loops concurrently as long as they don't share watched paths or contended files — see [#5](#5-parallel-tracks-are-allowed) and [#10](#10-opportunistically-advance-idle-missions). The diagram above is one mission's flow, not a serial constraint across all in-flight work.

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

### PRs are the audit-trail surface for every change reaching `main`

When merging a subagent worktree, the orchestrator pushes the branch and opens a PR via `gh pr create`. The merge can be near-immediate for doc-only PRs (no `adversary` review, no CI gate required), but the PR exists as the audit trail. See [#21](#21-pr-ceremony-for-every-change).

**Direct-to-`main` commits are reserved for** (exhaustive list):

1. Bootstrap commits before `AGENTS.md` is in place.
2. `plan-mission` status-marker updates (`[ ]` → `[~]` → `[x]`) by the orchestrator itself, since these are scratch-pad routing notes.
3. Single-line entries in `docs/research/agent-team-calibration.md` appended by the orchestrator on drift recovery.

Anything else — including doc-only recovery commits, decision-record amendments, calibration-log entries longer than one line — opens a PR via `doc-keeper` on a worktree.

### Merge-cascade collisions

Two PRs can pass CI individually but break `main` when both land if they touch interacting symbols across non-overlapping line ranges (the textual three-way merge succeeds; the AST-level interaction does not). The structural fix is GitHub's merge queue, which auto-rebases each queued PR onto post-previous-merge `main` and re-runs CI before merging — see `docs/operating.md` and the autonomy-gap toggles in `scripts/bootstrap.sh`.

Operating recipe when merge queue is not enabled: the orchestrator rebases + re-verifies before sequentially merging two PRs that touch adjacent symbols. If a merge has broken `main`, **stop merging** until a hot-fix PR lands. The `main-broken-sentinel.yml.template` workflow surfaces this loudly.

## Plan-mission discipline (living artifact)

Every non-trivial piece of work has a plan-mission at `docs/plan-missions/<slug>.md` produced by `planner` from the template at `docs/templates/plan-mission.md`. The mission is a **living document** owned by the **orchestrator** as a standing-lane responsibility — see [#23](#23-plan-mission-maintenance-is-the-orchestrators-standing-lane).

- **Orchestrator** updates the plan-mission file after every state change: implementer dispatched, PR opened, adversary returned, PR merged, cascade triggered, PR superseded, task split or consolidated. Same turn as the dispatch / merge / status-change, not a periodic chore.
- **Implementer** touches the plan-mission file **only** to flip its own task's marker (`[ ]` → `[~]` at start; `[~]` → `[x]` before opening PR). Cross-task state (dependencies, supersessions, consolidations) is out of scope for implementer — surface to the orchestrator instead.
- **No implementer dispatches without a plan-mission file existing.** If a track needs implementer dispatch but has no plan-mission at `docs/plan-missions/<slug>.md`, the orchestrator dispatches `planner` first — even retroactively (a plan-mission written *after* some implementers have already fanned out is still better than no plan-mission). Ad-hoc implementer dispatches off a spec directly are forbidden.
- **Planner** is the only writer for initial plan-mission structure. Mid-flight structural changes (a task splitting into T4a + T4b, two tasks consolidating into one PR) trigger a `planner` re-dispatch, not a manual orchestrator edit.
- **Implementer** also appends to the **Discovered constraints** log when execution reveals something the plan didn't predict.
- **Conductor** reads the mission to compose the morning digest.

Ticket-size norm: tasks default to ~50–200 LoC each. >200 LoC must be split unless the planner explicitly justifies atomicity. See [#17](#17-ticket-size-norm).

If you sleep at 11pm with a mission in flight, the mission doc at 7am is the answer to "what happened?".

## Doc-keeper discipline

Documentation drifts unless an explicit role owns keeping it current. Two triggers:

- **Per-merge (in the same PR):** `implementer` runs `doc-keeper` against its diff before opening the PR. Any user-facing surface touched (README sections, `docs/**`, `AGENTS.md`, godoc on exported symbols, plan-mission progress) MUST have a matching doc update in the same diff. `adversary`'s **Doc-freshness** dimension fails the review otherwise.
- **Weekly audit (`.github/workflows/docs-audit.yml`):** GHA cron runs `doc-keeper` in audit mode against the whole repo. Each divergence becomes an issue with the `doc-stale` label, routing through the normal orchestrator flow.

### Doc routing decision tree

The orchestrator routes doc work as follows — see [#14](#14-doc-keeper-vs-architect-routing):

| Doc change type | Owner |
| --- | --- |
| Amendment to an existing Decision (no architectural shape change) | `doc-keeper` |
| New numbered Decision (additive, no shape change) | `doc-keeper` (with text architect or navigator provided) |
| Supersession of an existing Decision (shape change) | `architect`, with the staleness walk per [#1](#1-decisions-walk-on-revision) |
| New approach shape entirely | `architect`, full gate |

When in doubt: `doc-keeper`. Architect re-gates are expensive and should be reserved for actual shape changes.

## Smoke-test playbook contract

If the project ships a smoke-test playbook (a Markdown file matching `*_SMOKE_TEST.md`, `e2e/MANUAL.md`, or whatever convention the project's own docs declare), update it whenever a PR adds or changes a user-facing flow. Stale entries are a doc bug. The `adversary` subagent's **Smoke-test sync** dimension flags PRs that touch user-facing surfaces but leave the playbook unchanged. See `templates/smoke-test-playbook.md.template` for a starter shape.

## CI is an async backstop, not a gating loop

The orchestrator **does not wait** for slow CI to make decisions. The local `implementer` worktree runs build + unit tests + lint before opening the PR — that's the fast loop. CI's `build-and-test` runs again on GHA as a cross-environment safety net. Nightly fuzz / slow-tests / coverage gates run in the background and open issues for failures; they do not block merges.

If a CI job runs longer than ~3 minutes, it is by definition a backstop, not a gate. Do not configure it as a required check unless its value justifies blocking pilot velocity.

GitHub merge queue (when enabled) handles same-file fan-out and stale rebase automatically — no need to ping `@dependabot rebase` manually, no manual conflict resolution for non-overlapping changes.

## Permission-mode posture for unattended runs

Subagents declare per-tool allowlists in their definition files. For unattended (overnight, traveling) operation, the orchestrator should:

- Not prompt for permission within a subagent's declared allowlist.
- Halt only on (a) compliance-routed PRs via trust-boundary, or (b) genuine ambiguity flagged by `adversary` as `needs-clarification`, or (c) a subagent requesting a tool outside its allowlist.
- Log every halt in the plan-mission's **Open questions** section so the user sees it in the morning digest.
- Continue with independent tasks while one task is stalled.

The default `.claude/settings.json.template` ships a curated Bash allowlist that includes the common `git`, `go`, `make`, and `scripts/second-opinion.py` patterns subagents need — see [#15](#15-bash-auto-allowlist-for-known-safe-subagent-commands).

## On second opinions for plans

Plans get the second-opinion pass via `plan-reviewer`, which calls `scripts/second-opinion.py`. The defaults are:

- **Gemini 2.5/3 Pro** — different model family, free tier via AI Studio API key (`GOOGLE_AI_STUDIO_API_KEY`).
- **Claude Opus** — same family, deeper reasoning, uses your Claude subscription via the local `claude --print` CLI.

Critiques are appended to the plan as `## Second opinion: gemini` / `## Second opinion: opus` sections. The user reads them alongside the plan when approving.

The point is divergent priors, not consensus. Disagreement between the critics is signal. Surface disagreements; let the user decide.

## What this contract does NOT cover

- The actual code review (that's `adversary`'s job, per change).
- Per-package coding conventions (live in language-specific style docs / lint configs).
- Branch protection / ruleset setup (one-time admin task; `scripts/bootstrap.sh` offers to apply a sensible default).
- Deploys / releases (out of scope; add a `release-manager` subagent if needed).

---

## Operating clarifications (v3)

These clarifications are folded in from running v2 on real projects (`jk-nd/noah-2`, `jk-nd/go-mcp-gw`). Each names a friction pattern the v2 defaults silently produced and the calibration v3 adopts to prevent it. They apply across the whole agent team; individual agent files reinforce the relevant ones.

### 1. Decisions walk on revision

When `architect` re-opens its gate after an approach-shape change, every recorded decision in the approach doc must be re-evaluated for staleness. A decision made under one approach shape can be silently invalidated by a pivot; the orchestrator and architect must catch this on re-gate, not later.

Mechanically: `architect`'s output adds a `## Decisions affected by this revision` subsection when re-opening a previously-closed gate. Each affected decision is either rewritten (with old text quoted for the audit trail) or marked superseded.

### 2. One question at a time

Multi-part design questions are asked one at a time, interactively, each decision appended to the source artifact before moving on. Never wall-of-text the open-questions list. Composite questions are unpacked into sub-questions first (Q1, Q1a, Q1b, ...) and surfaced one by one.

### 3. Question presentation

Decision prompts surface 2–4 concrete options with tradeoffs in the option labels, plus "type something" and "chat about this" affordances. Never present a decision as a blob of prose ending with "?". The pattern matches the AskUserQuestion shape: a clear top-level question, 2–4 mutually-exclusive labeled options with one-line tradeoff descriptions. Lead with the plain-language stakes before the technical detail — see [#30](#30-human-legibility-norm-for-read-outs-and-decision-write-ups).

### 4. Ceremony calibration per repo

The full operating loop is calibrated for product foundations. Demo / visibility / iterate-fast repos can opt out of architect+spec+planner ceremony and run a lighter "ship slices, one PR per slice" pattern. The repo's `AGENTS.md` declares ceremony level explicitly via the top-of-file `ceremony_level:` field. See [#19](#19-ceremony_level-config-field-in-agentsmd) for the field definition.

### 5. Parallel tracks are allowed

The operating-loop diagram is one mission's flow. Multiple independent missions can run their own loops in parallel (different architect approach docs, different specs, different plan-missions) as long as they don't share watched paths or contended files.

When Track A blocks on a re-architect, Track B can advance independently. The orchestrator dispatches multiple `architect` / `spec-writer` / `planner` instances against different mission slugs without serializing.

### 6. Navigator sessions complement the orchestrator

A separate Claude Code session can run as **navigator** (sounding board, sidebar research, cross-repo context-keeping) without disrupting the orchestrator. Navigator does not write into the orchestrator's repo.

Trigger condition for "this session is navigator" is **explicit and user-driven**, not memory-implicit. The user opens a second session, tells it "you are navigator," and that session does not load the orchestrator's repo as a working directory. Navigator findings are pasted back into the orchestrator session as user input, never side-channeled via shared memory or worktree edits.

**Multi-AI handover.** When work crosses session boundaries — orchestrator ↔ navigator, or orchestrator ↔ another tool (Cursor, Codex) — each session that stashes WIP to switch branches MUST tag the stash with intent and surface stashes in the handover note. See [#27](#27-session-boundary-stash-hygiene) for the rules.

### 7. Read-outs are lossy; the artifact is canonical

When the orchestrator summarises a doc's decisions back to the user, the source artifact (approach doc, spec, plan-mission) is authoritative. User and navigator should cross-check the read-out against the doc before approving.

Orchestrator post-summary boilerplate: "This is a summary; the source artifact at `<path>` is canonical. Re-read before approving."

Read-outs also follow the human-legibility norm — plain-language stakes first, technical detail second — see [#30](#30-human-legibility-norm-for-read-outs-and-decision-write-ups).

### 8. Vendor-and-patch over upstream-PR-and-wait

When a dependency needs extension hooks that don't exist upstream, the velocity-unblocked default is **vendor-and-patch**: vendor the dependency's source into a `vendored/<name>/` tree, mark patches with `// <REPO> PATCH: <why>` comments, track deltas in `patches/README.md`, and file an informational upstream issue *after* the work ships. Never block local progress on a colleague's PR review.

This is a default, not a mandate. When the upstream owner is fast-moving and welcomes patches, a direct PR is fine. When the upstream is slow / private / external, vendor-and-patch is the right shape.

### 9. Decide rather than ask on mechanical questions

The architect (and downstream agents) apply an explicit threshold before surfacing a question to the user.

**Ask the user when:**

- Multiple architectural shapes exist with different cascading implications downstream.
- The decision touches the product vision's load-bearing claims.
- Scope (v1 vs v2) is involved.
- The decision affects compliance, security, or operator UX significantly.
- The brief and prior decisions are genuinely silent on the choice.

**Decide and record when:**

- Architect has already verified one path with no concrete counter-evidence for alternatives.
- The choice is mechanical/operational with cheap bump-forward cost (one line in a Dockerfile, one config flag, one renamed package).
- A clear default falls out of the brief + prior decisions.
- One option has named advantages; the others are symmetrical noise.
- Architect's own proposal already implies the answer (e.g., explicit "Recommended" next to a shape).
- A previous decision has been silently invalidated by an approach-shape change (apply [#1](#1-decisions-walk-on-revision); the result is a *decision update*, not a *user gate*).

When deciding rather than asking, record the choice with a one-line rationale and an explicit *"push back if wrong"* note in the approach doc's `## Decisions made by architect (push back if wrong)` section. Don't gate progress on confirmation. The cost of a wrong mechanical decision is small; the cost of repeated over-asking is high.

Target ratio for an established approach doc (Decisions 10+): roughly **decide 3, ask 1** — not the inverse.

### 10. Opportunistically advance idle missions

After completing any non-user-gated step on any mission, the orchestrator scans every in-flight mission for a non-user-blocking next step that can be dispatched in the same turn. Single-thread only at user gates (approach / spec / plan-mission / compliance-routed PR) and merge gates. If the user is mid-conversation on one mission, every other mission should still be progressing through its non-user-blocking steps in the background.

Concretely: dispatch `planner` the moment a spec closes, even if pivoting to a different mission's gate next. Dispatch `plan-reviewer` the moment `planner` closes. Batch user-gate decisions across missions when a user-attention moment arrives — surface multiple pending gates together rather than asking about them one at a time.

### 11. Worktree default for edit-making subagents

Any subagent that can modify the working tree — including upstream doc-editing agents (`architect`, `spec-writer`, `planner`, `plan-reviewer`, `test-author`, `doc-keeper`) and not only `implementer` — dispatches on its own git worktree by default (`isolation: 'worktree'`).

This **supersedes the v2 doctrine** that upstream agents work in the main tree. That doctrine predated the parallelism principle (#5 + #10); with concurrent dispatch as the default, isolation must be too. Cost is near-zero: the harness creates the worktree, returns path + branch, and auto-cleans if the agent makes no changes.

Worktree cleanup respects uncommitted changes — see [#16](#16-worktree-cleanup-must-respect-uncommitted-changes). The orchestrator must surface (not silently lose) work that landed in a worktree but couldn't commit.

### 12. Default to subagent dispatch over direct orchestrator work

Every task with a named owning role dispatches to that role's subagent on a worktree (per [#11](#11-worktree-default-for-edit-making-subagents)). The orchestrator's direct work is reserved for:

1. Opening and merging PRs.
2. Updating task-list state and routing notes in its own scratch (not in the repo's docs or code).
3. Single-line entries in `docs/research/agent-team-calibration.md`.

When in doubt whether a task is direct-edit-or-dispatch, **dispatch**. The orchestrator's value is in routing and decision-making, not in execution; absorbing executable work degrades both. Direct edits also skip the audit-trail benefits of dispatch-on-worktree (#11) and the PR ceremony (#21).

### 13. Feasibility check between architect and spec-writer

For any approach that names specific module imports, exported types, or build-tooling assumptions, `architect` runs a stub-compile or stub-build pass before closing the approach gate. The result is recorded in the approach doc's `## Risks` section. Architect explicitly answers: *"have I verified the proposed integration shape compiles end-to-end?"*

`plan-reviewer` surfaces a critique if the approach doc misses this cue.

### 14. doc-keeper vs architect routing

The orchestrator over-escalates trivial doc work to `architect` when `doc-keeper` would do it in 1/5th the time. Apply the routing table under [Doc-keeper discipline](#doc-keeper-discipline) above. When in doubt: `doc-keeper`. Architect re-gates are expensive and reserved for actual shape changes.

### 15. Bash auto-allowlist for known-safe subagent commands

`templates/claude-settings.json.template` ships with auto-approval for read-only and obvious-write commands subagents need to do their work without orchestrator round-trips. Without this, subagents fail silently into orchestrator-as-fallback (see [#12](#12-default-to-subagent-dispatch-over-direct-orchestrator-work)).

The allowlist includes:

- `scripts/second-opinion.py` invocations.
- `git status / log / diff / show / add / commit / restore / stash` operations.
- `go build / vet / test / mod tidy` (or language-equivalent).
- `make:*` for repo-local make targets.

Forbidden operations (push --force, sudo, brew/apt/pip/npm install, ssh, gh secret/release/repo-edit) remain denied. The allowlist is conservative — it covers the operations subagents need but does not unlock anything that touches shared state.

### 16. Worktree cleanup must respect uncommitted changes

The harness's auto-cleanup of worktrees-with-no-commits silently deletes uncommitted in-progress edits when the agent couldn't `git commit` (e.g., because of a missing allowlist entry per [#15](#15-bash-auto-allowlist-for-known-safe-subagent-commands)).

The orchestrator must NOT rely on the harness's default auto-clean. Before cleanup, check `git status --porcelain` on the worktree; if non-empty, **preserve the worktree** and report the path + branch to the user. Subagents that hit a commit denial must surface it in their return value rather than silently exiting; the orchestrator must not interpret "no commit" as "no work."

Strictly this is a harness-level concern, but the orchestrator's operating posture should default to "keep if anything was written."

### 17. Ticket-size norm

Tasks in a plan-mission default to ~50–200 LoC each. Tasks >200 LoC must be split unless `planner` explicitly justifies why the work is atomic (e.g., a single state-machine table that doesn't decompose). The implementer fleet absorbs 5–10 small tasks in parallel; 2–3 large tasks serialise regardless of worktree availability.

### 18. Aggressive implementer fan-out on dependency satisfaction

After every merge, the orchestrator's automatic next move is to scan the plan-mission and dispatch every implementer task whose dependencies have now been satisfied — in the same orchestrator turn, in parallel, each on its own worktree. No serialising on "let's see what comes back first." If the plan-mission has N tasks now eligible, dispatch all N implementers in one batch.

This is the implementer-phase analogue of [#10](#10-opportunistically-advance-idle-missions).

### 19. `ceremony_level` config field in AGENTS.md

The repo's `AGENTS.md` declares `ceremony_level: foundation | demo | iterate-fast` at the top of the file (per the [Repo ceremony level](#repo-ceremony-level) section). Agents consult the field; agents not used at the chosen ceremony level skip themselves with a one-line note.

- `foundation` — full loop (current v2 default).
- `demo` — approach + spec collapsed; planner optional; plan-reviewer optional.
- `iterate-fast` — single doc per slice; implementer + adversary + doc-keeper only.

`scripts/bootstrap.sh` prompts for ceremony level during instantiation.

### 20. Calibration log as a default template file

The template ships `docs/research/agent-team-calibration.md` as a stub the orchestrator appends to whenever it notices drift or recovers from a calibration miss. Entries are dated, short, append-only. Patterns that recur across several entries are candidates for upstream amendment to `claude-code-setup`.

`scripts/bootstrap.sh` offers to copy the stub on instantiation.

### 21. PR ceremony for every change

When merging a subagent worktree, the orchestrator pushes the branch and opens a PR via `gh pr create`, even when the orchestrator is the one driving the change. The merge can be near-immediate for doc-only PRs (no `adversary` review, no CI gate required), but the PR exists as the audit trail.

The orchestrator dispatches `doc-keeper` on a worktree (per [#11](#11-worktree-default-for-edit-making-subagents), [#12](#12-default-to-subagent-dispatch-over-direct-orchestrator-work)), `doc-keeper` opens the PR, the orchestrator merges if no `adversary` is gated. Same audit chain, just doc-only and faster than the code path.

The exhaustive list of direct-to-main exceptions is in the [Merge policy](#prs-are-the-audit-trail-surface-for-every-change-reaching-main) section above.

### 22. Cross-repo dependencies signal via GitHub issues in the target repo

Issues are the *protocol between repos.* PRs are the *protocol within a repo.* Plan-mission docs are the *protocol within a mission.*

When the orchestrator completes work whose output unblocks another repo — a sibling repo the project knows about, or a stable upstream the project depends on — its next action *after* merging the PR is to file an issue in the target repo. The issue references the originating context: merged PR URL, plan-mission task, vendored patch markers, or other concrete provenance.

Conversely, when the orchestrator's plan-mission contains a task blocked on output from another repo, the dependency is recorded as either:

- An issue filed on the blocking repo (preferred — surfaces the dependency to that repo's session), or
- A `Blocked by` note in the plan-mission task pointing at an existing issue.

**Lane discipline.** Cross-repo signalling is the orchestrator's responsibility when the dependency originates from completing in-flight work. The navigator session's lane (see [#6](#6-navigator-sessions-complement-the-orchestrator)) is cross-repo *discovery* (finding the dependency by reading external source); the orchestrator's lane is cross-repo *handoff* (telling the next repo it's their turn). The two roles do not overlap; either fills the dependency surface for the other.

**Categories the orchestrator routinely files:**

| Triggering event | Target repo | Issue role |
| --- | --- | --- |
| Plan-mission task produces an artifact (image, library, schema) consumed by another repo | the consuming repo | "*artifact* `v<X>` available — consume in *<slice/spec/version>*" |
| Vendor-and-patch (see [#8](#8-vendor-and-patch-over-upstream-pr-and-wait)) accumulates fixes against an upstream | the upstream | "Upstream contribution offer: patch summary + diff" |
| The repo hits an operating-model gap | the template repo | Amendment candidate (see [#20](#20-calibration-log-as-a-default-template-file)) |
| The repo spots a bug in another repo's stable artifact | that repo | Standard bug report |

**Issue-creation defaults.** Issues filed across repos receive the `dependencies` label (created by `scripts/bootstrap.sh`). The issue body links back to the originating PR or plan-mission task, so the target repo's session has the full chain of provenance without needing to interrogate the source repo.

**Post-merge action sequence** for the orchestrator becomes:

1. PR merges (per merge policy).
2. Plan-mission task marker flips to `[x]` — by the orchestrator, in the same turn (see [#23](#23-plan-mission-maintenance-is-the-orchestrators-standing-lane)).
3. **Cross-repo handoff:** if the merged PR produced an artifact a sibling or upstream repo consumes, file an issue in the consuming/upstream repo referencing the merged PR + plan-mission task. Apply the `dependencies` label. Use the categories table above for tone and title shape.
4. Scan plan-mission for newly-unblocked tasks (per [#18](#18-aggressive-implementer-fan-out-on-dependency-satisfaction)); dispatch implementers per worktree isolation defaults ([#11](#11-worktree-default-for-edit-making-subagents)).

### 23. Plan-mission maintenance is the orchestrator's standing lane

The plan-mission file at `docs/plan-missions/<slug>.md` is the orchestrator's standing-lane responsibility. After every state change — implementer dispatched, PR opened, adversary returned, PR merged, cascade triggered, PR superseded, task split or consolidated — the orchestrator updates the plan-mission file in the same turn as the dispatch / merge / status-change.

**Why v2 / v3-prerelease doctrine broke here.** Earlier versions said *"implementer updates each task's status marker as work proceeds."* That model assumed:

1. **One implementer at a time.** With [#18](#18-aggressive-implementer-fan-out-on-dependency-satisfaction)'s fan-out, N implementers run concurrently and each one only sees its own task. Cross-task state (cascade markers, supersession notes, consolidations) had no owning agent.
2. **One PR per task.** With [#21](#21-pr-ceremony-for-every-change)'s per-merge PR ceremony plus practical realities (PRs supersede each other; tasks split mid-stream; CI cascades break and unbreak), PR ↔ task is not 1:1.
3. **Implementer has full view.** A single implementer on a worktree sees its task only. It can't update siblings dispatched in the same fan-out batch.

The orchestrator is the only agent with the complete view; it must own the file.

**Implementer's reduced scope.** Implementer touches the plan-mission **only to flip its own task's marker** (`[ ]` → `[~]` → `[x]`). Cross-task state changes are out of scope for implementer — surface to the orchestrator instead.

**No-plan-mission rule.** If a track needs implementer dispatch but no plan-mission file exists at `docs/plan-missions/<slug>.md`, the orchestrator dispatches `planner` first. Retroactive plan-missions are still better than no plan-mission. Ad-hoc implementer dispatches directly off a spec are forbidden.

**Planner's reinforced role.** `planner` is the only writer for *initial* plan-mission structure. Mid-flight structural changes (a task splitting into T4a + T4b; two tasks consolidating into one PR) trigger a `planner` re-dispatch, not a manual orchestrator edit. The orchestrator owns the *running state* (markers, cascade notes); planner owns the *structure* (task graph, dependencies, splits).

**Failure mode this prevents.** Without this lane assignment, plan-mission files go stale within hours of fan-out activating. The "living plan-mission" promise rots silently the moment parallelism kicks in. Operator-observed: `noah-2` Track A's plan-mission showed T2 / T4a / T4b / T7 as "proposed" for hours after they had been bundled into a merged PR. Track B had no plan-mission file at all and ran ad-hoc against the spec.

### 24. Orchestrator proactively checks in on long-running background agents

Stuck subagents — Bash denial at commit time, infinite tool loop, hung shell call — fail silently if the orchestrator only listens for completion notifications. Long silences are signals, not noise.

**Mechanism.** At every turn boundary, the orchestrator scans in-flight subagent dispatch timestamps. For any agent past its expected duration, it autonomously checks in: either `Read` the agent's task output / transcript, or `SendMessage` asking for status.

**Expected-duration defaults** (override per-task when the plan-mission task is genuinely larger):

| Subagent | Expected duration |
| --- | --- |
| `implementer` | 10 min |
| `test-author` | 10 min |
| `spec-writer` | 5 min |
| `adversary` | 5 min |
| `doc-keeper` | 5 min |
| `plan-reviewer` | 5 min |
| `architect` | varies — gated on user, not a check-in target |

**On detecting a stuck agent:**

1. Read the agent's transcript / JSONL output to identify the blocking step.
2. **If Bash denial** (see [#15](#15-bash-auto-allowlist-for-known-safe-subagent-commands)): widen the allowlist + re-dispatch, OR salvage the worktree edits by folding them into an orchestrator-merge-step (one of the direct-to-main exceptions in [#21](#21-pr-ceremony-for-every-change)), OR re-dispatch the agent with an `edit-only-no-git` constraint and let the orchestrator commit on its behalf.
3. **If hung tool call** or **infinite loop**: cancel + re-dispatch with a revised prompt.
4. **If genuinely just-slow** (large task, legitimate iteration): note the actual duration in the plan-mission so future dispatches calibrate.
5. **Log the observation** in `docs/research/agent-team-calibration.md` if it represents a new failure mode.

**Companion to [#15](#15-bash-auto-allowlist-for-known-safe-subagent-commands) and [#16](#16-worktree-cleanup-must-respect-uncommitted-changes).** Those three together close the silent-failure loop: #15 prevents most Bash denials from happening; #16 preserves uncommitted edits when they do; #24 catches the agent that *was* denied and is now silently stuck so the orchestrator can intervene before downstream cascade work is blocked.

**Failure mode this prevents.** Operator-observed: `noah-2` 2026-05-14 — a PR fixup implementer hit Bash denial at the commit step, returned no edits, and the orchestrator only noticed the agent was stuck when the user manually pointed at PR #19 being silent for 30+ minutes. Earlier in the same session, PR #15 / PR #10 rebase agents left stale conflicts because nobody checked back after dispatch. The "set and forget" dispatch model fails when Bash denial is the dominant failure mode.

### 25. Tag pushes always produce GitHub Release objects, with notes versioned in-tree

Repos that publish artifacts have an invariant: **every tag has a corresponding GitHub Release object**, and the Release body is sourced from a version-controlled file at `docs/releases/<tag>.md`. The template's `release.yml.template` workflow encodes this — build/push steps are project-specific stubs, but the Release-creation step is non-negotiable.

**Per-tag notes convention.** A release PR cuts a version and lands a corresponding `docs/releases/v<X.Y.Z>.md` file with the notes content alongside the substantive change. The notes are:

- **Version-controlled** — they live in the repo's git history, not as an API artifact created post-hoc.
- **Reviewable** — they appear in the bumping PR's diff alongside the change they describe.
- **Immutable post-release** — once the tag is pushed and the Release object is created, the file freezes.

`release.yml` fails fast if `docs/releases/<tag>.md` doesn't exist when the tag is pushed. No silent gaps where tags publish images but the Releases page stays empty.

**Cutting a release.** The orchestrator-driven flow:

1. Open a release PR. Title: `release: vX.Y.Z`. Diff includes `docs/releases/vX.Y.Z.md` with the notes content + whatever substantive change ships with this version (a fix, a feature, a vendored-patch bump).
2. Merge to `main`.
3. Tag the merge commit: `git tag -a vX.Y.Z -m "vX.Y.Z" && git push origin vX.Y.Z`.
4. `release.yml` fires: builds artifacts, creates GitHub Release with the body from `docs/releases/vX.Y.Z.md`. `make_latest: true` unless tag has `-pre` / `-rc` / `-alpha` / `-beta` suffix.

**Failure mode this prevents.** Operator-observed on `noah-2` 2026-05-14 → 2026-05-15: v0.1.0 through v0.3.1 tags shipped (images on GHCR, tags on the repo) without any GitHub Release objects. The navigator manually created five Release objects post-hoc via `gh api`. Without a template invariant, every repo bootstrapped without a `release.yml` of its own hits the same gap from scratch.

### 26. Use closing keywords only when the PR fully resolves an issue

GitHub's auto-close keywords (`closes`, `fixes`, `resolves`) operate on the issue number alone. Any scope qualifier that follows is **ignored**. A PR body line reading `Closes #81 Bug 1` will close the whole `#81` issue even when the PR fixes only Bug 1 and Bug 2 was explicitly deferred.

**For partial fixes:**

- Write `refs #N` or `addresses #N (Bug 1 only)` in the PR body — not `closes`/`fixes`/`resolves`.
- On merge, the orchestrator (or PR author) manually comments on the issue stating what was resolved and what remains.
- If the umbrella issue's scope is best split, file a separate narrow issue for the remaining work **before merge** so the trail is clean.

**If an issue is auto-closed in error**, reopen it and post a comment naming the residual scope so the audit trail reflects reality.

**Why this is template-level.** `adversary`'s **Stale claims** dimension checks that commit message / PR description match the diff — but it does not check whether closing keywords match the scope of the resolution. Operator discipline carries this; the template documents the failure mode so the discipline is shared, not re-discovered per repo.

**Failure mode this prevents.** Operator-observed on `noah-2` 2026-05-15: PR #82 fixed Bug 1 of two named bugs in #81. PR body said `Closes #81 Bug 1. Bug 2 (Inspector token sub propagation) deferred.` GitHub auto-closed #81 anyway on merge. Navigator had to reopen + add a clarifying comment.

### 27. Session-boundary stash hygiene

When work is handed off across AI sessions — Cursor → Codex → navigator → orchestrator, or any other multi-tool flow — each session that needs to check out a different branch may `git stash` WIP. Anonymous stashes accumulate; nobody remembers what they contain; by session N the stash list is opaque dead weight.

**Rules:**

1. **Tag every stash with intent.** `git stash push -m "wip-<branch>-<short-reason>"` (e.g. `wip-bundle-a-realm-edits`). Anonymous `git stash` calls without `-m` are forbidden when handing off.
2. **Surface stashes in the handover note.** When passing work to another session or to a human, include `git stash list` output verbatim plus what each entry is for. If the handover target is a human, also state whether each stash is safe to drop.
3. **Drop on session boundary.** Every AI session that creates a stash is responsible for either restoring it or explicitly handing it off. Never close a session leaving an unowned stash on the working tree.

**Orchestrator end-of-mission summary.** When `conductor` (or the orchestrator's own digest) closes out a mission, include a `Working-tree state:` line that names any open stashes and their owners. Empty state is the desired norm; non-empty state names what's there.

**Failure mode this prevents.** Operator-observed on `noah-2-demo` 2026-05-15 end-of-session: three stashes across two branches from three different coordination steps over ~4 hours, all anonymous, none of them intentional carrying state. The user had to be asked to tiebreak whether each was safe to drop. Multi-AI sessions accumulate stash debt much faster than single-AI sessions; the discipline scales with the number of session boundaries crossed, not with the wall-clock duration.

### 28. The orchestrator checkout is sync-only: never edit it directly

The orchestrator keeps its own checkout pinned to `origin/main` — it periodically runs `git checkout main; git reset --hard origin/main; git pull` so every new worktree branches from a clean, current `main` (per [#11](#11-worktree-default-for-edit-making-subagents)). That part is correct and required.

**The hazard.** `git reset --hard` silently discards **any uncommitted change to a tracked file** in the orchestrator's checkout. Only untracked *new* files survive a sync. Nothing about the routine reset warns the editor that work is about to vanish.

**When it bites.** The normal flow is safe — implementers commit on worktrees and open PRs, so committed work is never at risk. The hazard only surfaces when someone edits files **directly in the orchestrator's working directory and leaves them uncommitted**, e.g. an external editor (Codex / Cursor) opened *on* the orchestrator's checkout, or the navigator making a `settings.json` / config edit and not committing it.

**Rules.**

1. The orchestrator's checkout is **sync-only**. Never edit files directly in it. All editing happens on a worktree/branch (per [#11](#11-worktree-default-for-edit-making-subagents)) or in a separate clone.
2. External editors (Codex / Cursor) and any interactive human editing use a **separate clone or a dedicated worktree/branch**, never the orchestrator's main checkout.
3. Navigator config/settings changes are **committed** through the normal PR path ([#21](#21-pr-ceremony-for-every-change)), not left as working-tree edits.
4. Recommended: run the orchestrator in a clone **distinct** from where humans/editors operate, so co-tenancy can't happen by accident.

**Recovery, when it happens anyway.** What is recoverable depends on whether the work was ever *staged*. If it was `git add`-ed (or committed) at any point, the content reached the object database: `git fsck --unreachable` (or `--lost-found`) lists the dangling blobs, recoverable with `git cat-file -p <blob>`. But a purely **unstaged** working-tree edit — the common case where an external editor writes files and never stages them — was never written to `.git/objects`, so `git reset --hard` leaves **no git-recoverable trace**; there, the editor's own session/history log is the only source — Codex at `~/.codex/sessions/*.jsonl`, Cursor at `~/Library/Application Support/Cursor/User/History/`. Recover from the dangling blob (if it was staged) or the editor log (the fallback for unstaged work); do not trust an editor's own "I restored it" claim without checking.

**Companion to [#11](#11-worktree-default-for-edit-making-subagents) and [#16](#16-worktree-cleanup-must-respect-uncommitted-changes).** Those protect edits made *on a worktree*; this one protects against edits made in the *orchestrator's own checkout*, which has the opposite lifecycle — it is deliberately disposable and resets without warning.

**Failure mode this prevents.** Operator-observed in a downstream project built from this template (`jk-nd/noah-3`): an external editor (Codex) was opened on the orchestrator's main checkout, did a substantial UI rewrite, and left it uncommitted; the orchestrator's routine reset wiped it. A navigator `settings.json` hook edit was lost the same way, unnoticed. Both were recoverable via `git fsck` dangling blobs + the editor's session logs — but it was an avoidable fire drill, and the editor wrongly believed it had restored the work.

### 29. The GitHub planning surface

[#22](#22-cross-repo-dependencies-signal-via-github-issues-in-the-target-repo) frames issues as the cross-repo protocol and [#23](#23-plan-mission-maintenance-is-the-orchestrators-standing-lane) makes plan-mission docs canonical, but neither describes how GitHub is used *within* a repo day-to-day — which in practice is heavily. This clarification documents the proven model so it is shared, not re-derived per repo.

- **Milestones = build phases.** One milestone per `Phase N: <Name>`, sourced from the architecture doc's build-phases section. A milestone stays **open after its bulk work completes** so it can absorb follow-ups and regressions discovered later.
- **Issues = work items, within-repo as well as cross-repo.** Plan-mission tasks, bugs, follow-ups, and tech-debt all live as issues — not only the cross-repo dependencies of [#22](#22-cross-repo-dependencies-signal-via-github-issues-in-the-target-repo). Cross-linked titles keep the trail legible: `follow-up(#N):`, `regression(#N):`, `[#N follow-up]`.
- **Labels carry routing.** `phase-N` labels mirror the milestones for filtering; `for-orchestrator` / `for-navigator` are the multi-session pickup channel that tells each session which issues are in its lane.
- **GitHub mirrors; plan-mission docs stay canonical.** For live running state — what is dispatched, in review, merged — the plan-mission file at `docs/plan-missions/<slug>.md` remains the source of truth ([#23](#23-plan-mission-maintenance-is-the-orchestrators-standing-lane)). GitHub is the durable, multi-session-visible *mirror*. State this explicitly so the two surfaces are not treated as co-equal and allowed to drift.

The `phase-N`, `for-orchestrator`, and `for-navigator` labels are created at bootstrap alongside the existing label set (tracked separately as a `scripts/bootstrap.sh` enhancement); this clarification governs how they are *used* once present.

### 30. Human-legibility norm for read-outs and decision write-ups

This strengthens [#7](#7-read-outs-are-lossy-the-artifact-is-canonical) (read-outs are lossy) and [#3](#3-question-presentation) (question presentation) with a legibility requirement.

Orchestrator read-outs and architect decision write-ups **lead with the plain-language stakes** — an intuition, an analogy, or "what this means / why it matters" — and only then give the technical detail. A summary that is technically correct but jargon-first, so that a human has to reverse-engineer the point, is a **defect**, not a matter of taste. It defeats the purpose of the read-out, which exists so the user can decide quickly and correctly.

This applies to gate summaries, orchestrator status read-outs, the architect's `## Decisions made by architect` write-ups, and open-question framing.

**Failure mode this prevents.** Operator feedback during an `nda-vertical` bootstrap session: a technically-correct orchestrator read-out "was not very understandable for a human." The information was all present; the ordering and register made it unusable at a glance.

### 31. Briefing precedence: source-of-truth wins over a parts-donor

A briefing sometimes names both a **parts-donor** repo ("salvage the taxonomy / scaffolding from X") and a **source-of-truth** for the actual content or criteria. When it does, precedence is explicit and non-negotiable: **the source-of-truth wins; the donor is structural/parts only.** The donor supplies skeleton, naming, and file shapes — never authority over criteria or content when the two disagree.

`architect` and `spec-writer` resolve this precedence *before* reusing donor material, and record the resolution where the reuse is described, so a later reader doesn't silently re-inherit the donor's content as if it were authoritative.

There is no `CLAUDE.md` template shipped today, so this guidance lives here; when a `CLAUDE.md`-authoring prompt is added to `scripts/bootstrap.sh`, it should carry the same rule.

**Failure mode this prevents.** Operator-observed in an `nda-vertical` bootstrap: the briefing named a donor repo for structure and a separate criteria source (a client NDA breakdown + a gold-standard template). The donor's `CHECKLIST.md` had to be explicitly demoted — the criteria source was the authority, the donor only the skeleton — to stop the donor's checklist content leaking in as truth.

### 32. Skills: prefer an invocable skill over re-deriving a procedure

The template ships a `.claude/skills/` layer (see [`docs/skills.md`](docs/skills.md)) alongside `.claude/agents/`. **Agents are roles; skills are how-to procedures** for recurring, easy-to-get-wrong tasks. When such a task has a known-right way that would otherwise be re-improvised each session — watching CI to a correct pass/fail (`ci-watch`), pruning agent worktrees safely (`prune-worktrees`), running `adversary` against a project's invariants (`domain-adversary-checklist`) — the orchestrator invokes the matching skill instead of re-deriving the steps.

**Built-ins first.** Claude Code's built-in skills (`code-review` / `code-review ultra`, `verify`, `deep-research`) come before any custom skill. Author a custom skill only when no built-in covers the task *and* the task is recurring **and** easy-to-get-wrong **and** currently a re-derived gotcha.

This is the procedural complement to [#12](#12-default-to-subagent-dispatch-over-direct-orchestrator-work): #12 routes *role* work to the owning agent; this routes *recurring-procedure* work to the owning skill. A skill may itself dispatch an agent (e.g. `domain-adversary-checklist` dispatches `adversary`), so the two layers compose rather than overlap.
