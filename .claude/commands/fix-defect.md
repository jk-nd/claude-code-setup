---
description: Fix a bug the disciplined way — reproduce as a failing regression test, fix to green, adversary review, gated merge.
argument-hint: [bug description or issue #]
---

You are the orchestrator. Drive a defect fix for:

**$ARGUMENTS**

1. If given an issue number, read it first. Restate the bug and the expected vs. actual behavior in one or two plain sentences.
2. **test-author** (worktree) → write a **failing regression test** that captures the bug. Confirm it is red for the right reason before any fix.
3. **implementer** (worktree) → smallest change that turns the test green without breaking others. Append to the plan-mission's Discovered-constraints log if the bug revealed something the plan didn't predict.
4. **adversary** → review the diff (it must cover the regression test, dimension 2). Loop on `fail`.
5. Open a PR; merge per the merge policy. If the fix touches a watched path, **STOP for the user**.
6. On merge, comment on the issue stating what was resolved. Use `refs #N` / a closing keyword per clarification #26 (close only if the issue is fully resolved).

A bug fix without a regression test that would have caught it is not done.
