# Commands — invocable entry points to the operating loop

The operating model in [`AGENTS.md`](../AGENTS.md) is documented; commands make
the common paths through it **invocable** by name. A command is a prompt file in
`.claude/commands/<name>.md` that the user (or orchestrator) triggers with
`/<name>`. They are thin wrappers — they compose the existing agents and skills
and honor the same gates, merge policy, and trust-boundary; they add no new
authority.

## What ships

| Command | What it does |
| --- | --- |
| `/ship [what to build]` | Runs the full loop: architect → spec → plan → implement → adversary → merge, stopping at the four user gates. |
| `/fix-defect [bug or #N]` | Reproduce as a failing regression test → fix to green → adversary → gated merge. |
| `/cut-release [vX.Y.Z]` | The clarification #25 release flow: in-tree notes → release PR → tag → GitHub Release object. |
| `/digest` | Dispatches `conductor` for a morning digest from plan-mission state + git activity. |
| `/gate-status` | Reports what's waiting on a user decision vs. progressing in the background. |
| `/adr [decision]` | Captures an architectural-shape decision as a numbered ADR under `docs/adr/` (see [`docs/adr/`](adr/)). |

## Commands vs. agents vs. skills

- **Agents** are roles (who does the work).
- **Skills** are reusable how-to procedures (`docs/skills.md`).
- **Commands** are *named entry points* a human invokes to start a known path
  through the operating loop. A command's body typically dispatches agents
  and/or invokes skills; it does not bypass any gate or the trust-boundary.

## Authoring a command

Add `.claude/commands/<name>.md` with optional frontmatter (`description`,
`argument-hint`) and a body that instructs the orchestrator. Use `$ARGUMENTS`
for the invocation text. Keep commands thin — encode *which* agents/skills run
in *what order* with *which gates*, not new policy. Commands ship as plain files
(like agents and skills); bootstrap performs no action on them.
