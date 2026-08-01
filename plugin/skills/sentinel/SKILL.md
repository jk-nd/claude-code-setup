---
name: sentinel
description: Whole-system security review - not a diff review. Run monthly per repo (schedule it), on demand after significant architectural change, and in fleet mode across repo seams. Maintains the living threat model and attack surface artifacts.
---

# /sentinel — system-level security review

Per-diff review structurally cannot see systemic risk. This skill reviews the *system*.

## Repo mode

1. Load or create `docs/security/threat-model.md` (assets, trust boundaries, attacker capabilities)
   and `docs/security/attack-surface.md` (every entry point: listeners, authn/authz paths, parsers
   of external input, agent-facing surfaces — CLAUDE.md/rules/skills/MCP configs are injection
   carriers and belong on this list).
2. Sweep the codebase with distinct lenses, one pass each — dispatch parallel read-only agents for
   the heavy lenses (sonnet is sufficient for the sweeps; do the final synthesis and severity
   judgment yourself at full capability): authz (every path fail-closed?), injection (all external input treated as
   data?), secrets handling, supply chain (deps, workflows, toolchain lines), protocol/consensus
   safety where applicable, and the Rule of Two for any agent-facing code the repo ships (untrusted
   input + sensitive access + external write: never all three in one context).
3. Check each invariant in `invariants/` against current code: HOLDS / VIOLATED / CANNOT-VERIFY,
   fail closed on uncertainty.
4. Update both artifacts (they are diffs over time, never rewrites). File one issue per finding
   with severity; ALERT the operator on highs immediately, batch the rest into the digest.

## Fleet mode (with a fleet repo present)

Read `fleet.yaml` edges and review each producer-consumer seam *together*: does the consumer trust
the producer's outputs correctly, do authz assumptions survive the boundary, is fail-closed
preserved end-to-end. Component-local review cannot see these; this pass exists for them.

Built-ins first: for a branch-scoped diff review use `/security-review` instead — this skill is for
what that cannot do.
