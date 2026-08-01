# Installing groundwork (v4)

## Get the setup

```bash
git clone -b v4 git@github.com:jk-nd/claude-code-setup.git ~/code/groundwork   # any path you like
export GW=~/code/groundwork                                                    # put this in your shell rc
# update later: git -C "$GW" pull
```

The plugin loads per launch via `claude --plugin-dir "$GW/plugin"` — make it an alias:

```bash
alias cc='claude --plugin-dir "$GW/plugin"'
```

(Once stable, publish `plugin/` to a private marketplace and pin a version per repo instead —
`README.md` § Install. The `--plugin-dir` flag is the pilot path; `git pull` is the update path.)

## A. New repo

```bash
cd my-new-repo && git init
cp -r "$GW/repo-template/." .
mkdir -p .github/workflows && mv ci/ci.yml .github/workflows/ci.yml   # scripts stay in ci/
```

Then:

1. **CLAUDE.md** — fill in the "Environment facts" section (build/test/lint/run commands, pointers).
   Keep the behavioral rules section as-is; extend only after an `/ablation`-style measurement.
2. **`.claude/settings.json`** — adjust the Bash allowlist to the repo's stack (template is Go).
3. **GitHub side** — walk `ci/HARDENING.md` top to bottom (branch protection + `ci-pass` required
   check + merge queue first; push rulesets on workflows; watched-path review).
4. **Invariants** — keep `fail-closed.md`, add area files as the repo grows sensitive surfaces.
5. **Local tripwire** — `ln -sf ../../ci/pre-commit.sh .git/hooks/pre-commit`. The PreToolUse guard
   matches the Edit/Write *tools*, so a shell redirect, `sed -i`, another editor, or another agent
   slips past it; a commit hook sees the staged tree however the change arrived. Both use the same
   escape: `GW_ALLOW_CONFIG_EDIT=1`.
6. **Non-Go repos** — `ci/` ships impact-analysis scripts for three stacks: `affected-go-tests.sh`,
   `affected-ts-tests.sh` (vitest / jest), `affected-py-tests.sh` (pytest-testmon). Point the
   `test` job in `.github/workflows/ci.yml` at the one you need and delete the others. Each falls
   back to the full suite whenever it cannot determine impact soundly — a slow job beats a green
   one that skipped the failing test.
7. Start: `cc` in the repo. Try `/groundwork:ship <small feature>` as the shakedown.

## B. Existing repo with the v3 setup

Remove first, then copy — the v3 leftovers' main cost is context weight loaded into every session.

**Delete** (git history preserves everything):

```bash
# --ignore-unmatch on every line: without it, ONE missing path aborts the whole command and
# removes nothing — silently leaving the context weight this step exists to delete.
git rm -r --ignore-unmatch .claude/agents .claude/skills .claude/commands .claude/hooks
git rm --ignore-unmatch AGENTS.md .claude/settings.json   # AGENTS.md loads into EVERY session
git rm -r --ignore-unmatch docs/templates scripts/second-opinion.py scripts/context-budget.py
```

**Keep and carry over:**

| v3 asset | v4 home |
| --- | --- |
| `docs/research/agent-team-calibration.md` | keep as `docs/calibration.md` — append-only history is the point |
| `.claude/invariants/*` | move to `invariants/`; add a "default verdict on uncertainty" line per file |
| In-flight plan-missions | finish under old habits or convert remaining tasks to GitHub issues; no new ones |
| `trust-boundary.yml`, CODEOWNERS, branch protection | untouched — reconcile against `ci/HARDENING.md` |
| `WATCHED_PATHS` notion | lives on as the `watched` class in `.github/workflows/ci.yml` + CODEOWNERS |

**Then copy the template.** `cp -r` **overwrites**, so preserve anything you're keeping first:

```bash
[ -f CLAUDE.md ] && cp CLAUDE.md CLAUDE.md.v3           # keep your facts; merged back below
[ -d invariants ] && cp -r invariants invariants.v3
cp -rn "$GW/repo-template/." .                          # -n: never clobber what already exists
mkdir -p .github/workflows && mv -n ci/ci.yml .github/workflows/ci.yml
```

Merge your old repo-specific facts from `CLAUDE.md.v3` into the new CLAUDE.md's Environment facts
(then delete the `.v3` copies);
re-add repo-specific permission allows to `.claude/settings.json`. Replace v3's `ci.yml` job shape
with the new change-class router (or graft the `classify`/`ci-pass` pattern into your existing
workflow if it carries repo-specific jobs).

## C. Fleet (optional, for multi-repo work)

```bash
git init ~/code/fleet && cp -r "$GW/fleet-template/." ~/code/fleet/
```

Fill in `fleet.yaml` — repos as GitHub `owner/name` plus their produces/consumes edges — and
`INTENT.md` (your goals and standing preferences, operator-authored). `fleet.yaml` is deliberately
machine-independent: **no local clone paths**, because coordination runs on GitHub issues keyed on
`owner/name`, and committed paths conflict across machines. If a session needs to reach a sibling
repo's files directly, copy `fleet.local.yaml.example` to `fleet.local.yaml` (gitignored) and put
paths there.

Attach the fleet repo to sessions with `cc --add-dir ~/code/fleet`, then run
`/groundwork:chronicle` once to seed `index/`.

## Verify the install

- `cc` → the session opens knowing your branch, uncommitted count, and any open stashes
  (injected by the SessionStart hook).
- `/groundwork:` tab-completes to ship / fix / sentinel / ablation / chronicle.
- Ask the agent to *edit* `acceptance/` or `.golangci.yml` (an Edit/Write call, not a shell
  redirect — the guard matches tools, not command strings): it is **blocked**. Escape hatch is
  `GW_ALLOW_CONFIG_EDIT=1` exported when launching the session, not per command.
- A docs-only PR runs only the classify job; a Go change runs affected-package tests.
- `echo x >> acceptance/<any>_test.go && git add -A && git commit` is **refused** by the pre-commit
  hook (this is the path the PreToolUse guard cannot see).
- `ci/eval-harness.sh` prints the harness's always-resident context cost and any prose that
  duplicates a mechanism — the input to `/groundwork:ablation`.

## Updating

`git -C "$GW" pull` — plugin changes apply on the next `claude` launch. Files copied from
`repo-template/` are repo-owned after install: diff against the template when pulling
(`git -C "$GW" log --stat repo-template/`) and adopt changes deliberately.
