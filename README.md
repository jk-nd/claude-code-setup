# claude-code-setup v4 — "groundwork"

A lean Claude Code setup for enterprise-grade development across multiple repos. Built on the
paradigm in [FRESH-VIEW.md](FRESH-VIEW.md): **environment over orchestration**. The design record of
the competing (rejected) pipeline branch is preserved in [DESIGN.md](DESIGN.md).

## The five layers

| Layer | What | Lives in |
| --- | --- | --- |
| L1 Verification | rubric-graded done, change-class CI, tagged acceptance job, affected-package test selection | `repo-template/ci/`, `repo-template/rubrics/` |
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

## Install

See **[INSTALL.md](INSTALL.md)** — new repo, migration from v3, and fleet setup, with the exact
commands. Don't improvise from this page; the copy order matters (`cp -r` overwrites) and the CI
workflow has to move into `.github/workflows/`.

Prerequisites: `git`, the `gh` CLI authenticated (`gh auth login` — the skills read PRs, issues,
and releases through it), and Go plus `golangci-lint` for the Go template.

## Not implemented yet

Named in the design, deliberately absent from this build — don't read the design record as a
description of what ships:

- mutation testing, property/DST harnesses, evals-as-tests for AI behavior
- test-speed and flake-rate SLOs (nothing measures them)
- scheduling: `/sentinel`, `/chronicle`, and `/ablation` say "run monthly/weekly" but ship no cron
  or routine — they are manual today
- the morning digest, USD circuit-breakers for unattended runs, per-repo configurable watched paths
  (the watched class is a regex in `ci.yml` you edit by hand)

## Models and cost

Capability where it pays, economy everywhere else (pricing per MTok in/out, 2026-08):

| Role | Model | Why |
| --- | --- | --- |
| Main session (writing mind) | **Sonnet 5** daily ($3/$15; intro $2/$10) → **Opus 5** ($5/$25) for hard features → **Fable 5** ($10/$50) only for the hardest novel work (consensus/protocol design) | Sonnet 5 is near-Opus on coding/agentic; switch per session with `/model` |
| `reviewer`, `criteria-author` | **Opus 5** (frontmatter default) | One tier above a Sonnet implementer; review quality degrades measurably on haiku. Panel escalates one reviewer to top tier for core/watched diffs |
| `implementer` | inherits the session model (no pin) | You choose per session with `/model`; escalate a hard unit by naming a stronger model at dispatch |
| Explorers, chronicle, sentinel sweeps | **Haiku/Sonnet** | Mechanical read/summarize work |
| Effort | session-level only (`/effort`, or `effortLevel` in settings) — there is no per-agent or per-dispatch effort override | On current models effort is as big a cost lever as model choice |

Two settings worth checking in `~/.claude/settings.json`: a global `effortLevel: xhigh` plus a
top-tier default `model` applies maximum spend to *everything*, including trivial turns and every
subagent — prefer per-session `/model` and per-dispatch escalation. The biggest cost lever stays
structural: two ephemeral agents instead of nine standing ones, and docs merges that never invoke a
model at all.

## How involved do you want to be?

You should never have to remember this — on a repo where it isn't set, the session **asks you
before it starts the first real piece of work** and records your answer. But so it's written down
somewhere you can find it:

| `.claude/involvement` | What the session does |
| --- | --- |
| `gated` | Waits for you at the approach, at the criteria, and before every merge. Closest to how v3 behaved. |
| `checkpoint` | Waits at the approach and the criteria; after that reports at each phase boundary and keeps going. Stops mid-phase only for something hard to reverse. |
| `autonomous` | Waits at the approach, then runs — surfacing each decision you might want to reverse *as it makes it*. Stops for anything irreversible, security-relevant, or out of scope. |

Set it directly (`echo checkpoint > .claude/involvement`), or just tell the session in plain words
at any time — "check in with me more often", "stop asking, just run" — and it rewrites the file.

Without this, a long run front-loads its questions into the design phase and then goes quiet for
hours. That is right for some operators and wrong for others, and it is not the kind of thing a
harness should guess.

## Operating model in five lines

One mind per unit of work, dispatched to a background `implementer` on its own worktree so your TUI
session stays free for dialogue while code is being written (writes single-threaded per unit;
parallel worktrees only for independent units). Default ritual `/ship`: shape → criteria (blind) →
build → verify → fresh review — phases, not personas; skippable by change class. Defects via `/fix` (regression test first). Whole-system
security monthly via `/sentinel`. Every incident becomes a test, eval, hook, or lint rule — never a
prose rule. Every model generation, `/ablation` re-measures the harness and deletes what no longer
earns its place.
