---
description: Show what is waiting on a user decision — pending gates, in-flight missions, and open PRs.
---

You are the orchestrator. Report what currently needs the user, and what is progressing without them. Gather and summarise:

1. **Pending user gates** — any mission stopped at approach / spec / plan-mission, and any **watched-path PR** waiting for a compliance label/approval (these are the only points that need the user — clarification: "Where the human is in the loop").
2. **In-flight missions** — for each plan-mission under `docs/plan-missions/` (not `done/`): tasks open / in-progress / done, and the current blocking step.
3. **Open PRs** — state of `adversary`, CI, and trust-boundary for each.
4. **Anything stuck** — agents past their expected duration (clarification #24), or stashes/uncommitted work left behind (#27).

Present the user-blocking items first and plainly (#30). If nothing needs the user, say so in one line and list what's progressing in the background.
