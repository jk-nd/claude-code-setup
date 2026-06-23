# Skills — reusable how-to procedures for the team

The template ships an **agents** layer (`.claude/agents/`, see [`AGENTS.md`](../AGENTS.md)) and, alongside it, a **skills** layer (`.claude/skills/`). They are complementary.

- **Agents** = *who* does the work — specialised subagents with roles, tool allowlists, and a model class, dispatched as separate contexts by the orchestrator.
- **Skills** = *how* a recurring, easy-to-get-wrong task gets done the known-right way — an invocable `SKILL.md` (optionally with a bundled script) that loads into the current session on demand.

Without skills, hard-won *procedural* knowledge lives as passive memory "gotchas" that every session re-derives and hand-improvises (and gets subtly wrong). A skill makes that knowledge **active, bundled, and consistent** regardless of which session or model is driving.

## What ships in the template

| Skill | What it does |
| --- | --- |
| [`ci-watch`](../.claude/skills/ci-watch/) | Wait for a PR's/branch's CI to finish and report pass/fail with correct exit codes; handles the path-skip case without hanging. Bundles `ci-watch.sh`. |
| [`prune-worktrees`](../.claude/skills/prune-worktrees/) | Safe agent-worktree + stale-branch hygiene: manifest first, never delete in-flight or co-tenant work. Dry-run by default. Bundles `prune-worktrees.sh`. |
| [`domain-adversary-checklist`](../.claude/skills/domain-adversary-checklist/) | Run the `adversary` agent against a project-supplied invariants file (`.claude/invariants/<area>.md`) instead of re-typing the rules per PR. Mechanism only; the project supplies the content. |

`ci-watch` and `prune-worktrees` are orchestrator hygiene tools (CI watching and worktree cleanup are orchestrator jobs). `domain-adversary-checklist` composes with the existing `adversary` agent — see [`docs/agentic-review.md`](agentic-review.md).

## Use the built-in skills first

Claude Code ships built-in skills. Reach for these before authoring a custom one:

- **`code-review` / `code-review ultra`** — review a diff for correctness and quality (the multi-agent `ultra` variant runs in the cloud).
- **`verify`** — run the app and confirm a change actually behaves as intended.
- **`deep-research`** — fan-out, fact-checked research with citations.

A custom skill is worth authoring only when no built-in covers the task.

## When to author a skill

Author one when a task is **all three** of:

1. **Recurring** — it comes up across sessions, not once.
2. **Easy to get wrong** — there's a known trap (a misleading exit code, an unsafe delete, an order-of-operations gotcha).
3. **Currently a gotcha** — the right way lives only in someone's memory or a comment, and gets re-improvised.

`ci-watch` is the canonical example: CI-watching was reinvented repeatedly and the "right" way (read the status rollup, never `| tail`-mask the exit code, treat path-skip as clean) kept being re-derived.

## When NOT to author a skill

- **Trivial one-offs** — a single `git branch -D <name>` doesn't need a skill.
- **Things a built-in already covers** — don't reimplement `code-review` or `verify`.
- **Role work that belongs to an agent** — if the task is "implement this task" or "review this diff against the spec," that's `implementer` / `adversary`, not a skill. A skill captures a *procedure*; an agent captures a *role*.

## How skills compose with agents

A skill runs in the current session's context and can itself dispatch an agent. `domain-adversary-checklist` is the pattern: the skill is the procedure the orchestrator runs (load the project's invariants, frame the review), and it dispatches the `adversary` agent to do the judging. This keeps the agent generic and reusable while letting the skill inject project specifics at dispatch time — consistent with [dispatch-over-self](../AGENTS.md#12-default-to-subagent-dispatch-over-direct-orchestrator-work).

## Authoring shape

A skill is a directory `.claude/skills/<name>/SKILL.md` with YAML frontmatter (`name`, `description`) plus any bundled scripts. The `description` carries the trigger wording — write it so the orchestrator recognises when the skill applies. Bundled scripts keep their logic out of the prompt and make the procedure identical every run; the two shipped scripts put their logic in `python3` (a hard template dependency) for portability. Add the skill's script invocation to the Bash allowlist in `templates/claude-settings.json.template` so it runs unattended (per [AGENTS.md #15](../AGENTS.md#15-bash-auto-allowlist-for-known-safe-subagent-commands)).
