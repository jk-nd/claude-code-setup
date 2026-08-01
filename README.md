# claude-code-setup v4 — "groundwork"

A lean Claude Code setup for enterprise-grade development across multiple repos. Built on the
paradigm in [FRESH-VIEW.md](FRESH-VIEW.md): **environment over orchestration**. The design record of
the competing (rejected) pipeline branch is preserved in [DESIGN.md](DESIGN.md).

## The five layers

| Layer | What | Lives in |
| --- | --- | --- |
| L1 Verification | fast tests as SLO, rubric-graded done, change-class CI, mutation/property checks | `repo-template/ci/`, `repo-template/rubrics/` |
| L2 Rules as code | guard hooks, permission allowlist, tiny behavioral CLAUDE.md | `plugin/hooks/`, `repo-template/` |
| L3 Independence | blind criteria author, fresh-context reviewer (memoryless, read-only), background implementer (worktree-isolated) | `plugin/agents/` |
| L4 Operations | phase ritual, defect loop, security sentinel, fleet ledger | `plugin/skills/`, `fleet-template/` |
| L5 Learning | incident→mechanism, chronicle index, scheduled measure-then-delete ablation | `plugin/skills/` |

## Layout

```
plugin/           the distributable plugin (install in every repo via marketplace or --plugin-dir)
repo-template/    what a consuming repo carries (copy once, then own it)
fleet-template/   the control-repo files for multi-repo operation (copy to a small `fleet` repo)
```

## Install (per repo)

1. `claude --plugin-dir /path/to/plugin` (or publish `plugin/` to a private marketplace and pin).
2. Copy `repo-template/CLAUDE.md` to the repo root; fill in the Environment facts section.
3. Copy `repo-template/.claude/settings.json` (adjust the allowlist to the repo's stack).
4. Copy `repo-template/ci/` workflows; wire branch protection + merge queue per `ci/HARDENING.md`.
5. Optional, multi-repo: create a `fleet` repo from `fleet-template/`; add `--add-dir` to sessions.

## Models and cost

Capability where it pays, economy everywhere else (pricing per MTok in/out, 2026-08):

| Role | Model | Why |
| --- | --- | --- |
| Main session (writing mind) | **Sonnet 5** daily ($3/$15; intro $2/$10) → **Opus 5** ($5/$25) for hard features → **Fable 5** ($10/$50) only for the hardest novel work (consensus/protocol design) | Sonnet 5 is near-Opus on coding/agentic; switch per session with `/model` |
| `reviewer`, `criteria-author` | **Opus 5** (frontmatter default) | One tier above a Sonnet implementer; review quality degrades measurably on haiku. Panel escalates one reviewer to top tier for core/watched diffs |
| `implementer` | inherits the session model (no pin) | You choose per session with `/model`; escalate a hard unit by naming a stronger model at dispatch |
| Explorers, chronicle, sentinel sweeps | **Haiku/Sonnet** | Mechanical read/summarize work |
| Effort | `high` default; `xhigh` for hard implementation and core-lane review; `low` for mechanical steps | On current models effort is as big a cost lever as model choice |

Two settings worth checking in `~/.claude/settings.json`: a global `effortLevel: xhigh` plus a
top-tier default `model` applies maximum spend to *everything*, including trivial turns and every
subagent — prefer per-session `/model` and per-dispatch escalation. The biggest cost lever stays
structural: two ephemeral agents instead of nine standing ones, and docs merges that never invoke a
model at all.

## Operating model in five lines

One mind per unit of work, dispatched to a background `implementer` on its own worktree so your TUI
session stays free for dialogue while code is being written (writes single-threaded per unit;
parallel worktrees only for independent units). Default ritual `/ship`: shape → criteria (blind) →
build → verify → fresh review — phases, not personas; skippable by change class. Defects via `/fix` (regression test first). Whole-system
security monthly via `/sentinel`. Every incident becomes a test, eval, hook, or lint rule — never a
prose rule. Every model generation, `/ablation` re-measures the harness and deletes what no longer
earns its place.
