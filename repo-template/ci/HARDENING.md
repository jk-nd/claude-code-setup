# CI hardening checklist (agent-era, 2026)

GitHub-side settings that cannot ship as files — apply once per repo. Ordered by leverage; every
item traces to a real 2026 incident class.

## Enforcement (do these first)

- [ ] **Branch protection / rulesets on main**: require `ci-pass`, require PRs, no force pushes.
      Enable **merge queue** (full suite runs there; PR-level tests are affected-only).
- [ ] **Push ruleset on `.github/workflows/**` and CODEOWNERS** — a checking workflow is advisory;
      attackers (GhostAction, Megalodon) won by *pushing workflow files*. Rulesets are enforcement.
- [ ] **Watched-path human gate**: PRs touching workflows, CODEOWNERS, `go.mod` `toolchain` lines,
      or declared crypto/consensus paths require the operator's review (CODEOWNERS + required
      review). Agent-authored PRs on these lanes: add Anthropic's `agent-approval-check` as a
      required status check — for a solo operator set N=1 and hand-review; never give any agent
      identity a ruleset bypass.
- [ ] **SHA-pin every action** in ci.yml (marked `# PIN-BY-SHA`); enable the org policy blocking
      unpinned actions if available. Upgrade pins deliberately — pinners did not get checkout v7's
      fork-PR protection automatically.

## Trust separation

- [ ] No job that touches untrusted content (PR bodies, fork heads, caches writable by untrusted
      triggers) may also hold `id-token: write` or repo-write — OIDC tokens have been minted from
      poisoned runner memory (TanStack, tj-actions). Keep `permissions: contents: read` as the
      workflow default; escalate per job only.
- [ ] Read-only Actions cache for untrusted triggers; no `pull_request_target` with checkout of
      the PR head.
- [ ] Agent runs in CI: OIDC federation to the model API (no static API keys), content
      sanitization on, `allowed_bots` empty.

## Supply chain

- [ ] Dependabot with 3-day cooldown (longer for majors); human review on any `toolchain` line
      change (CVE-2026-42501: a malicious module proxy could serve altered toolchains).
- [ ] Release builds: artifact attestations; verify with `gh attestation verify` at deploy.

## Deployment (services)

- [ ] Feature flags + canary + metric-driven rollback for anything user-facing. Agent-velocity
      merges are only safe when production exposure is progressive and reversible.
