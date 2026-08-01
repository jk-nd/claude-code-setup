---
name: ablation
description: The measure-then-delete harness review. Run once per model generation (roughly every 6 months) or when the harness feels heavy. Tests whether each piece of the setup still earns its place, and deletes what does not.
disable-model-invocation: true
---

# /ablation — scaffolding is a depreciating asset

Yesterday's scaffolding becomes today's deadweight: Anthropic deleted 80% of Claude Code's own
system prompt when Opus 5 shipped. This ritual is how the setup avoids becoming its own v3.

1. **Inventory.** List the harness surface: CLAUDE.md lines, rules files, skills, agents, hooks,
   settings. For each item note its claimed job.
2. **Classify.** (a) mechanism (hooks, CI, permissions) — keep, mechanisms don't tax context;
   (b) environmental fact (build commands, architecture pointers) — keep if true, fix if stale
   (stale facts are worse than none); (c) behavioral prose — candidate for measurement.
3. **Measure before deleting** (the superpowers lesson: deleting "why" prose degraded test-first
   behavior 8/10 → 5/10 — some persuasion prose is load-bearing). For each behavioral-prose
   candidate: run 3-5 representative tasks with and without it, compare behavior on the specific
   discipline the prose targets. Cheap spot-checks beat no measurement; skip measurement only for
   prose that duplicates an existing mechanism — that deletes without testing.
4. **Delete what fails.** Prose whose removal changes nothing, rules the model now follows
   unprompted, skills unused since the last ablation (check invocation history), hooks whose
   failure mode the platform now prevents natively.
5. **Record.** One calibration-log entry per deletion or retention decision, with the measurement.
   If something was deleted and a regression appears later, /fix routes it back as a *mechanism*,
   not as restored prose (unless the measurement said prose was the working form).

Also check the reverse drift: prose rules that should have become mechanism ("lint leakage"), and
platform features that now cover something the harness hand-rolls.
