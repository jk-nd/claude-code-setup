# Calibration log

Append-only. One entry per drift or recovery, newest last. This is the institution's memory —
`/fix` writes here on every escaped defect, `/ablation` records every keep-or-delete measurement.
Personal auto-memory is not a substitute: this is checked in and team-visible.

Entry format — keep it to a few lines:

```
## <date> — <one-line pattern>
Confidence: 0.3–0.9   Scope: project | global   Domain: <area>
What happened: <one or two sentences>
Mechanism added: <test | eval | hook | lint rule | invariant>  (never "a prose rule")
```

Promotion rule: a `global` pattern at confidence ≥ 0.7 seen in ≥ 2 entries becomes an upstream
amendment candidate — file it against the setup repo.
