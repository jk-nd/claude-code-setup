#!/usr/bin/env python3
"""validate.py — self-validation for a claude-code-setup repo.

Checks that the template's own machine-read artifacts are well-formed, so a
malformed agent/skill/hook file, a broken cross-reference, a leaked personal
path, or a dangerous invisible-unicode payload is caught in CI rather than at
runtime. Stdlib only; run from the repo root:

    python3 scripts/validate.py

Exit code 0 if all checks pass, 1 otherwise.
"""
from __future__ import annotations
import glob
import os
import re
import subprocess
import sys

ERRORS: list[str] = []
WARNINGS: list[str] = []


def err(msg: str) -> None:
    ERRORS.append(msg)


def warn(msg: str) -> None:
    WARNINGS.append(msg)


def frontmatter(path: str) -> dict | None:
    """Parse a leading --- frontmatter block (flat key: value)."""
    text = open(path, encoding="utf-8").read()
    m = re.match(r"^---\n(.*?)\n---\n", text, re.S)
    if not m:
        return None
    fm: dict[str, str] = {}
    for line in m.group(1).splitlines():
        if ":" in line and not line.lstrip().startswith("#"):
            k, _, v = line.partition(":")
            fm[k.strip()] = v.strip()
    return fm


KNOWN_TOOLS = {
    "Read", "Grep", "Glob", "Bash", "Write", "Edit", "MultiEdit",
    "WebFetch", "WebSearch", "NotebookEdit", "Task", "TodoWrite",
}
KNOWN_MODELS = {"opus", "sonnet", "haiku"}


def check_agents() -> None:
    files = sorted(glob.glob(".claude/agents/*.md"))
    if not files:
        warn("no .claude/agents/*.md found")
    for f in files:
        fm = frontmatter(f)
        if fm is None:
            err(f"{f}: missing frontmatter")
            continue
        for key in ("name", "description", "tools", "model"):
            if not fm.get(key):
                err(f"{f}: missing frontmatter key '{key}'")
        if fm.get("model") and fm["model"].split("-")[0] not in KNOWN_MODELS:
            warn(f"{f}: unrecognised model '{fm['model']}'")
        for t in (fm.get("tools", "")).replace("[", "").replace("]", "").split(","):
            t = t.strip().strip('"').strip("'")
            if t and t not in KNOWN_TOOLS:
                warn(f"{f}: unrecognised tool '{t}'")


def check_skills() -> None:
    for f in sorted(glob.glob(".claude/skills/*/SKILL.md")):
        fm = frontmatter(f)
        if fm is None:
            err(f"{f}: missing frontmatter")
            continue
        for key in ("name", "description"):
            if not fm.get(key):
                err(f"{f}: missing frontmatter key '{key}'")
        for sh in glob.glob(os.path.join(os.path.dirname(f), "*.sh")):
            if not os.access(sh, os.X_OK):
                err(f"{sh}: bundled skill script is not executable (chmod +x)")


def check_hooks() -> None:
    for f in sorted(glob.glob(".claude/hooks/*.sh")):
        if not os.access(f, os.X_OK):
            err(f"{f}: hook script is not executable (chmod +x)")
        if "set -uo pipefail" not in open(f, encoding="utf-8").read():
            warn(f"{f}: hook script does not 'set -uo pipefail'")


def slugify(text: str) -> str:
    return "#" + re.sub(r"[^\w\s-]", "", text.strip().lower()).replace(" ", "-")


def check_anchors() -> None:
    for f in ["AGENTS.md", "README.md"] + sorted(glob.glob("docs/**/*.md", recursive=True)):
        if not os.path.exists(f):
            continue
        text = open(f, encoding="utf-8").read()
        slugs = {slugify(m.group(2)) for m in re.finditer(r"^(#{1,6})\s+(.*)$", text, re.M)}
        for link in re.findall(r"\]\((#[^)]+)\)", text):
            if link not in slugs:
                err(f"{f}: in-page link {link} resolves to no header")


def tracked_text_files() -> list[str]:
    """Tracked text files on the agent-harness surface only — not the
    downstream project's own application code (which may legitimately contain
    these patterns)."""
    try:
        out = subprocess.run(["git", "ls-files"], capture_output=True, text=True).stdout
    except Exception:
        return []
    exts = (".md", ".sh", ".py", ".json", ".yml", ".yaml", ".txt", ".template")
    surface = (".claude/", "docs/", "scripts/", "templates/", ".github/")
    files = []
    for p in out.splitlines():
        if not p.endswith(exts):
            continue
        if p.startswith(surface) or ("/" not in p and p.endswith(".md")):
            files.append(p)
    return files


def check_personal_paths() -> None:
    pat = re.compile(r"/(Users|home)/[A-Za-z0-9._-]+/")
    for f in tracked_text_files():
        try:
            for i, line in enumerate(open(f, encoding="utf-8"), 1):
                if pat.search(line):
                    err(f"{f}:{i}: leaked personal path: {line.strip()[:80]}")
        except Exception:
            pass


# Dangerous invisible / bidi-control code points (NOT normal punctuation such
# as em-dashes or accented letters). Built from code points so this source file
# contains no invisible characters itself.
_BAD = (
    list(range(0x200B, 0x2010))   # zero-width space .. RLM
    + list(range(0x202A, 0x202F))  # bidi embeddings / overrides
    + list(range(0x2060, 0x2065))  # word joiner .. invisible plus
    + list(range(0x2066, 0x206A))  # bidi isolates
    + [0xFEFF]                     # BOM / zero-width no-break space
)
INVISIBLE = re.compile("[" + "".join(chr(c) for c in _BAD) + "]")


def check_unicode() -> None:
    for f in tracked_text_files():
        try:
            for i, line in enumerate(open(f, encoding="utf-8"), 1):
                m = INVISIBLE.search(line)
                if m:
                    err(f"{f}:{i}: dangerous invisible/bidi char U+{ord(m.group()):04X}")
        except Exception:
            pass


def main() -> int:
    for name, fn in [
        ("agents", check_agents), ("skills", check_skills), ("hooks", check_hooks),
        ("anchors", check_anchors), ("personal-paths", check_personal_paths),
        ("unicode-safety", check_unicode),
    ]:
        before = len(ERRORS)
        fn()
        status = "FAIL" if len(ERRORS) > before else "ok"
        print(f"  [{status}] {name}")
    for w in WARNINGS:
        print(f"  warning: {w}")
    if ERRORS:
        print(f"\nvalidate: {len(ERRORS)} error(s):")
        for e in ERRORS:
            print(f"  - {e}")
        return 1
    print(f"\nvalidate: OK ({len(WARNINGS)} warning(s)).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
