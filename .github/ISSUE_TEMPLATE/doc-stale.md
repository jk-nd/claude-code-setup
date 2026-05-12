---
name: Doc stale
about: Documentation drift — code changed, docs didn't follow.
labels: doc-stale
---

## Doc location

`<file>:<line>` — the doc that is out of sync.

## Code location

`<file>:<line>` — what changed (or the current state of the cited code).

## Drift

What the doc says vs. what the code now does. Be specific — quote the doc text and the corresponding code.

## Suggested fix

(Optional. `doc-keeper` will compose the update when dispatched.)

## Discovered by

- [ ] Audit run (`.github/workflows/docs-audit.yml`)
- [ ] Per-merge check (`adversary` Doc-freshness dimension)
- [ ] Manual report
