#!/usr/bin/env python3
"""context-budget.py — audit how much model context the shipped agent-harness
surface consumes, so the template (and downstream repos) can keep it lean as
agents, skills, rules, and hooks accumulate.

Token counts are *approximate* (chars / 4 — a standard rough heuristic); the
point is relative size and trend, not exactness. Stdlib only.

    python3 scripts/context-budget.py            # human report
    python3 scripts/context-budget.py --json      # machine-readable
    python3 scripts/context-budget.py --warn-file 2500
    python3 scripts/context-budget.py --max-total 60000   # exit 1 if exceeded

Exit 0 normally; exit 1 only if a --max-* threshold is exceeded.
"""
from __future__ import annotations
import argparse
import glob
import json
import os

# (label, glob, when it's loaded)
SURFACES = [
    ("operating-contract", ["AGENTS.md"], "always (orchestrator)"),
    ("agents", [".claude/agents/*.md"], "on dispatch (description always surfaced)"),
    ("skills", [".claude/skills/*/SKILL.md"], "on trigger (description always surfaced)"),
    ("invariants", [".claude/invariants/*.md"], "on demand"),
    ("commands", [".claude/commands/*.md"], "on invocation"),
    ("rules", [".claude/rules/*.md"], "varies"),
    ("docs", ["docs/*.md"], "on demand"),
]


def est_tokens(path: str) -> int:
    try:
        return (len(open(path, encoding="utf-8").read()) + 3) // 4
    except Exception:
        return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--warn-file", type=int, default=3000,
                    help="flag a single file above this many tokens (default 3000)")
    ap.add_argument("--max-total", type=int, default=0,
                    help="exit 1 if the grand total exceeds this (0 = no gate)")
    ap.add_argument("--max-file", type=int, default=0,
                    help="exit 1 if any single file exceeds this (0 = no gate)")
    args = ap.parse_args()

    report = []
    grand = 0
    over_file = []
    for label, globs, when in SURFACES:
        files = sorted({f for g in globs for f in glob.glob(g)})
        items = [(f, est_tokens(f)) for f in files]
        subtotal = sum(t for _, t in items)
        grand += subtotal
        report.append({"surface": label, "when": when, "tokens": subtotal,
                       "files": [{"path": f, "tokens": t} for f, t in items]})
        for f, t in items:
            if t >= args.warn_file:
                over_file.append((f, t))
            if args.max_file and t > args.max_file:
                over_file.append((f, t))

    if args.json:
        print(json.dumps({"total_tokens": grand, "surfaces": report}, indent=2))
    else:
        print("Context-budget audit (approximate tokens, chars/4)\n")
        for s in report:
            if not s["files"]:
                continue
            print(f"  {s['surface']:18} ~{s['tokens']:>7,} tok   [{s['when']}]")
            for fi in sorted(s["files"], key=lambda x: -x["tokens"]):
                mark = "  <-- large" if fi["tokens"] >= args.warn_file else ""
                print(f"      {fi['tokens']:>6,}  {fi['path']}{mark}")
        print(f"\n  {'TOTAL':18} ~{grand:>7,} tok")
        if over_file:
            print(f"\n  {len(set(over_file))} file(s) over {args.warn_file} tokens — consider trimming or splitting.")

    failed = False
    if args.max_total and grand > args.max_total:
        print(f"\ncontext-budget: FAIL — total {grand} > --max-total {args.max_total}")
        failed = True
    if args.max_file and any(t > args.max_file for _, t in over_file):
        print(f"context-budget: FAIL — a file exceeds --max-file {args.max_file}")
        failed = True
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
