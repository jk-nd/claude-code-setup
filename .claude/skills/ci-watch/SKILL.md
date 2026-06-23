---
name: ci-watch
description: Wait for a GitHub PR's (or branch's) CI checks to finish and report whether they actually passed, with the correct exit-code semantics. Use whenever you need to block on CI before merging or before dispatching dependent work — e.g. "wait for PR #N to go green", "did CI pass on this branch", "is the PR mergeable yet". Handles the path-skip case (a docs-only PR whose required jobs skip) without hanging.
---

# ci-watch

Watching CI to completion is reinvented constantly and is easy to get wrong. This skill encodes the known-right way once, as a bundled script.

## How to run it

```bash
.claude/skills/ci-watch/ci-watch.sh <pr-number>
# or
.claude/skills/ci-watch/ci-watch.sh --branch <branch-name>
```

Optional flags: `--repo owner/name` (defaults to the current repo), `--interval <secs>` (poll cadence, default 20), `--timeout <secs>` (default 1800).

It polls the PR's **status-check rollup** until every check reaches a terminal state, prints each check's `name=conclusion` plus the final `mergeable` / `mergeStateStatus`, and exits:

- **0** — all checks terminal and none failed (SUCCESS / SKIPPED / NEUTRAL), **or** no checks ran at all (path-skipped → reported CLEAN, not hung).
- **1** — at least one check FAILED / CANCELLED / TIMED_OUT / errored.
- **2** — timed out waiting.
- **3** — usage / lookup error.

So `if .claude/skills/ci-watch/ci-watch.sh 40; then ...` is a reliable green/red gate.

## Gotchas this avoids (why the ad-hoc ways are wrong)

- **`gh pr checks --exit-status` is unreliable here.** It can report before all checks are terminal and its semantics around skipped/neutral are surprising. This skill reads the `statusCheckRollup` directly and defines terminal/failed explicitly.
- **`gh ... | tail` masks the real exit code.** A pipeline's exit code is the *last* command's, so a `gh` failure piped into `tail`/`grep`/`head` looks like success. The script captures `gh` output into a variable and checks its own `$?` — never through a pipe.
- **Path-skipped PRs.** A docs-only PR may legitimately skip its Go jobs (see the `ci-pass` aggregator in `ci.yml.template`), so a naive watcher that waits for a specific required job to "appear" hangs forever. This skill treats "no checks ran" as CLEAN and returns immediately.

## Notes

- The exit code reflects **check outcomes** (the CI question). `mergeStateStatus` is *reported* but not used for the exit code, so you can tell "CI is red" apart from "CI is green but the PR is BLOCKED awaiting a review / trust-boundary gate." Read the printed `mergeStateStatus` for the latter.
- Read-only: it never merges, comments, or edits.
