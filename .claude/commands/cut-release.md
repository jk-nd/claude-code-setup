---
description: Cut a release the invariant way — versioned notes file in-tree, release PR, tag, GitHub Release object.
argument-hint: [version, e.g. v1.2.3]
---

You are the orchestrator. Cut release **$ARGUMENTS** per AGENTS.md clarification #25 (every tag has a Release object; notes are version-controlled).

1. Confirm the version and what substantive change ships with it (a fix, feature, or vendored-patch bump). Pick the next semver if not given.
2. Open a **release PR** titled `release: $ARGUMENTS`. Its diff includes `docs/releases/$ARGUMENTS.md` (the notes) **alongside** the substantive change. Route doc work through `doc-keeper`.
3. Merge to `main` per the merge policy.
4. Tag the merge commit and push: `git tag -a $ARGUMENTS -m "$ARGUMENTS" && git push origin $ARGUMENTS`.
5. `release.yml` fires: it builds artifacts and creates the GitHub Release with the body from `docs/releases/$ARGUMENTS.md`. `make_latest: true` unless the tag has a `-pre`/`-rc`/`-alpha`/`-beta` suffix.

Never push a tag without a matching `docs/releases/<tag>.md` in the tree first — `release.yml` fails closed on that, by design.
