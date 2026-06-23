#!/usr/bin/env bash
#
# prune-worktrees.sh — safe hygiene for agent dispatch worktrees and their
# ephemeral branches. DRY-RUN by default; pass --apply to actually delete.
#
# Part of the `prune-worktrees` skill. See SKILL.md.
#
# What it does:
#   1. `git worktree prune` (drop records for worktrees whose dirs are gone).
#   2. Write a recovery MANIFEST (branch, tip SHA, date, subject) for every
#      matching ephemeral branch BEFORE deleting anything — so a wrongly
#      deleted branch is recoverable (the SHA stays reachable via reflog /
#      `git fsck` and the manifest names it).
#   3. Delete matching branches that are safe to remove. It NEVER touches:
#        - a branch checked out in a live worktree that is dirty or unmerged
#          (in-flight work — left and reported),
#        - co-tenant branches (`codex/*`),
#        - anything outside the ephemeral prefix.
#
# Usage:
#   prune-worktrees.sh [--apply] [--prefix worktree-agent-] [--base origin/main]
#
# Defaults: prefix=worktree-agent-   base=origin/main (fallback: main)
#
# Exit codes: 0 ok (incl. dry-run), 2 usage/environment error.
#
set -uo pipefail

APPLY=0
PREFIX="worktree-agent-"
BASE=""

die() { echo "prune-worktrees: $*" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --apply)   APPLY=1; shift ;;
    --prefix)  PREFIX="${2:?--prefix needs a value}"; shift 2 ;;
    --base)    BASE="${2:?--base needs a value}"; shift 2 ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)         die "unknown arg: $1" ;;
  esac
done

command -v git >/dev/null 2>&1     || die "git not found"
command -v python3 >/dev/null 2>&1 || die "python3 not found"
git rev-parse --git-dir >/dev/null 2>&1 || die "not a git repository"

if [ -z "$BASE" ]; then
  if   git rev-parse --verify -q origin/main >/dev/null; then BASE="origin/main"
  elif git rev-parse --verify -q main        >/dev/null; then BASE="main"
  else die "no origin/main or main to judge 'merged' against; pass --base"
  fi
fi

# Refuse an empty prefix: it would make every branch a deletion candidate.
[ -n "$PREFIX" ] || die "refusing an empty --prefix (it would match every branch)"

CURRENT=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")

echo "prune-worktrees: prefix='$PREFIX' base='$BASE' mode=$([ $APPLY -eq 1 ] && echo APPLY || echo DRY-RUN)"

# 1. Drop dangling worktree records up front.
git worktree prune

# Manifest path lives inside .git (not the work tree, so it never pollutes a diff).
ts=$(date +%Y%m%d-%H%M%S)
manifest_dir="$(git rev-parse --git-dir)/prune-manifests"
mkdir -p "$manifest_dir"
manifest="$manifest_dir/prune-$ts.txt"

# 2 + 3. Analysis in python3 (portable; avoids bash-version array quirks).
# The human-readable report goes to stderr; the machine plan (DELETE lines)
# goes to stdout so the apply step below can consume it.
plan=$(PREFIX="$PREFIX" BASE="$BASE" MANIFEST="$manifest" CURRENT="$CURRENT" python3 <<'PY'
import os, subprocess, sys

prefix = os.environ["PREFIX"]
base = os.environ["BASE"]
manifest_path = os.environ["MANIFEST"]
current = os.environ.get("CURRENT", "")
base_short = base.rsplit("/", 1)[-1]
never = {b for b in (current, base, base_short) if b}

def git(*args):
    return subprocess.run(["git", *args], capture_output=True, text=True)

# branch -> live worktree path
branch_path, cur = {}, None
for line in git("worktree", "list", "--porcelain").stdout.splitlines():
    if line.startswith("worktree "):
        cur = line[len("worktree "):]
    elif line.startswith("branch refs/heads/"):
        branch_path[line[len("branch refs/heads/"):]] = cur
    elif line == "":
        cur = None

branches = [b for b in git("for-each-ref", "--format=%(refname:short)",
                           f"refs/heads/{prefix}*").stdout.splitlines() if b]

def is_merged(b):
    return git("merge-base", "--is-ancestor", b, base).returncode == 0

def is_dirty(path):
    return bool(path and os.path.isdir(path)
                and git("-C", path, "status", "--porcelain").stdout.strip())

protected, removable, manifest_lines = [], [], []
for b in branches:
    if b in never:
        protected.append(f"{b} (base/current branch; never touched)")
        continue
    if b.startswith("codex/"):
        protected.append(f"{b} (co-tenant; never touched)")
        continue
    sha = git("rev-parse", "--short", b).stdout.strip()
    subj = git("log", "-1", "--format=%s", b).stdout.strip()
    bdate = git("log", "-1", "--format=%ci", b).stdout.strip()
    manifest_lines.append(f"{b}\t{sha}\t{bdate}\t{subj}")
    path = branch_path.get(b)
    if path:
        if is_dirty(path):
            protected.append(f"{b} (live worktree, dirty — left)")
        elif is_merged(b):
            removable.append((b, path, "merged"))
        else:
            protected.append(f"{b} (live worktree, unmerged in-flight — left)")
    else:
        removable.append((b, "", "merged" if is_merged(b) else "unmerged-orphan"))

with open(manifest_path, "w") as f:
    f.write("# branch\tsha\tdate\tsubject\n")
    f.write("\n".join(manifest_lines) + ("\n" if manifest_lines else ""))

def err(*a): print(*a, file=sys.stderr)
err()
err(f"Manifest: {manifest_path} ({len(manifest_lines)} branch record(s))")
err()
err("PROTECTED (left as-is):")
err("\n".join(f"  {p}" for p in protected) if protected else "  (none)")
err()
err("REMOVABLE:")
if removable:
    for b, path, reason in removable:
        err(f"  {b} ({reason})" + (f" [worktree: {path}]" if path else ""))
else:
    err("  (none)")

for b, path, reason in removable:
    print(f"DELETE\t{b}\t{path}")
PY
)
[ $? -eq 0 ] || die "analysis failed"

if [ "$APPLY" -ne 1 ]; then
  echo
  echo "DRY-RUN: nothing deleted. Re-run with --apply to remove the REMOVABLE entries."
  exit 0
fi

echo
echo "Applying..."
printf '%s\n' "$plan" | while IFS=$'\t' read -r tag br path; do
  [ "$tag" = "DELETE" ] || continue
  if [ -n "$path" ]; then
    echo "  removing worktree $path"
    git worktree remove "$path" 2>/dev/null \
      || git worktree remove --force "$path" 2>/dev/null \
      || echo "    (could not remove worktree; leaving)"
  fi
  echo "  deleting branch $br"
  git branch -D "$br" >/dev/null 2>&1 || echo "    (could not delete $br)"
done
git worktree prune
echo "Done. Recovery manifest: $manifest"
