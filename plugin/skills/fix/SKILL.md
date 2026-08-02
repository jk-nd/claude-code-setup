---
name: fix
description: Use this the moment a bug, regression, or escaped defect is reported - before attempting a fix. Reproduces it as a failing regression test first, then minimal fix to green, fresh review, and the incident-to-mechanism step. For production-down emergencies see the break-glass section.
---

# /fix — regression test first

A bug fix without a regression test that would have caught it is not done.

1. **Reproduce.** Write a failing test that demonstrates the defect. If you cannot reproduce it,
   say so and stop — do not fix blind.
2. **Fix minimally.** Smallest change to green. Resist adjacent refactoring; file it instead.
   Most defect fixes are small enough to do in the foreground; dispatch `implementer` in the
   background when the fix turns out to be substantial, so the operator keeps a session to talk to.
3. **Verify + fresh review.** Full repo check, then dispatch `reviewer` (the regression test is the
   rubric). PR references the originating issue with `refs #N` — use `closes #N` only when the PR
   resolves the *entire* issue; GitHub ignores any qualifier after the number, and an auto-closed
   ledger issue silently drops the remaining work.
4. **Incident → mechanism.** If this defect escaped to main or production, add exactly one of:
   a new invariant line, an eval case, a hook, or a lint/CI rule that makes the *class* recur-proof.
   Never a prose rule. Note the incident in the repo's calibration log (one line).

## Break-glass (production down)

When something is burning: fix it directly — skip the ritual, keep the operator informed with
ALERT-type messages. The debt is mandatory and immediate after recovery: regression test,
fresh review of the emergency diff, and the incident→mechanism step. Break-glass without the
after-work is how quality regimes rot; do the after-work the same day.
