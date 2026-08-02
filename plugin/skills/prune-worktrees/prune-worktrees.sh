#!/bin/bash
# Remove finished agent worktrees. Dry-run by default; --apply to actually delete.
#
# Refuses to remove a worktree that has uncommitted changes, whose branch is not merged into the
# base, or that is the current one. Records every branch tip SHA before deleting, so a wrongly
# pruned branch is recoverable with `git branch <name> <sha>`.
#
# Usage: prune-worktrees.sh [--apply] [--base <ref>]     (default base: main)
set -uo pipefail

apply=false; base=main
while [ $# -gt 0 ]; do
  case "$1" in
    --apply) apply=true; shift ;;
    --base)  base="${2:-main}"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "not a git repo"; exit 1; }
root=$(git rev-parse --show-toplevel)
here=$(git rev-parse --show-toplevel 2>/dev/null)
manifest="$root/.git/prune-worktrees-manifest.txt"

removable=(); kept=()
while IFS= read -r line; do
  case "$line" in worktree\ *) wt="${line#worktree }" ;; *) continue ;; esac
  [ "$wt" = "$root" ] && continue                       # never the main checkout
  [ "$wt" = "$here" ] && { kept+=("$wt — is the current worktree"); continue; }
  [ -d "$wt" ] || continue

  if [ -n "$(git -C "$wt" status --porcelain 2>/dev/null)" ]; then
    kept+=("$wt — has uncommitted changes"); continue
  fi
  br=$(git -C "$wt" branch --show-current 2>/dev/null)
  if [ -z "$br" ]; then kept+=("$wt — detached HEAD"); continue; fi
  if ! git merge-base --is-ancestor "$br" "$base" 2>/dev/null; then
    kept+=("$wt — branch '$br' not merged into $base"); continue
  fi
  removable+=("$wt|$br|$(git -C "$wt" rev-parse HEAD 2>/dev/null)")
done < <(git worktree list --porcelain)

echo "Agent worktrees under this repo:"
if [ ${#kept[@]} -gt 0 ]; then
  echo "  KEEP:"; printf '    %s\n' "${kept[@]}"
fi
if [ ${#removable[@]} -eq 0 ]; then
  echo "  nothing is safe to remove."
  exit 0
fi
echo "  REMOVABLE (clean and merged into $base):"
for e in "${removable[@]}"; do
  IFS='|' read -r wt br sha <<< "$e"; echo "    $wt   [$br @ ${sha:0:8}]"
done

if [ "$apply" != true ]; then
  echo
  echo "Dry run. Re-run with --apply to remove them."
  echo "Note: a worktree is still bound to its agent — if that agent may be RESUMED, keep it."
  echo "A resumed agent whose worktree is gone can commit into a sibling worktree."
  exit 0
fi

{ echo "# pruned $(git log -1 --format=%cI 2>/dev/null)"; for e in "${removable[@]}"; do echo "$e"; done; } >> "$manifest"
echo
echo "Recorded branch tips in $manifest (recover with: git branch <name> <sha>)"
for e in "${removable[@]}"; do
  IFS='|' read -r wt br sha <<< "$e"
  if git worktree remove "$wt" 2>/dev/null; then echo "  removed $wt"
  else echo "  FAILED to remove $wt (left in place)"; fi
done
git worktree prune
echo "done."
