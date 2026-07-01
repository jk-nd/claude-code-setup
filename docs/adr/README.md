# Architecture Decision Records (ADRs)

An ADR captures one **architectural-shape decision** and why it was made, so the
reasoning survives the session it was made in. ADRs *complement* the approach
doc's `## Decisions made by architect` section and the plan-mission: those track
the *running* decisions of a mission; an ADR is the *durable, queryable* record
of a load-bearing one.

## When to write one

Write an ADR when a decision:

- changes the architectural shape — a new boundary, a swapped dependency, a
  protocol / data-contract choice; or
- is one a future reader would otherwise have to reverse-engineer ("why is it
  built this way?").

Do **not** write one for mechanical / operational choices — those are recorded
in the approach doc's decisions section per [AGENTS.md #9](../../AGENTS.md#9-decide-rather-than-ask-on-mechanical-questions) — or for reversible one-liners.

## Convention

- One file per decision: `docs/adr/NNNN-kebab-title.md`, `NNNN` zero-padded and
  monotonically increasing. Copy `0000-template.md`.
- ADRs are **append-only**. Don't rewrite an accepted ADR. To change a decision,
  write a *new* ADR that supersedes it and set the old one's status to
  `superseded by [NNNN]`. This is the ADR form of "decisions walk on revision"
  ([AGENTS.md #1](../../AGENTS.md#1-decisions-walk-on-revision)).
- Cross-link the ADR from the approach doc that produced it.

## Capturing one

`/adr <decision>` (see [`docs/commands.md`](../commands.md)) drafts a numbered
ADR from the conversation + approach doc; the architect or orchestrator fills
the options and consequences. Route the new file through `doc-keeper` + a PR like
any other doc change.
