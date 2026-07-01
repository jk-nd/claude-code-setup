---
name: domain-adversary-checklist
description: Run the adversary review agent against a project-defined invariants checklist instead of re-typing the rules by hand each PR. Use when reviewing a diff/PR that touches an area with fixed must-hold rules (e.g. an enforcement / deny path, an auth boundary, a fail-closed config loader). Loads .claude/invariants/<area>.md and dispatches the adversary agent to verify the diff against exactly those invariants.
---

# domain-adversary-checklist

The `adversary` agent (`.claude/agents/adversary.md`) is generic — "find what's wrong" against the spec and tests. But the *invariants that matter* for a sensitive area are project-specific, and they currently get hand-typed into the adversary prompt every PR — lossy and inconsistent. This skill is the **mechanism** that runs the adversary against a checklist the project owns, so the standard is enforced the same way every time. The project supplies the **content** (its invariants); the template ships the mechanism, an example, and two **security invariants that apply by path**: `.github/workflows/**` → `workflow-hardening.md`, and scripts / `*.sh` / command-building code → `script-injection.md`. When a diff touches those paths, run this skill with the matching invariants even if no area was named.

## How to use it

Given a diff or PR and an area name (e.g. `enforcement`, `auth`, `evidence`):

1. **Resolve the checklist.** Read `.claude/invariants/<area>.md`. If it doesn't exist, list `.claude/invariants/*.md`, pick the closest area, or ask which checklist applies. (See `.claude/invariants/example-fail-closed.md` for the shape and `.claude/invariants/README.md` for how to author one.)

2. **Resolve the diff.** Use `git diff <base>..HEAD` for a worktree, or `gh pr diff <N>` for a PR.

3. **Dispatch the `adversary` agent** (a subagent — same one the operating loop uses) with this framing:

   > Review this diff **against the invariants below — these are the pass/fail criteria, in addition to your standard dimensions.** Default to **flagging on uncertainty**: if you cannot prove an invariant holds from the diff, treat it as a finding. For each invariant: state HOLDS / VIOLATED / CANNOT-VERIFY with a `file:line` citation. Then emit an overall verdict: **PASS** (every invariant HOLDS) or **FAIL** (a must-fix list, smallest fix per item).
   >
   > Diff: `<diff or gh pr diff output>`
   > Invariants (`<area>`):
   > `<contents of .claude/invariants/<area>.md>`

4. **Relay the verdict.** Surface the adversary's PASS/FAIL + must-fix list. On FAIL in the per-task loop, this routes back to the implementer exactly like a normal adversary fail.

## Why a skill (not just a longer adversary prompt)

The checklist lives in one version-controlled file the project maintains, so the same fail-closed standard is applied by whoever (or whichever model) is driving — not re-improvised per PR. The skill keeps `adversary` itself generic and composes the project specifics in at dispatch time.

## Notes

- This skill **dispatches** the existing `adversary` agent; it does not replace it or its 7 standard dimensions (`docs/agentic-review.md`). The invariants are *additional*, project-specific pass/fail criteria.
- Read-only review. It produces a verdict; it does not edit code or merge.
