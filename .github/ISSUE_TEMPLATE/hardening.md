---
name: Hardening
about: Follow-up to surface gaps that aren't blocking but should land as a hardening pass
title: "[hardening][PRIORITY] <topic> — defense-in-depth + edge-case follow-up"
labels: ["hardening"]
---

Follow-up to PR #_  / issue #_. Code review surfaced <N> robustness gaps that aren't blocking but should land as a hardening pass.

## 1. <Gap title> (HIGH / MEDIUM / LOW)

<Description of the gap: where in the code, what the issue is, what the realistic exposure is.>

**Fix:** <concrete remediation, with code shape if helpful>.

## 2. <Gap title> (HIGH / MEDIUM / LOW)

<Description.>

```go
// Optional: code snippet showing the problematic shape
```

**Fix:** <concrete remediation>.

## 3. <Gap title> (HIGH / MEDIUM / LOW)

<Description.>

**Fix:** <concrete remediation>.

## 4. Test coverage gaps (LOW)

- <Missing test 1>
- <Missing test 2>
- <Missing test 3>

## Acceptance

- [ ] Item 1 — <terse statement of done with a negative test case>.
- [ ] Item 2 — <terse statement of done with tests>.
- [ ] Item 3 — <terse statement of done with tests>.
- [ ] Item 4 — at minimum the <named test under -race / fuzz / etc.>.

## Source

<Critical review of PR #_  on YYYY-MM-DD / specific reviewer comment / etc.>
