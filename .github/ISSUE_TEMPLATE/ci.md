---
name: CI / tooling
about: CI pipeline change, lint config, build infrastructure
title: "[ci][PRIORITY] <topic>"
labels: ["ci"]
---

## Context

<What the CI / build / lint setup looks like today. Reference exact file path and the relevant lines / steps.>

<What is missing or wrong: race detector not enforced / coverage not measured / wrong toolchain version / etc.>

<Why it matters: recent PRs depend on this gate being there / a regression slipped through / etc.>

## Scope

- <Concrete change 1 — e.g. "add `-race` to the existing `build-and-test` go test invocation">
- <Concrete change 2 — alternative approach if applicable, e.g. "or: add a parallel job">
- <Verification step — e.g. "verify CI still finishes within the existing time budget">

## Why <priority>

<Honest rationale for the priority level — e.g. "race detector slows tests 2-20×; worth a follow-up rather than a hot fix".>

## Acceptance

- [ ] <Concrete deliverable 1 — e.g. "either `-race` added, or a new race job exists">.
- [ ] <Concrete deliverable 2 — e.g. "CI completes within an acceptable time budget; document new wall-clock">.
- [ ] <Validation deliverable — e.g. "at least one historical bug from `git log` reproduces under the new gate">.

Source: <today's review / specific PRs that surfaced the gap / etc.>.
