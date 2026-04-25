---
name: Testing
about: Targeted coverage gap — package or function at low / 0% coverage
title: "[testing][PRIORITY] Coverage: <function or area>"
labels: ["testing"]
---

`<package.Function>` is at **<N>% coverage** per <coverage report path>. <One-sentence description of what the function does and why it matters.> Currently exercised only by <existing path: integration tests / cmd wiring / etc.>; <statement of gap, e.g. "no unit test ever invokes it">.

## Scope

- Unit tests in `<package>/<file>_test.go`:
  - <Test case 1 — happy path>
  - <Test case 2 — boundary condition>
  - <Test case 3 — conflict / collision case>
  - <Test case 4 — empty / zero-input case>
  - <Test case 5 — invariant: e.g. "hash unchanged after empty append">
- Integration test wiring through `<entry-point>` to confirm <invariant>.

## Acceptance

- [ ] `<package.Function>` ≥ <coverage target, e.g. 80>% line coverage.
- [ ] At least <N> test cases covering the bullets above.
- [ ] Tests pass under `<test command, e.g. go test -race>`.
- [ ] No behavioural change to production code.

## References

- <Coverage report path / audit date>.
- <Architecture doc reference if applicable>.
