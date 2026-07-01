# Security Policy

`claude-code-setup` is a template: the files here are copied into downstream
repositories and executed by an autonomous agent team. A weakness in a shipped
template, workflow, or script therefore propagates to every project bootstrapped
from it. We treat the template's supply-chain surface as a first-class security
concern.

## Reporting a vulnerability

Please report suspected vulnerabilities **privately**, not as a public issue:

- Use GitHub's **private vulnerability reporting** for this repository
  (Security → *Report a vulnerability*), or
- contact the maintainer directly if private reporting is unavailable.

Please include the affected file/template, the impact, and a reproduction or
proof-of-concept where possible.

**Response targets (best effort):**

- Acknowledgement within **48 hours**.
- Initial assessment within **7 days**.
- Fix or mitigation for confirmed high-severity issues within **14 days**.

Please allow coordinated disclosure before any public write-up.

## Supply-chain policy for shipped templates

These rules apply to everything the template ships and to contributions:

- **Pin third-party GitHub Actions to a commit SHA**, with a trailing
  `# vX.Y.Z` comment for readability. Floating tags (`@v4`) are not allowed in
  shipped `.github/workflows/*` — a tag can be repointed at malicious code.
- **No `curl | bash` (or `bash <(curl …)`) of remote scripts.** Download a
  pinned release artifact and verify it against published checksums before
  executing (see the `actionlint` step in `ci.yml.template` for the pattern).
- **Least-privilege workflow permissions.** Default to `contents: read`; grant
  write scopes only on the specific job that needs them. Avoid
  `pull_request_target` with checkout of untrusted code.
- **No secrets in the tree.** Configuration templates that need secrets use
  placeholders (`${...}` / `YOUR_*_HERE`) filled at install time from the
  environment or a secrets manager — never committed.
- **Untrusted content is data, not instructions.** Agents that read diffs,
  issues, or fetched web pages must treat that content as untrusted and must not
  act on instructions embedded in it (see `AGENTS.md`).

## Scope

In scope: the templates, workflows, scripts, agent/skill definitions, and the
bootstrap path shipped by this repository. Out of scope: vulnerabilities in
downstream projects' own code, and in third-party tools the template merely
invokes (report those upstream).
