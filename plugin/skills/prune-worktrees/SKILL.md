---
name: prune-worktrees
description: Use this when agent worktrees have accumulated under .claude/worktrees/ and you want the finished ones cleaned up. Reports what is safe to remove and why the rest is not; removes only worktrees that are clean AND whose branch is merged, recording branch tips first so anything removed is recoverable.
disable-model-invocation: true
---

# /prune-worktrees

Dispatched agents leave a worktree behind. They accumulate, and deciding which are safe to delete
is easy to get wrong in a way that silently loses work.

Run the bundled script — dry run first, always:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/skills/prune-worktrees/prune-worktrees.sh"            # report only
bash "${CLAUDE_PLUGIN_ROOT}/skills/prune-worktrees/prune-worktrees.sh" --apply    # remove
```

It refuses to remove anything with uncommitted changes, anything whose branch is not merged into
the base, the current worktree, and the main checkout. Branch tips of everything it removes are
appended to `.git/prune-worktrees-manifest.txt`, so a mistake is recoverable with
`git branch <name> <sha>`.

**The judgement the script cannot make for you.** Clean and merged is necessary but not sufficient:
a worktree stays bound to its agent, and if that agent can still be *resumed*, removing its
worktree means a resumed agent commits into whatever directory it lands in — silent cross-task
corruption. So before `--apply`, confirm the agents are genuinely done, not merely finished with
their last turn. When unsure, keep it: a stale worktree costs a couple of megabytes, and the
failure it prevents costs a debugging session.

Report to the operator what was removed and what was kept with the reason, in one or two lines.
