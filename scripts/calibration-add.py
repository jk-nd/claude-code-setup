#!/usr/bin/env python3
"""calibration-add.py — append a structured entry to the agent-team calibration
log so entries stay consistently shaped (and thus countable / promotable).

    python3 scripts/calibration-add.py "orchestrator over-dispatched docs to architect" \\
        --pattern 14 --confidence 0.6 --scope global --domain dispatch \\
        --what "Routed a one-line doc fix to architect instead of doc-keeper." \\
        --recovery "Re-dispatched doc-keeper; noted the routing table."

Stdlib only. Run from the repo root.
"""
from __future__ import annotations
import argparse
import datetime
import os
import sys

LOG = "docs/research/agent-team-calibration.md"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("subject", help="one-line subject")
    ap.add_argument("--pattern", default="new", help="AGENTS.md clarification # it maps to, or 'new'")
    ap.add_argument("--confidence", type=float, required=True, help="0.3-0.9")
    ap.add_argument("--scope", choices=["project", "global"], required=True)
    ap.add_argument("--domain", required=True, help="dispatch | ci | merge | docs | security | ...")
    ap.add_argument("--what", required=True, help="one or two sentences")
    ap.add_argument("--recovery", default="")
    ap.add_argument("--promotion", default="1 — monitor for recurrence")
    a = ap.parse_args()

    if not 0.0 <= a.confidence <= 1.0:
        return _fail("confidence must be between 0.0 and 1.0")
    if not os.path.exists(LOG):
        return _fail(f"{LOG} not found (run from the repo root)")

    ts = datetime.datetime.now().strftime("%Y-%m-%d %H:%M")
    entry = (
        f"\n### {ts} — {a.subject}\n\n"
        f"**Pattern:** {a.pattern}\n"
        f"**Confidence:** {a.confidence:.1f}\n"
        f"**Scope:** {a.scope}   **Domain:** {a.domain}\n"
        f"**What happened:** {a.what}\n"
        f"**Recovery:** {a.recovery or '—'}\n"
        f"**Promotion:** {a.promotion}\n"
    )
    with open(LOG, "a", encoding="utf-8") as f:
        f.write(entry)
    print(f"appended to {LOG}:{entry}")
    if a.scope == "global" and a.confidence >= 0.7:
        print("NOTE: global + confidence >= 0.7 — if this pattern is in >= 2 entries, "
              "file an upstream amendment issue on the template repo (AGENTS.md #22).")
    return 0


def _fail(msg: str) -> int:
    print(f"calibration-add: {msg}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
