# Invariants

Must-hold rules for sensitive areas, written so a reviewer can check each line yes/no against code.
The `reviewer` agent and `/sentinel` grade them: HOLDS / VIOLATED / CANNOT-VERIFY — and on a
security invariant, CANNOT-VERIFY is a finding (fail closed).

One file per area. Format: an **Area**, a **default verdict on uncertainty**, numbered single-
checkable statements, optionally "how a violation looks". Prefer converting an invariant into a
mechanical check (lint rule, CI job, property test) whenever possible — an invariant that became a
mechanism gets deleted from this directory and noted in the calibration log.

Note: workflow-file hardening (SHA pinning, injection, least privilege) is checked mechanically by
zizmor in CI — it needs no invariant file here.
