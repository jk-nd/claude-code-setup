#!/usr/bin/env bash
#
# ci-watch.sh — wait for a GitHub PR's checks to reach a terminal state and
# exit with a code that reflects whether CI actually passed.
#
# Part of the `ci-watch` skill. See SKILL.md for the gotchas this avoids
# (the `gh pr checks --exit-status` trap and `| tail` exit-code masking).
#
# Usage:
#   ci-watch.sh <pr-number> [--repo owner/name] [--interval secs] [--timeout secs]
#   ci-watch.sh --branch <branch> [--repo owner/name] [...]
#
# Exit codes:
#   0  all checks terminal and none failed (SUCCESS / SKIPPED / NEUTRAL);
#      also the "no checks ran" path-skip case.
#   1  at least one check FAILED / CANCELLED / TIMED_OUT / errored.
#   2  timed out waiting for checks to finish.
#   3  usage / lookup error.
#
set -uo pipefail

INTERVAL=20
TIMEOUT=1800
REPO=""
PR=""
BRANCH=""

die() { echo "ci-watch: $*" >&2; exit 3; }

while [ $# -gt 0 ]; do
  case "$1" in
    --repo)     REPO="${2:?--repo needs a value}"; shift 2 ;;
    --branch)   BRANCH="${2:?--branch needs a value}"; shift 2 ;;
    --interval) INTERVAL="${2:?}"; shift 2 ;;
    --timeout)  TIMEOUT="${2:?}"; shift 2 ;;
    -h|--help)  grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)         die "unknown flag: $1" ;;
    *)          PR="$1"; shift ;;
  esac
done

command -v gh >/dev/null 2>&1      || die "gh CLI not found"
command -v python3 >/dev/null 2>&1 || die "python3 not found"

repo_args=()
[ -n "$REPO" ] && repo_args=(--repo "$REPO")

# Resolve PR number from a branch name if that's what we were given.
if [ -z "$PR" ] && [ -n "$BRANCH" ]; then
  PR=$(gh pr list ${repo_args[@]+"${repo_args[@]}"} --head "$BRANCH" --state open --json number --jq '.[0].number' 2>/dev/null)
  [ -n "$PR" ] || die "no open PR found for branch '$BRANCH'"
fi
[ -n "$PR" ] || die "usage: ci-watch.sh <pr-number> | --branch <branch>"

deadline=$(( $(date +%s) + TIMEOUT ))

while :; do
  # Capture gh output into a variable so we read its REAL exit code. Never
  # pipe `gh` into another command to inspect output — the pipe's exit code
  # is the LAST command's, masking a gh failure (the `| tail` trap).
  raw=$(gh pr view "$PR" ${repo_args[@]+"${repo_args[@]}"} --json statusCheckRollup,mergeable,mergeStateStatus 2>/dev/null)
  rc=$?
  [ $rc -eq 0 ] || die "gh pr view failed (rc=$rc) for PR #$PR"

  verdict=$(RAW="$raw" python3 <<'PY'
import json, os

data = json.loads(os.environ["RAW"])
rollup = data.get("statusCheckRollup") or []

NONTERMINAL = {"QUEUED", "IN_PROGRESS", "PENDING", "WAITING", "REQUESTED", "EXPECTED"}
FAIL_CONCLUSION = {"FAILURE", "CANCELLED", "TIMED_OUT", "ACTION_REQUIRED", "STARTUP_FAILURE"}
FAIL_STATE = {"FAILURE", "ERROR"}

pending = failed = 0
lines = []
for c in rollup:
    if c.get("__typename") == "CheckRun":
        name = c.get("name", "?")
        status = (c.get("status") or "").upper()
        concl = (c.get("conclusion") or "").upper()
        if status != "COMPLETED":
            pending += 1
            lines.append(f"{name}={status or 'PENDING'}")
            continue
        lines.append(f"{name}={concl or 'NEUTRAL'}")
        if concl in FAIL_CONCLUSION:
            failed += 1
    else:  # StatusContext
        name = c.get("context", "?")
        state = (c.get("state") or "").upper()
        if state in NONTERMINAL:
            pending += 1
            lines.append(f"{name}={state}")
            continue
        lines.append(f"{name}={state}")
        if state in FAIL_STATE:
            failed += 1

print("COUNT", len(rollup))
print("PENDING", pending)
print("FAILED", failed)
print("MERGEABLE", data.get("mergeable"))
print("MERGESTATE", data.get("mergeStateStatus"))
for l in lines:
    print("CHECK", l)
PY
)
  [ $? -eq 0 ] || die "failed to parse statusCheckRollup for PR #$PR"

  count=$(printf '%s\n' "$verdict"   | awk '$1=="COUNT"{print $2}')
  pending=$(printf '%s\n' "$verdict" | awk '$1=="PENDING"{print $2}')
  failed=$(printf '%s\n' "$verdict"  | awk '$1=="FAILED"{print $2}')

  # Path-skip / no-checks case: nothing to wait for — do NOT hang.
  if [ "${count:-0}" -eq 0 ]; then
    echo "ci-watch: PR #$PR has no checks (path-skipped or none configured) — treating as CLEAN."
    exit 0
  fi

  if [ "${pending:-0}" -eq 0 ]; then
    printf '%s\n' "$verdict" | awk '$1=="CHECK"{$1="";sub(/^ /,"");print "  "$0}'
    mergeable=$(printf '%s\n' "$verdict"  | awk '$1=="MERGEABLE"{print $2}')
    mergestate=$(printf '%s\n' "$verdict" | awk '$1=="MERGESTATE"{print $2}')
    echo "ci-watch: PR #$PR mergeable=$mergeable mergeStateStatus=$mergestate"
    if [ "${failed:-0}" -gt 0 ]; then
      echo "ci-watch: FAILED — $failed check(s) did not pass."
      exit 1
    fi
    echo "ci-watch: OK — all checks passed or were skipped."
    exit 0
  fi

  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo "ci-watch: TIMEOUT after ${TIMEOUT}s with $pending check(s) still pending." >&2
    exit 2
  fi
  echo "ci-watch: PR #$PR — $pending pending, $failed failed so far; re-checking in ${INTERVAL}s..."
  sleep "$INTERVAL"
done
