---
name: night-build
description: Run the per-phase build loop that carries an approved plan-mission to done unattended (overnight) — implementer → adversary → orchestrator live-verify → fix → merge, with the stronger-model-class rule and terse reporting baked in. Use for a multi-phase autonomous build once the plan-mission is approved (the four user gates already cleared). Not for a single quick change (use /fix-defect) or before the plan gate.
---

# night-build

The engine of a successful overnight build. It makes the per-task loop **repeatable** instead of improvised, and encodes the two things that made it work in practice: the **adversary is a stronger model class than the implementer** (it catches test-invisible bugs), and the **orchestrator verifies against reality**, not just green tests.

Precondition: an **approved plan-mission** at `docs/plan-missions/<slug>.md` (the approach / spec / plan gates already cleared — see `AGENTS.md`). This skill runs the implementation phase; it does not skip any user gate.

## The loop (per plan-mission task / phase)

For each task whose dependencies are satisfied (fan out in parallel per [#18]):

1. **Implementer** — dispatch on its own worktree at the tier the task's difficulty warrants: `sonnet` default, `opus` for hard logic, `fable` for the hardest (AGENTS.md #35). It writes code + doc updates, turns the `test-author` tests green, commits. It must stay on its own worktree (AGENTS.md #36).
2. **Adversary** — dispatch **one tier above the implementer** (`sonnet`→`opus`, `opus`→`fable`, `fable`→`fable`+convergence; AGENTS.md #35). Different, stronger model class is the point. On `fail`, loop back to the implementer with the findings.
3. **Live-verify (orchestrator)** — do not trust green tests alone. Bring the stack up against **fresh** state, run the real flow, and confirm the change behaves. Verify in the correct order (see `docs/verify-hygiene.md` when present) with test telemetry off so real errors aren't drowned. A test-invisible regression caught here loops back to the implementer.
4. **Merge** — once adversary passed, live-verify passed, CI is green, and the trust-boundary is satisfied, the orchestrator opens the PR and merges per the merge policy. Watched-path PRs stop for the user.
5. **Advance** — update the plan-mission in the same turn (#23); scan for newly-unblocked tasks and fan out again (#18).

## Reporting discipline (keeps the orchestrator context lean)

- Agents return a **terse** result — verdict + findings list + "full detail in my transcript", not a pasted 3,000-word report. `Read` the transcript on demand for the rare case you need specifics.
- The orchestrator's read-out to the user is a **two-line verdict + the fix**, not the full adversary report.
- **Disk is the source of truth, context is scratch**: the plan-mission, git history, and task list hold the durable state and survive compaction. Re-derive the narrative from them rather than carrying it in context. **Compact proactively at phase boundaries**, not mid-task.
- For a large multi-phase build, consider scripting the pipeline with the **Workflow tool** so each agent's output stays out of the driving context entirely (see AGENTS.md #35 / the context-discipline clarification).

## When NOT to use

A single quick change is `/fix-defect`. Anything before the plan-mission gate is the normal architect → spec → planner flow (`/ship`). This skill is specifically the unattended implementation loop for an already-approved multi-phase plan.
