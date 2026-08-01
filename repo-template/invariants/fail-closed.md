# Invariant: fail closed

Area: configuration loading, authz decisions, and any gate between untrusted input and action.
Default verdict on uncertainty: VIOLATED (unprovable = finding).

1. A malformed, missing, or partially-parsed config MUST hard-error at startup — never fall back
   to a permissive default.
2. An authz check that cannot be evaluated (store down, token unparseable, tenant unknown) MUST
   deny.
3. No code path may convert an error from a security check into a log-and-continue.
4. Feature flags default to the restrictive state when the flag service is unreachable.

How a violation looks: `if err != nil { log.Warn(...); return defaultAllow }`, a zero-value struct
used after a failed parse, an authz middleware that `next()`s on error.
