# Rubric: <slug>

Approach: <link to approach doc or PR discussion>. Author: criteria-author, <date>.
Acceptance tests: <paths>. Status: draft | approved | done.

## Behaviors (plain language — this table is what the operator approves)

| # | When | The system | Test |
| --- | --- | --- | --- |
| B1 | <a malformed config is loaded> | <refuses to start with a named error — never default-allows> | `<TestX>` |
| B2 | ... | ... | ... |

## Adversarial behaviors (what must NOT happen — a stub passes the table above; it fails these)

| # | When | The system | Test |
| --- | --- | --- | --- |
| N1 | <request has no/invalid credentials> | <rejects with 403 AND makes no downstream call> | `<TestX>` |
| N2 | <input is malformed> | <hard-errors; never defaults to permissive> | ... |
| N3 | <a dependency is unavailable> | <fails closed, surfaces the error> | ... |

## Gradeable criteria (each answerable yes/no with evidence by a reviewer)

- [ ] C1: Every behavior above has a passing test at a stable boundary (API/CLI/HTTP).
- [ ] C2: <property-shaped criterion, e.g. "for any request without a valid tenant token, the
      response is 403 and no downstream call is made">
- [ ] C3: Docs touched by this behavior updated in the same diff.
- [ ] C4: No exported API removed/changed outside the approach's stated surface.

## Invariants in scope

- <invariants/fail-closed.md> — <which lines apply>

## Decisions (push back if wrong)

- <date> <mechanical decision made without asking, one line of rationale>
