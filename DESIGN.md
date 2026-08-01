# claude-code-setup v4 — clean-sheet design

Status: DRAFT for operator review. Written from first principles on 2026-07-31, before stress-testing
against v3's operating clarifications. The stress-test report (STRESS-TEST.md) records which v3
learnings this design absorbs, which it makes structurally impossible, and which it consciously drops.

## 0. Design stance

v3 was one pipeline, enforced by prose (a 64KB AGENTS.md), distributed as a template repo, run per-repo
in isolation. v4 is **three planes, enforced by code, distributed as a plugin, operated as a fleet.**

Principles:

- **P1 — The verifier is the product.** Agents solve whatever problem the verifier defines. Verification
  is a co-equal plane with its own agents and artifacts, adversarially independent of production —
  never a stage bolted onto the build pipeline.
- **P2 — Prose for judgment, code for process.** Anything that must happen *every time* (review can't be
  skipped, verdicts have a schema, fan-out on dependency satisfaction) lives in workflow scripts and
  hooks. Prose is reserved for judgment calls that genuinely need a model's discretion.
- **P3 — Earned autonomy, per lane.** Trust is concentric and dynamic: each lane (docs, deps, periphery
  code, core code, security surfaces) carries an autonomy level that rises on evidence and falls
  automatically on incident. Never a static global setting.
- **P4 — Containment at the environment layer.** Agents are treated as capable insiders: default-deny
  egress for unattended runs, credential isolation, single-purpose identities, enforcement outside the
  agent's reach (GitHub-side). Model-layer discipline is a second line, never the first.
- **P5 — The operator is a decision-maker, not a log reader.** Nothing reaches the operator until it is
  decision-ready. Every operator-facing message is one of three kinds (DECISION / PROGRESS / ALERT) and
  leads with plain-language stakes.
- **P6 — Disk is truth, context is scratch.** Durable state lives in artifacts (contracts, missions,
  dashboards, git); agent reports are terse pointers to disk.
- **P7 — Fleet-first.** Repos are nodes in a portfolio with declared produces/consumes edges, not islands
  that discover each other by accident.
- **P8 — Ship as a plugin.** The operating system lives in one versioned plugin; a repo holds only what
  is genuinely repo-specific (invariants, threat model, rules, fleet entry, config).

## 1. The three planes

### 1.1 Production plane — makes changes

| Role | Input → Output | Model / effort | Isolation |
| --- | --- | --- | --- |
| `shaper` | idea → one-page approach (2–4 shapes, one recommendation, feasibility stub, decide-vs-ask) | top tier, high effort | worktree |
| `contract-author` | approved approach → **executable contract**: red acceptance tests + prose rationale + invariant deltas | top tier, high effort | worktree |
| `planner` | contract → task graph (only for missions above the size threshold) | mid tier | worktree |
| `implementer` | one task → green diff (docs updated in the same diff) | mid tier, escalable | worktree |

The v3 `spec-writer` and `test-author` merge into **`contract-author`**: the spec IS the acceptance test
suite plus the prose that justifies it. This is the TDD commitment made structural — there is no prose
spec that tests are later "derived from"; what the operator approves at the contract gate is testable
behavior. Blindness to implementation is inherent (the implementation does not exist yet).

`doc-keeper` and `conductor` are deleted as agents: docs ship in the implementer's diff (verified by the
verification plane); audits and digests become scheduled routines (§8).

### 1.2 Verification plane — challenges changes, independently

| Role | Challenges | Key property |
| --- | --- | --- |
| `test-adversary` | the **tests** — against contract intent: coverage of stated behaviors, tautologies, missing edge cases, mutation survivors | runs at contract gate (before any implementation exists) AND post-implementation (test-integrity re-check) |
| `code-adversary` | the **code** — against contract + invariants, assuming the visible tests may be insufficient or gamed | always one tier above the implementer, `xhigh` effort; structured verdict schema |
| `holdout-verifier` | the **pair** — regenerates acceptance checks from the contract prose alone (never having seen implementation or stored tests) and runs them | holdout checks are never stored in the repo; divergence between stored-suite results and regenerated-suite results is a finding |
| `security-sentinel` | the **system** — scheduled whole-system review (§4), not per-diff | operates at repo AND fleet scope |

This answers the independence requirement directly: **tests and code are challenged by different agents
with different failure assumptions, and neither challenger produced the artifact it challenges.**

Hard separation rule, hook-enforced: **the implementer cannot edit acceptance tests.** A PreToolUse guard
blocks Edit/Write on acceptance-test paths inside implementer dispatches. A test that needs changing is a
contract change: it routes back through `contract-author` + `test-adversary`, and re-opens the contract
gate only if behavior (not wording) changed. This makes "adjust the test until it passes" structurally
impossible rather than merely forbidden.

Mechanical anti-gaming layers (CI, §5): diff-scoped mutation testing (do the new/changed tests kill
mutants in the changed code?), three-band coverage gate (kept from v3), and the holdout run.

Domain depth:
- Distributed/consensus/federation code: property-based tests required by the contract; deterministic
  simulation (container-level, Antithesis-style — no production-grade in-process DST exists for Go) as a
  scheduled deep gate, not per-PR.
- AI-behavior features: **evals are tests.** The contract for an LLM-driven behavior includes a regression
  eval set gated at 100% in CI; capability evals run scheduled.

**Incident → eval loop** (workflow-enforced): every escaped defect must produce, in one PR: (a) a failing
regression test reproducing it, (b) an invariant or eval addition when the defect class warrants one,
(c) a calibration-log entry. The `/fix` entry point (§3) refuses to proceed without (a).

### 1.3 Operations plane — coordinates and communicates

Owns: the operator interface (§6), fleet coordination (§7), scheduled routines (§8), and memory &
calibration (§9). The orchestrator session belongs to this plane: it routes, dispatches, merges per
policy, and talks to the operator. It does not write code, author tests, or edit specs.

## 2. Trust model: lanes with earned autonomy

Each repo declares lanes in `.claude/autonomy.yaml`:

```yaml
lanes:
  docs:        { level: autonomous }      # merge on green, PR as audit trail
  deps:        { level: autonomous-cooldown }  # patch/minor after 3-day cooldown; majors gated
  code:        { level: verified-autonomous }  # merge on full verification-plane pass
  core:        { level: verified-autonomous }  # + holdout + mutation mandatory, adversary at top tier
  watched:     { level: operator-gated }  # workflows, CODEOWNERS, go.mod toolchain, crypto/consensus paths
```

Levels move **up** only on evidence (N consecutive clean cycles; new automated reviewers run in shadow
mode first and graduate on validated precision). Levels move **down automatically** on incident (an
escaped defect in a lane demotes it one level until the incident→eval loop completes). The autonomy file
is itself on the `watched` lane.

This replaces v3's static `ceremony_level` with something dynamic and per-lane, and matches the
concentric-rings model documented at the frontier (mandatory review on core, earned automation on the
periphery, shadow mode for new automation).

## 3. The work-unit lifecycle

Operator gates shrink from four to **three plus watched-paths**:

- **G1 — Shape**: approve/redirect the approach. (Unchanged from v3.)
- **G2 — Contract**: approve the executable contract — readable behavior list + the red acceptance suite
  + `test-adversary`'s critique attached. This replaces v3's separate spec gate and implicit test
  acceptance: one decision, on the thing that actually defines "done".
- **G3 — Plan**: only for missions above the size threshold (default: >5 tasks or >1000 LoC projected);
  judge-panel critique attached (§5.3). Auto-skipped below threshold with a PROGRESS note.
- **G4 — Watched-path PRs**: GitHub-enforced, as in v3. The orchestrator can never satisfy it.

Ceremony is selected by **entry point**, not by a config field the agents consult:

| Entry | Flow |
| --- | --- |
| `/ship <idea>` | full lifecycle: shape → contract → (plan) → build loop |
| `/fix <defect>` | red regression test first (refuses to proceed without it) → minimal green diff → verification plane → PR |
| `/patch <trivial>` | implement → code-adversary → PR (docs lane merges on green) |

The **per-task build loop is a workflow script**, not prose: implement → verify (code-adversary +
post-implementation test-integrity + holdout on core lanes) → PR → merge-policy check → fan out newly
unblocked tasks. Schema-enforced verdicts (`pass | fail | needs-clarification` + cited findings), loop-back
on fail with findings attached, resumable after interruption, token-budgeted. Skipping review is not a
discipline the orchestrator maintains; it is a branch that does not exist in the script.

Merge policy (per lane, encoded in the workflow + GitHub):
- verification-plane pass for the lane's required checks
- CI green (async backstop doctrine kept from v3; see §5 for what actually runs)
- `agent-approval-check` satisfied on lanes that require human approval
- no conflict with main; merge queue handles cascade collisions
- the orchestrator never self-approves, never bypasses rulesets

## 4. Security doctrine (system-level, not just per-diff)

Three loops at three cadences:

1. **Per-change** (existing strength, kept): code-adversary invariant dimension + `/security-review` on
   diffs touching declared sensitive surfaces.
2. **Per-repo, scheduled** (new): `security-sentinel` runs monthly (and on demand) against the whole
   system, not a diff. It maintains two living artifacts checked into the repo:
   - `docs/security/threat-model.md` — assets, trust boundaries, attacker capabilities; updated, not
     rewritten; changes to it route through the watched lane.
   - `docs/security/attack-surface.md` — enumerated entry points (network listeners, authn/authz paths,
     parsers of external input, agent-facing surfaces) derived from code, with per-surface invariant links.
   The sweep is a multi-lens workflow (authz, injection, secrets handling, supply chain, protocol/consensus
   safety, **agent-facing attack surfaces** — CLAUDE.md/rules/skills/MCP configs are injection carriers per
   the 2026 incident record). Findings become issues with severity; highs page the operator (ALERT).
3. **Fleet-level, scheduled** (new): the sentinel also runs across repo boundaries where the fleet
   manifest declares edges — e.g. the MCP gateway and its consumers reviewed *together*: does the
   consumer trust the gateway's outputs correctly, do authz assumptions hold end-to-end, is a
   fail-closed invariant preserved across the seam. Component-local review structurally cannot see these.

The development system itself is in scope: sandbox with default-deny egress for unattended runs,
credential masking, guard hooks (config-protection, safety-guard kept from v3), single-purpose agent
identities in CI, and the Rule of Two (untrusted input + sensitive access + external write: never all
three in one agent context) as an explicit review dimension for any agent-facing code we ship — which,
for an MCP-gateway vendor, is the product itself.

## 5. CI/CD doctrine

### 5.1 Change-class routing (the "why did docs run the Go suite" fix)

Every PR is classified by a cheap first job into a change class; the class drives what runs:

| Class | Detected by | Runs |
| --- | --- | --- |
| `docs` | only `docs/**`, `*.md`, images | markdown lint, link check. **No Go build.** |
| `config` | CI-visible config, non-watched | targeted validation for the config surface |
| `code` | Go/source paths | **affected-package tests** (below), lint, build |
| `core` | declared core paths | affected + mutation (diff-scoped) + holdout job |
| `watched` | watched paths | full suite + trust boundary + zizmor on workflow changes |
| `release` | tag / release PR | full suite + provenance/attestation + release workflow |

Two mechanisms, both used: **job-level** path filtering (paths-filter → conditional jobs → a fail-closed
`ci-pass` aggregator that treats *path-skipped* jobs as satisfied — this is the piece v3 templates had but
repos wired incompletely, which is why docs merges ran the full Go suite), and **test-level** impact
analysis for Go: compute changed packages from the diff, take the reverse dependency closure via
`go list`, run `go test` only on that closure. The full suite still runs on the merge queue and nightly —
so per-PR feedback is minutes, and nothing merges to main without a full-suite pass in the queue batch.

### 5.2 Agent-era hardening (from the 2026 incident record)

- `agent-approval-check` as a required status check on operator-gated lanes; the initiating human's
  approval does not count; agent commits signed and attributed.
- Push rulesets (not just a checking workflow) on `.github/workflows/**` and CODEOWNERS; zizmor as a
  required check on workflow diffs; workflow execution protections in evaluate-then-enforce mode.
- Job-level trust separation: no job that touches untrusted content (PR bodies, fork heads, shared
  caches) also holds `id-token: write`; read-only caches on untrusted triggers.
- OIDC federation for agent API access in CI (no static API keys); SHA-pinned actions with deliberate
  upgrade cadence; dependabot cooldown (3 days patch/minor, longer for majors); human review required on
  any `go.mod` `toolchain` line change.
- Provenance: artifact attestations on release builds; `gh attestation verify` as a deploy gate.

### 5.3 Plan critique as judge panel

`plan-reviewer` (agent) is deleted. Plan and contract critiques run as a workflow judge panel: N
independent in-family critics at high effort with distinct lenses (sequencing risk, testability,
hidden assumptions) plus one cross-vendor critic (Gemini, current model, config-pinned not hardcoded).
Disagreement between critics is surfaced as signal at the gate, verbatim. Same divergent-priors intent
as v3, now with enforced independence and no stale model pins.

### 5.4 Deployment (v3's acknowledged gap)

For deployable services (the gateway): feature flags + canary + metric-driven auto-rollback as the
standard backstop; merge velocity is only safe when production exposure is progressive and reversible.
For libraries/artifacts: v3's release discipline is kept verbatim (every tag has a Release object, notes
versioned in-tree, fail-closed release workflow).

## 6. Operator interface (the frustration fix)

The contract: **the operator sees decisions, progress, and alerts — never agentic internals.**

- **Interaction grammar.** Every operator-facing message is typed:
  - `DECISION` — needs input. Always: plain-language stakes (2–3 sentences, product vocabulary, no
    internal codenames), 2–4 labeled options with tradeoffs, a recommendation, and what happens next
    either way. One decision at a time; batched at natural attention moments.
  - `PROGRESS` — no action needed; three lines max; links to artifacts for depth.
  - `ALERT` — something broke or a lane was demoted; states impact first, cause second, action third.
- **Decision-ready queue.** Nothing surfaces until preparation is complete (artifact written, critiques
  attached, options formed). `/queue` shows what is waiting on the operator vs. progressing in
  background — the successor to `/gate-status`.
- **The fleet dashboard.** A live artifact (auto-updated by the digest routine) showing, per repo:
  missions and their gate states, PRs open/merged, CI health, lane autonomy levels, pending decisions,
  alerts. The operator glances at one page instead of reconstructing state from transcripts. The
  morning digest is a delta of this page, not a new prose genre.
- **Jargon is a defect.** A technically-correct read-out the operator has to reverse-engineer is treated
  as a failing output (v3 #30, promoted from norm to rule with the message-type templates above).
- **The artifact is canonical.** Summaries carry the standing footer: source artifact path, re-read
  before approving (v3 #7, kept).

This is enforced where it can be: the message templates ship as a skill the orchestrator must use for
gate presentations, and DECISION messages use AskUserQuestion structurally (options, not prose walls).

## 7. Fleet coordination (cross-repo)

Design goal: 3–4 concurrent repos with declared relationships, one operator, no polling loops, three
switchable operating modes, and a transversal knowledge layer agents can crawl.

### 7.1 The control repo

A small dedicated repo (working name: `fleet`) that every orchestrator session attaches
(`--add-dir`) and every routine can read. It contains:

- `fleet.yaml` — the manifest: repo list, produces/consumes edges (artifact → consumer), notification
  targets, shared invariant packs, and the current operating mode. The plugin validates consistency;
  the security sentinel uses the edges for seam-level review (§4).
- `INTENT.md` — the operator's living statement of goals, priorities, and preferences ("what I want").
  Operator-authored, no gates. Every `shaper` run and every DECISION presentation consults it
  (skill-enforced) — which also grounds operator-facing language in the operator's own vocabulary (§6).
- `index/` — the chronicle (§7.4).
- Cross-repo epic missions (contracts/plans that span repos) live here, not in any single repo.

### 7.2 Transport (resolved against what the platform verifiably ships)

- **Issues remain the durable ledger** (v3 #22 kept: provenance-linked issues, `dependencies` label,
  post-merge handoff sequence). Everything else is transport on top of this ledger — if the transport
  dies, the ledger still tells any session what is owed to whom.
- **Operator mode transport**: per-repo orchestrator sessions + the control repo + issues. No new
  machinery.
- **Automated mode transport**: **cloud routines with GitHub-event triggers** — a `dependencies` issue
  landing in a consuming repo triggers a routine that runs that repo's next step. Constraints accepted:
  research-preview status, ≥1h scheduled cadence, daily run caps, cloud-only.
- **Upgrade path**: a shared **coordination MCP server** (dogfooding our own gateway) exposing fleet
  state — task claims, artifact versions, sync-point status — to all sessions and routines. Adopted
  when issue-granularity coordination proves too coarse, not before.
- **Explicitly not load-bearing**: agent teams (experimental, single-repo, no session resume) and
  `--add-dir`-as-orchestration (file access, not coordination). Re-evaluate teams when they leave
  experimental status.

### 7.3 Operating modes

Declared in `fleet.yaml` (`mode:`), overridable per repo; changing it is a watched-lane change. Modes
differ in **who executes handoffs and how long the leash is — never in gate policy.** G1–G4 bind in
every mode.

| Mode | Handoffs | Leash |
| --- | --- | --- |
| `operator` (default) | Orchestrator files them; consuming repo acts when the operator's session picks them up | Decisions surface immediately; work pauses at gates |
| `auto-coordinate` | A fleet-coordinator routine (GitHub-triggered + scheduled sweep) dispatches the consuming repo's next step automatically, within that repo's lane autonomy | Gates still queue for the operator; everything below gate level flows unattended across repos |
| `epic` (night mode) | Declared **sync points** in an approved epic plan; reaching one files the handoff and continues independent tasks | Fully unattended within the epic's scope: contract + plan (incl. sync points) approved up front; night sandbox profile (default-deny egress, pre-approved allowlist); morning digest + dashboard report the result |

Entry to epic mode: `/epic <mission>` — refuses to start unless G1/G2 (and G3 where applicable) are
closed and the plan declares its cross-repo sync points and exit criteria. This is v3's `night-build`
reborn as: workflow scripts (process), sandbox profile (containment), routines (scheduling) — instead
of prose discipline.

### 7.4 The chronicle (transversal knowledge index)

Requirement: "index everything I have done across all repos so my agents can crawl what I know and
what I want."

- A scheduled **indexer routine** crawls every fleet repo (weekly + on demand): approach docs,
  contracts, ADRs, calibration logs, release notes, threat models, merged-PR summaries, open issues.
  It regenerates:
  - `index/<repo>.md` — current state, key decisions with dates, public API surface, open threads;
  - `index/topics/<topic>.md` — cross-cutting views spanning repos (e.g. `authz`, `federation`,
    `mcp-protocol`), which is where transversal knowledge actually lives.
- Format is deliberately **plain markdown**: grep-able, token-cheap, diff-reviewable. Agents Read the
  index instead of re-crawling repos; the index links back to canonical artifacts (P6: the index is a
  map, never the truth).
- `INTENT.md` is the "what I want" half; the chronicle is the "what I know/did" half. Together they are
  the standing context for shaping, decision presentation, and any new session's cold start.
- Optionally exposed through the coordination MCP server (§7.2) so non-Claude tools can query it.
- Auto memory (§9) stays personal scratch; the chronicle is the institution — same split as
  memory-vs-calibration-log.

## 8. Scheduled routines (replacing cron-workflow + agent hybrids)

| Routine | Cadence | Replaces |
| --- | --- | --- |
| digest + dashboard refresh | morning + on demand | `conductor` agent + GHA cron |
| docs audit | weekly | `doc-keeper` audit mode |
| security sentinel (repo) | monthly + on demand | — (new) |
| security sentinel (fleet seams) | monthly, offset | — (new) |
| chronicle indexer (§7.4) | weekly + on demand | — (new) |
| fleet coordinator (§7.3, `auto-coordinate` mode only) | GitHub-event + scheduled sweep | polling loops |
| dependency triage | weekly, post-cooldown | dependabot babysitting |
| deep verification (DST / capability evals) | nightly/weekly | nightly fuzz template |

## 9. Memory, calibration, learning

- **Auto memory** (per-project, platform-native) carries the orchestrator's working knowledge across
  sessions; subagent memory enabled for roles that benefit from accumulation (sentinel, adversaries).
- **The calibration log stays checked in** (team-visible, append-only, structured entries with
  confidence/scope/domain and the ≥2-recurrences promotion rule — v3 #34 kept verbatim). Memory is
  personal; the log is the institution.
- **Incident → eval** (§1.2) is the executable form of the loop that produced v2 and v3.

## 10. Distribution, and what a repo actually contains

The plugin (private marketplace, versioned) ships: agent definitions, workflow scripts, skills
(operator-interface templates, ci-watch, recovery procedures, invariant-review), hooks (lifecycle +
guards + the test-edit separation guard), CI templates, settings defaults (sandbox, permissions),
`fleet` tooling. Consuming repos pin a plugin version and upgrade by bump — the v3 "no migration path"
problem is dissolved.

A repo carries only: `CLAUDE.md` (<150 lines, judgment only), `.claude/rules/*.md` (path-scoped
conventions), `.claude/invariants/`, `docs/security/{threat-model,attack-surface}.md`,
`.claude/autonomy.yaml`, `fleet.yaml`, contracts/missions under `docs/`, and the calibration log.

Skills policy: built-ins and marketplace first, custom only for recurring + easy-to-get-wrong +
not-covered (v3 #32 kept). Concretely, from the current official marketplace:

- **Adopt now**: `gopls-lsp` (Go language server), `security-guidance` (in-edit vulnerability review —
  complements, does not replace, the sentinel), `github` (connector), `commit-commands`.
- **Evaluate**: `pr-review-toolkit`, `sentry` (if/when error monitoring lands), `agent-sdk-dev` (for the
  AI-app repos).
- **Gap confirmed by research**: no TDD/testing skill exists in the marketplace — our plugin authors its
  own `go-tdd` skill (table-driven + testify + race-detector discipline) and a path-scoped
  `rules/testing.md`; this is a distribution opportunity as much as a gap.

### Open items for the operator (decision-ready)

- **O-1** ~~Fleet transport~~ — resolved in §7.2: issues as ledger, routines as automated transport,
  coordination MCP server as the upgrade path; agent teams not load-bearing until stable.
- **O-2** ~~Plugin adoption~~ — resolved above.
- **O-3** Whether `core`-lane holdout verification runs per-PR (cost) or per-merge-queue-batch (cheaper,
  slightly later signal). Recommendation: per-batch, promote to per-PR on any lane demotion.
- **O-4** Chronicle store: plain markdown in the control repo (recommended start) vs. MCP-served
  database. Recommendation: markdown until query needs outgrow grep, then serve the same files via the
  coordination MCP server rather than migrating the store.
