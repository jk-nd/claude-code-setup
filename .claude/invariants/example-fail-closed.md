# Invariants: fail-closed enforcement path (EXAMPLE)

> This is an **example** checklist shipped with the template to show the
> shape. Replace it with your project's real invariants, or copy it to
> `.claude/invariants/<your-area>.md` and edit. The `domain-adversary-checklist`
> skill loads a file like this and has the `adversary` agent verify a diff
> against it. See `.claude/invariants/README.md` for authoring guidance.

**Area:** enforcement / deny path (the code that decides allow vs. deny).

**Default verdict on uncertainty:** if the diff does not let you *prove* an
invariant holds, mark it CANNOT-VERIFY and treat it as a finding. Fail closed.

## Invariants

1. **Malformed config errors at load — never silently allows.** A config that
   fails to parse or fails validation must cause a hard load error, not a
   permissive default. There is no code path where an unparseable policy
   results in "allow".

2. **Missing, tampered, or wrong-kind evidence denies.** If required evidence
   is absent, fails an integrity check, or is the wrong type, the decision is
   DENY — not allow, not skip.

3. **Unconfigured = no-op, not allow-all.** When a check is not configured for
   a resource, the resource is left in its prior state; absence of config does
   not widen access.

4. **Composites preserve prior behavior.** Combining rules (AND/OR/precedence)
   never turns a DENY from any constituent into an ALLOW. A composite is at
   least as strict as its strictest enabled member.

5. **No fail-open on internal error.** An exception, timeout, or nil/None in
   the decision path results in DENY (or a surfaced hard error), never a
   default-allow fallthrough.

6. **Decisions are observable.** Every allow/deny emits the audit signal the
   spec requires (log/metric/event); a decision path that is silent is a
   finding.

## How a violation looks (guidance for the reviewer)

- A new `default:` / `else` branch that returns allow.
- An error swallowed (`if err != nil { /* ignore */ }`) on the decision path.
- A config-absent code path that returns the permissive value.
- A composite that short-circuits to allow before evaluating a deny rule.
