# Plan mission: <feature slug>

> Living artifact. Owned by `planner`. Updated by `implementer` (status, discovered constraints) and `plan-reviewer` (second opinions) as work proceeds. Read by `conductor` for the morning digest.

| Field        | Value                                                              |
| ------------ | ------------------------------------------------------------------ |
| Status       | `draft` / `under-review` / `approved` / `in-progress` / `done` / `paused` |
| Owner        | orchestrator                                                       |
| Created      | YYYY-MM-DD                                                         |
| Last updated | YYYY-MM-DD HH:MM (auto-stamped)                                    |
| Spec         | `docs/specs/<slug>.md`                                             |
| Approach     | `docs/approaches/<slug>.md`                                        |
| Issue        | `#NNN` (if any)                                                    |

## Outcome

One paragraph. What shipping this mission means in terms of user/operator-observable behavior. NOT code structure.

## Approach summary

Two or three sentences from the approved approach doc. Why this shape, not the alternatives.

## Task graph

Tasks in dependency order. Status markers: `[ ]` pending, `[~]` in-progress, `[x]` done, `[d]` deferred, `[?]` blocked-by-question.

**Ticket-size norm: ~50–200 LoC per task.** Tasks projected over 200 LoC must be split unless `planner` explicitly justifies why the work is atomic. See AGENTS.md operating clarification #17. The implementer fleet absorbs 5–10 small tasks in parallel; 2–3 large ones serialise regardless of worktree availability.

### Ready to dispatch now

(Updated by the orchestrator after every merge. Lists tasks whose dependencies are immediately satisfied so the next orchestrator turn can fan out implementers in one batch — per AGENTS.md operating clarification #18.)

- T<N>, T<M>, T<K>: ready when T<dep> merges.


- [ ] **T1: <title>** — owner: `implementer`. Spec § *NN*. Blockers: none.
  - Files (expected): `internal/foo/bar.go`, `internal/foo/bar_test.go`
  - Acceptance: `TestProcess_*` in `internal/foo/bar_test.go` pass.
- [ ] **T2: <title>** — owner: `implementer`. Spec § *NN*. Blockers: T1.
  - Files (expected): `internal/foo/baz.go`
  - Acceptance: `TestBaz_*` pass; integration `TestFooEnd2End` covers T1 + T2.
- [ ] **T3 (parallel): <title>** — owner: `implementer`. Spec § *NN*. Blockers: none.
  - Files (expected): `internal/bar/bar.go`
  - Acceptance: `TestBar_*` pass.
- [ ] **T4 (doc): <title>** — owner: `doc-keeper`. Blockers: T1–T3.
  - Files (expected): `README.md`, `docs/operating.md`
  - Acceptance: README usage section updated to new API; `docs/operating.md` lists the new flag.

Tag tasks `[compliance]` if they touch `WATCHED_PATHS` (see `.github/workflows/trust-boundary.yml`). Those PRs will require human label/approval at merge.

## Tests-from-spec

Path(s): `internal/foo/bar_test.go`, `internal/foo/baz_test.go`. Written by `test-author` before any T-N implementation. Must be **red** at start and turn green per task. Implementation must not modify these tests except where the spec evolves.

## Second opinion: gemini

(Appended by `plan-reviewer`. The orchestrator and other subagents must NOT edit this section.)

## Second opinion: opus

(Same — appended by `plan-reviewer`.)

## Open questions

Things the orchestrator paused on. The user is the answerer. Each entry: who/when/what.

- [ ] **Q1:** <question> — discovered YYYY-MM-DD by `<subagent>` during T<N>. Mission paused at T<N> until answered.

## Discovered constraints

Append-only log of things execution revealed that the plan didn't predict. Format: `YYYY-MM-DD HH:MM, T<N>: <observation>. Plan adjustment: <what changed>.`

- YYYY-MM-DD HH:MM, T2: `implementer` found `foo.Bar()` is called from `internal/baz`, requiring a deprecation shim. Plan adjusted: added T2a (shim) before T2.

## Out of scope

Reiterated from the spec / approach. Things this mission explicitly does NOT do.

- ...

## On completion

When the last task is `[x]`, all tests pass, CI is green, `adversary` returned pass, and the PR(s) merged:

- `conductor` posts the close-out digest.
- This file is moved to `docs/plan-missions/done/<slug>.md`.
- Any open `doc-stale` issues created during the mission are linked in the digest.
