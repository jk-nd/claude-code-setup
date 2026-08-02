---
name: ship
description: Use this at the START of any request to build, add, implement, or change a feature - before writing code, not after. Runs the delivery ritual: shape and get the approach approved, author criteria blind, build, verify, fresh review. Not for defect fixes (use /fix) or trivial mechanical changes.
---

# /ship — the phase ritual

One mind carries each unit of work start to finish — but that mind need not be the session the
operator is talking to. Dispatch the build to a background `implementer` so the operator always has
a live session for dialogue; you keep routing, reviewing, and answering while it works. Other agents
appear only where independence pays: criteria authorship and review. Writes stay single-threaded per
unit; parallelize only genuinely independent units, each in its own worktree.

## Skip table — match ceremony to blast radius

| Change | Ritual |
| --- | --- |
| docs, comments, config values | edit → PR (no ritual) |
| mechanical change, no behavior delta (rename, dep bump, lint fix) | build → verify → PR |
| behavior change | full ritual below |
| touches watched paths, security surfaces, consensus/crypto | full ritual + reviewer panel (2-3 lenses) |

## Phases

1. **Shape.** Read the relevant code before proposing. Write a one-page approach: the recommended
   shape, one alternative worth naming, risks, and a stub-compile check for any named integration
   points. Decide mechanical questions yourself and record them ("push back if wrong"); ask the
   operator only when shapes genuinely diverge or scope/security is at stake. Present the decision
   in plain language: stakes first, 2-4 options, recommendation. **Operator approves the approach.**
2. **Criteria (blind).** Dispatch `criteria-author` with the approved approach. It writes the
   rubric + red acceptance tests on its own worktree without seeing any implementation, and returns
   its branch name. The operator reads the behavior table (not the test code); escalate only if
   criteria and approach seem to diverge.

   **Then establish the work branch — the build cannot start without this.** Worktree-isolated
   agents branch from whatever the main checkout has at HEAD (`worktree.baseRef: "head"`, set in
   the repo template). So: `git checkout -B work/<slug>` and merge the criteria branch into it
   before phase 3. Skip this and the implementer's worktree branches off main, the acceptance tests
   are absent, and every path you hand it fails to resolve. Rubric, tests, and implementation all
   land on `work/<slug>` and ship as one PR — which is also what lets CI require the acceptance
   suite green without ever blocking on a half-finished contract.
3. **Build — dispatch, don't absorb.** Default: dispatch `implementer` **in the background** with
   the approach doc path, the rubric path, and the acceptance-test paths. It runs on its own
   worktree; you return to the operator immediately and stay available for dialogue — reviewing the
   rubric, shaping the next unit, answering questions — until the completion notification arrives.
   Dispatch several implementers only for genuinely independent units, each on its own worktree.

   Work in the foreground instead only when the operator asks to watch it, or the change is small
   enough that a dispatch costs more than it saves (a few lines, a rename, a config value).

   Either way the rule holds: acceptance tests are not edited during Build. If one seems wrong, that
   is a criteria change — re-dispatch `criteria-author` with the contract and the failing-test
   evidence only (never the diff), and let it judge behavior-vs-wording.

   While implementers run: check in on any that has been silent past roughly ten minutes by reading
   its transcript — silence is a signal, usually a denied command or a hung call, not progress.
4. **Verify.** Run the full check the repo declares (tests, lint, build). Fix until clean. If a
   check is slow or flaky, that is itself a finding — file it.
5. **Review (fresh).** Dispatch `reviewer` with the rubric — no summary of your reasoning, no
   coaching. Panel of 2-3 lenses for core/watched paths. Loop on blockers; then open the PR with
   the rubric grades in the description. Merge per the repo's lane policy; watched paths always
   wait for the operator.

## Model escalation

The reviewer and criteria-author default to Opus. Escalate at dispatch, don't run everything at the
top: for core/watched diffs, run one panel reviewer on the top-tier model (model IS overridable per
dispatch; effort is session-level only, so raise it with /effort if the whole session warrants it);
for routine diffs the Opus default suffices. Read-only exploration subagents run on haiku. If the
session itself is on a mid-tier model and the work turns out to be genuinely hard (novel protocol
design, subtle concurrency), tell the operator to restart the phase on a stronger model rather than
grinding — escalation is cheaper than a wrong foundation.

Throughout: state lives on disk (approach, rubric, PR), not in context. If dispatched agents go
silent past ~10 minutes, check their transcripts — silence is a signal. Preserve any worktree with
uncommitted changes; never remove a worktree whose agent may still be resumed.
