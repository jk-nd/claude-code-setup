# Operating — recipes for the orchestrator session

Day-to-day patterns the orchestrator should know. See [`AGENTS.md`](../AGENTS.md) for the operating contract; this file is the troubleshooting + ground-rules side.

## Merge-cascade collision

### The pattern

Two PRs that pass CI individually break `main` when both land sequentially because their changes interact at the AST level even though git's three-way merge had no textual conflict.

Example:

- **PR A** changes `foo()`'s signature from `foo(a, b)` to `foo(a, b, c)` and updates every call site it knows about.
- **PR B** branched off `main` BEFORE PR A and added a NEW call to `foo(a, b)` somewhere PR A couldn't see.
- Both rebase + CI green individually. Sequential merge → `main` has PR A's signature change AND PR B's new old-signature call site → compile error.

This scales linearly with parallel-agent throughput. A solo human merging sequentially rarely hits it; an orchestrator merging 5–10 agent PRs in a window hits it routinely.

### Structural fix: GitHub merge queue

Merge queue auto-rebases each queued PR onto post-previous-merge `main` and re-runs CI before letting the merge land. Eliminates this class of bug.

The template's `ci.yml.template` and `trust-boundary.yml` already carry the `merge_group: { types: [checks_requested] }` trigger. Bootstrap optionally enables the queue. See [`docs/setup.md`](setup.md#github-merge-queue).

### Defense in depth: post-merge build sentinel

`main-broken-sentinel.yml.template` runs a quick verify on every push to `main`. On failure it files a `main-broken` issue tagged with the offending merge SHA and comments on the merging PR. This is opt-in via bootstrap.

### Manual recipe when merge queue is off

1. **Before sequentially merging two PRs that touch adjacent symbols**: rebase the second PR onto post-first-merge `main`, wait for CI green, then merge.
2. **If a merge has broken `main`**:
   1. **Stop merging.** No further PRs land until `main` is green again.
   2. `git fetch origin main && git log -1` to find the offending merge.
   3. Open a **one-line hot-fix PR** — the smallest change that restores green. Don't try to refactor or improve the affected code in the hot-fix; that's a separate PR.
   4. Merge the hot-fix once CI is green.
   5. Resume normal merge cadence.
3. **If the orchestrator detects the cascade pattern proactively** (rare): pause dispatching new tasks that touch the affected files until the conflict is resolved.

## Parallel tracks

Per AGENTS.md operating clarification #5, multiple missions can run their own loops concurrently as long as they don't share watched paths or contended files. Common shapes:

- **Track A's spec just closed → planner queued; Track B's architect gate is up.** Dispatch Track A's `planner` immediately; do not wait for Track B's gate to close. The user is mid-conversation on B, but A's `planner` is non-user-gated and can run in the background.
- **Track A's plan-mission gate closes → multiple implementer tasks immediately eligible.** Dispatch every eligible implementer in one orchestrator turn (per #18), each on its own worktree (per #11). Do not serialise on "let's see what comes back first."

If the user is single-threaded, the orchestrator must not be.

## When the user is mid-conversation

The user is a serial resource — one question at a time, one decision recorded before the next. But every other mission should still progress through its non-user-blocking steps in the background:

- Dispatch `planner` the moment a spec closes.
- Dispatch `plan-reviewer` the moment `planner` closes.
- Dispatch `implementer` the moment the plan-mission's "ready to dispatch now" set updates.
- Batch user-gate decisions across missions when a user-attention moment arrives — surface multiple pending gates together rather than asking one at a time.

## Direct-to-`main` allowlist

The exhaustive direct-to-`main` exceptions (every other change opens a PR) per AGENTS.md operating clarification #21:

1. Bootstrap commits before `AGENTS.md` is in place.
2. `plan-mission` status-marker updates (`[ ]` → `[~]` → `[x]`).
3. Single-line entries in `docs/research/agent-team-calibration.md`.

Anything else — including doc-only recovery commits, decision-record amendments, calibration-log entries longer than one line — opens a PR via `doc-keeper` on a worktree.

## Calibration log entries

When the orchestrator notices drift or recovers from a calibration miss (over-asking, under-dispatching, direct-edit shortcut, lost worktree edits), append a one-line entry to `docs/research/agent-team-calibration.md`. Format:

```
### YYYY-MM-DD HH:MM — <one-line subject>
**Pattern:** <which AGENTS.md operating clarification this maps to, or "new">
**What happened:** <one or two sentences>
**Recovery:** <what the orchestrator did to recover>
**Upstream candidate:** <yes/no + sketch>
```

Single-line entries land direct-to-`main`. Multi-line entries (post-mortems, longer reflections) flow through `doc-keeper` + PR.

Patterns that recur across several entries are candidates for upstream amendment to `jk-nd/claude-code-setup`.

## Proactive check-ins on long-running background agents

Per AGENTS.md operating clarification #24: at every turn boundary, the orchestrator scans in-flight subagent dispatch timestamps. For any agent past its expected duration (10 min for implementer / test-author; 5 min for adversary / spec-writer / doc-keeper / plan-reviewer), the orchestrator autonomously checks in — either `Read`s the agent's transcript or `SendMessage`s asking for status.

On detecting a stuck agent:

1. Read the transcript / JSONL output to identify the blocking step.
2. If **Bash denial** (the most common failure mode): widen the allowlist + re-dispatch, OR salvage worktree edits into an orchestrator-merge step, OR re-dispatch with `edit-only-no-git` constraint and commit on the agent's behalf.
3. If **hung tool call** or **infinite loop**: cancel + re-dispatch with a revised prompt.
4. If **genuinely just-slow** (large task, legitimate iteration): note the actual duration in the plan-mission so future dispatches calibrate.
5. **Log to `docs/research/agent-team-calibration.md`** if it represents a new failure mode.

Long silences are signals, not noise. The "set and forget" dispatch model fails when Bash denial is the dominant silent-failure mode.

## When a subagent's Bash is denied

Per AGENTS.md operating clarifications #15 and #16: if a subagent's allowlisted-but-denied Bash call (e.g., a `git commit` denied because the path pattern doesn't match) causes the agent to return without committing, the orchestrator must:

1. Preserve the worktree (do not let the harness auto-clean it).
2. Note the denial in the orchestrator's scratch + the calibration log.
3. Either widen the allowlist (in `templates/claude-settings.json.template` for upstream propagation, or in `.claude/settings.json` for this repo only) and re-dispatch, OR fold the in-worktree edits back manually and dispatch a fresh agent against the merged state.

**Do not interpret "no commit" as "no work."** Uncommitted worktree edits are work that needs to be preserved.

## When `adversary` flags Smoke-test sync

Per AGENTS.md / `docs/agentic-review.md`: if a PR touches user-facing surfaces but doesn't update the project's smoke-test playbook (`*_SMOKE_TEST.md` or `e2e/MANUAL.md`), `adversary` surfaces a Concern at MEDIUM. The orchestrator's response:

1. Dispatch `doc-keeper` on a fresh worktree against the PR's diff, with a hint that the playbook may need a new flow entry.
2. `doc-keeper` updates the playbook in the same PR (commit on top of the existing branch).
3. Re-run `adversary` against the updated diff.

If `doc-keeper` cannot determine the right entry to add, it inserts a `<!-- doc-stale: <reason> -->` marker and surfaces the gap as an Open Question on the plan-mission. The orchestrator does not merge until the playbook is in sync.

## Decide vs. ask threshold

Per AGENTS.md operating clarification #9: the architect (and downstream agents) apply an explicit threshold before surfacing a question to the user. Mechanical-operational decisions get recorded with a "push back if wrong" note, not gated on user approval.

If the user feels over-asked, the recovery is: re-read the relevant agent definition, re-check that the `## Decisions made by architect (push back if wrong)` section is being populated, and (if needed) tighten the agent's prompt to bias more toward decide. The 3:1 decide:ask target ratio applies to established approach docs (Decisions 10+); early in the doc, ask-heavy is correct.

## Cutting a release

Per AGENTS.md operating clarification #25: every tag has a corresponding GitHub Release object, and the Release body is sourced from `docs/releases/<tag>.md`. The template's `release.yml.template` workflow enforces this — the build/push steps are project-specific stubs, but the Release-creation step is non-negotiable.

Orchestrator-driven flow:

1. **Open a release PR.** Title: `release: vX.Y.Z`. Diff includes `docs/releases/vX.Y.Z.md` with the notes content alongside the substantive change (fix, feature, vendored-patch bump, etc.).
2. **Merge to `main`.**
3. **Tag the merge commit:** `git tag -a vX.Y.Z -m "vX.Y.Z" && git push origin vX.Y.Z`.
4. **`release.yml` fires:** builds artifacts (per the project's stub fill-in), then creates the GitHub Release with the body from `docs/releases/vX.Y.Z.md`. Marked `latest` unless tag has `-pre` / `-rc` / `-alpha` / `-beta` suffix.

If `docs/releases/<tag>.md` doesn't exist when the tag is pushed, the workflow fails fast on the "Verify release notes exist" step. The file is the contract; missing file = missing release.

## Closing-keyword discipline

Per AGENTS.md operating clarification #26: `closes #N` / `fixes #N` / `resolves #N` operate on the issue number alone — GitHub's matcher ignores scope qualifiers that follow. Use them only when the PR fully resolves the issue.

For partial fixes, use `refs #N` or `addresses #N (<scope>)`. On merge, manually comment on the issue stating what was resolved and what remains. If an auto-close happened in error, reopen and post a residual-scope comment.

When opening a PR that fixes one of several sub-items in an umbrella issue, consider splitting the umbrella into a narrow follow-up issue **before merge** so the trail is clean rather than reconstructed post-hoc.

## Session-boundary stash hygiene

Per AGENTS.md operating clarification #27: multi-AI sessions accumulate stash debt unless every session tags its stashes with intent and surfaces them in the handover note.

Rules:

1. **Tag intent:** `git stash push -m "wip-<branch>-<short-reason>"`. Never anonymous when handing off.
2. **Surface in handover:** `git stash list` output + what each entry is for. State whether each is safe to drop.
3. **Drop on session boundary:** each session that creates a stash either restores it or hands it off explicitly. No unowned stashes.

The orchestrator's end-of-mission digest carries a `Working-tree state:` line naming any open stashes and their owners. Empty state is the norm.

## Dispatch over self

Per AGENTS.md operating clarification #12: the orchestrator dispatches subagents on worktrees for every task with a named owning role. Direct work is reserved for PR open/merge, task-list state, and single-line calibration-log entries.

When the orchestrator catches itself doing direct edits in its own context, the recovery is: stop, dispatch the correct subagent, and append a calibration-log entry naming the failure mode. The work isn't lost — the orchestrator can paste its draft into the subagent's input — but the audit trail is restored.
