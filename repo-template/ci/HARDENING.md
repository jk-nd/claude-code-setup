# CI hardening checklist

GitHub-side settings that can't ship as files, plus the two edits `ci.yml` needs before first use.
Ordered by leverage. Every item here is one you can actually perform — where a control needs a paid
tier or doesn't exist as a setting, that's stated rather than glossed.

## 0. Do these before the first PR that touches `.github/**`

Otherwise the `workflow-lint` lane fails on the template's own workflow and blocks `ci-pass`.

- [ ] Replace every `# PIN-BY-SHA` marker in `ci.yml` with a commit SHA (`gh api
      repos/actions/checkout/commits/v4 --jq .sha`). Tag refs are mutable; a SHA is not.
- [ ] Set `ZIZMOR_VERSION` in `ci.yml`'s `env:` block to a released version. It is intentionally
      empty: an unpinned `pipx run` fetch is exactly the supply-chain shape this job exists to
      catch, so the job fails loudly rather than silently executing whatever PyPI serves.
- [ ] After pinning, tighten `zizmor --min-severity=high` to `medium`.

## 1. Enforcement

- [ ] **Branch protection / ruleset on `main`**: require the `ci-pass` check, require PRs, no force
      pushes. Enable the **merge queue** — the full suite and the acceptance suite run there, while
      PRs run only affected packages.
- [ ] **Watched-path human review.** `ci.yml`'s `watched-approval` job fails closed unless a human
      who is not the PR author has approved. It uses only `github.token` and needs no extra setup —
      this is the concrete form of "agent PRs on sensitive paths need a human", implemented rather
      than delegated to an action you'd have to go find. Solo operator: you approve your agents'
      PRs; nothing lets an agent satisfy it.
- [ ] **CODEOWNERS** at the repo root covering workflows, `go.mod`, and your crypto/consensus paths,
      with required review from code owners. Note GitHub honors CODEOWNERS at three locations —
      root, `.github/`, and `docs/` — all three are in `ci.yml`'s watched regex for that reason.
- [ ] **Push ruleset restricting `.github/workflows/**`** — real enforcement, since a checking
      workflow can itself be edited in the PR that changes it. *Requires an organization on a paid
      plan*; unavailable on personal repos. On a personal repo the CODEOWNERS + `watched-approval`
      pair above is the fallback, and it is weaker: it gates review, not the push.
- [ ] **Extend the watched regex** in `ci.yml`'s `classify` job with this repo's sensitive paths
      (crypto, consensus, authz). It ships covering only workflows, CODEOWNERS, and Go module
      files — per-repo paths are a hand edit today.

## 2. Trust separation

- [ ] No job that reads untrusted content (PR bodies, fork heads, caches written by untrusted
      triggers) may also hold `id-token: write` or repo-write. Keep `permissions: contents: read` as
      the workflow default and escalate per job — `ci.yml` does this.
- [ ] `persist-credentials: false` on every checkout (set in the template) so the job's git config
      doesn't carry a usable token into anything the workflow runs.
- [ ] Never check out a PR head under `pull_request_target`. If you need fork-PR handling, run the
      untrusted code in a job with no secrets and no write permission.
- [ ] Don't restore base-branch cache keys on fork PRs — a poisoned cache entry is executable input.
      (There is no "read-only cache" setting; scope your cache keys and use `lookup-only` where the
      job only needs a hit/miss.)

## 3. Supply chain

- [ ] Dependabot with a cooldown (3 days patch/minor, longer for majors) so a compromised release
      isn't merged within the hour.
- [ ] Treat a `toolchain` directive change as watched — `classify` already detects it in `go.mod`
      and `go.work` by diffing the directive line, because CODEOWNERS is path-scoped and would
      otherwise gate every dependency bump to catch this one case.
- [ ] Pin the linter *binary*, not just the action (`version:` in `golangci-lint-action`). Pinning
      the action does not pin what it downloads.
- [ ] Release builds: artifact attestations, verified with `gh attestation verify` at deploy.

## 4. Deployment (services)

- [ ] Feature flags + canary + metric-driven rollback for anything user-facing. Merge velocity is
      only safe when production exposure is progressive and reversible.
