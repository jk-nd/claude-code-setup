# `.claude/invariants/` — project must-hold rules for the adversary

Files here are **project-owned checklists** of invariants that must hold for a
sensitive area of the codebase. The `domain-adversary-checklist` skill
(`.claude/skills/domain-adversary-checklist/`) loads one of these and has the
`adversary` agent verify a diff/PR against it — so the same fail-closed standard
is enforced every PR instead of being re-typed by hand.

## Authoring a checklist

1. Copy `example-fail-closed.md` to `.claude/invariants/<area>.md`, where
   `<area>` is a short name you'll reference when invoking the skill (e.g.
   `enforcement`, `auth`, `evidence`, `billing`).
2. Write each invariant as a **single, checkable statement** — something a
   reviewer can mark HOLDS / VIOLATED / CANNOT-VERIFY from the diff alone.
   Prefer "must DENY when X" / "must error when Y" over vague goals.
3. State the **default on uncertainty** at the top (usually: fail closed —
   unprovable means flag it).
4. Optionally add a "how a violation looks" section with concrete code smells;
   it sharpens the review.

## Using it

Invoke the `domain-adversary-checklist` skill with the area name and the
diff/PR. The skill reads `.claude/invariants/<area>.md`, dispatches `adversary`
with those invariants as additional pass/fail criteria, and returns a
PASS/FAIL verdict plus a must-fix list.

Keep these files small and specific — one area per file. They are the
source of truth for what "correct" means in that area, so review them like any
other load-bearing spec.

## Shipped invariants

Besides `example-fail-closed.md`, the template ships two **security invariants
that apply by path** — `adversary` (dimension 8) runs them via the
`domain-adversary-checklist` skill whenever a diff touches the matching paths,
without needing an area named:

- **`workflow-hardening.md`** — `.github/workflows/**`: pinned action SHAs,
  least-privilege permissions, no `curl | bash`, no `${{ }}` script injection.
- **`script-injection.md`** — scripts / `*.sh` / command-building code: no
  command injection, safe subprocess, no path traversal, no secret
  exfiltration, fail-closed on error.

They map to the supply-chain policy in `SECURITY.md`.
