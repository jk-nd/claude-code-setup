## Summary

<!-- 1–3 bullets describing what changed and why. -->

## Test plan

<!-- Bulleted markdown checklist. Examples below; replace with what's
     relevant to this change. -->

- [ ] Build / compile check passes locally
- [ ] Test suite passes locally (with race detector if applicable)
- [ ] Vet / static analysis passes locally
- [ ] Lint passes locally
- [ ] New code has tests where appropriate

## Boundaries respected

- [ ] Changes are confined to the package tree declared in the linked issue.
- [ ] No edits to shared interfaces / cross-cutting files unless called out below.
- [ ] No modification to `.github/workflows/trust-boundary.yml` or the agentic-review workflow.
- [ ] No backwards-compat hacks or out-of-scope features added.

## Notes for review

<!-- Anything the reviewer should look at specifically: interface
     changes, design choices, deferred work, known rough edges. -->

Closes #<!-- issue number -->

---
Co-Authored-By: <!-- author handle / agent identity -->
