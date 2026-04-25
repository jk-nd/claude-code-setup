---
name: Sub-issue
about: One unit of work inside an epic; one subagent owns it end-to-end
title: "[feature][PRIORITY] <topic> (epic #__ / sub-issue _)"
labels: ["sub-issue"]
---

Sub-issue **<letter>** of epic #_. <Critical path / parallel notes.>

## Goal

<One paragraph: what this sub-issue produces.>

## Scope

1. **<Component name>** — <fields, contract, or interface description>.
2. **<Component name>** — <storage, persistence, or wiring description>.
3. **<API name>** — <endpoint shape, list endpoints if applicable>.
4. **Audit / observability** — <which events, which logs, which metrics>.
5. **Integration with X** — <how this slice plugs into the broader system>.

## Non-goals (this sub-issue)

- <Explicitly NOT in scope item 1>
- <Explicitly NOT in scope item 2>

## Acceptance

- [ ] <Concrete, verifiable deliverable 1 — e.g. "package X with types + store">
- [ ] <Concrete, verifiable deliverable 2 — e.g. "endpoints under /admin/v1/foo with tests">
- [ ] <Audit / observability emission deliverable>
- [ ] <Documentation deliverable>

## Prior art to harvest

- <Existing package / PR / pattern that this should mirror>
- <Existing audit / type / interface to coordinate with>

## References

- Epic #_  has the architectural rationale.
