# Invariants: GitHub Actions workflow hardening

**Area:** `.github/workflows/**` and composite/reusable actions.

**Default verdict on uncertainty:** if the diff doesn't let you prove an
invariant holds, mark CANNOT-VERIFY and treat it as a finding. Supply-chain is
fail-closed (see `SECURITY.md`).

Apply this checklist (via the `domain-adversary-checklist` skill) whenever a
diff touches a workflow.

## Invariants

1. **Third-party actions are pinned to a commit SHA**, not a floating tag
   (`uses: owner/repo@<40-hex> # vX.Y.Z`). A movable tag can be repointed at
   malicious code. First-party `actions/*` are still pinned.

2. **No `curl | bash` / `bash <(curl …)`** of a remote script. Remote artifacts
   are downloaded at a pinned version and checksum-verified before execution.

3. **Least-privilege `permissions`.** The workflow (or job) declares an explicit
   `permissions:` block defaulting to `contents: read`; write scopes are granted
   only on the specific job that needs them. No unscoped `write-all`.

4. **No untrusted checkout with elevated trust.** `pull_request_target` (or
   `workflow_run`) must not check out and execute PR-author code with access to
   secrets. If it does, that is a finding.

5. **No script injection via `${{ … }}` interpolation in `run:`.** Untrusted
   context (`github.event.*.title`, `.body`, `.head_ref`, comment text) is not
   interpolated directly into a shell `run:` block — it is passed via `env:` and
   referenced as a quoted shell variable.

6. **Secrets are not echoed or written to logs/artifacts**, and not passed to
   untrusted steps.

## How a violation looks

- `uses: some/action@v1` (tag, not SHA).
- `run: bash <(curl -sSfL https://…)`.
- `permissions: write-all` or a missing permissions block on a privileged job.
- `run: echo "${{ github.event.pull_request.title }}"` (direct interpolation).
- `pull_request_target` + `actions/checkout` of `head.ref` + a build/test step.
