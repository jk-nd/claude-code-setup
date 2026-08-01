# Testing rules

- Acceptance tests (owned by criteria-author, keyed to a rubric) live in `acceptance/` behind the
  `//go:build acceptance` tag: red suites never break `go test ./...` for unrelated packages, and
  implementers do not edit files under `acceptance/` — a wrong acceptance test is a criteria
  change, routed back through the criteria-author.
- Run acceptance explicitly: `go test -tags acceptance ./acceptance/...`.
- Unit tests: table-driven for >1 scenario; always `-race` in CI; no time.Sleep-based
  synchronization (use channels/contexts) — sleep-synced tests flake, and a flaky suite is an
  agent outage.
- Concurrency- or protocol-heavy packages: prefer property-based tests (testing/quick or rapid)
  for anything specified as "for all X".
