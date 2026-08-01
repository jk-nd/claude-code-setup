#!/bin/bash
# Harness inventory and lint-leakage scan — the input to /ablation, not a benchmark.
#
# What this DOES: measures how much context the harness costs every session, and finds prose rules
# that duplicate something already enforced mechanically (a hook, a linter, a CI check). Those are
# the deletion candidates, because a rule enforced by code costs nothing and never degrades.
#
# What this does NOT do: measure behaviour. Whether removing a rule changes what the model does can
# only be found by running representative tasks with and without it — deleting prose blind is how
# you lose a rule that was actually load-bearing. This script ranks candidates; you measure them.
#
# Usage: ci/eval-harness.sh [--json]
# Env:   GW_PLUGIN_DIR (path to the groundwork plugin, if you want its skills/agents counted)
set -euo pipefail

json=false
[ "${1:-}" = "--json" ] && json=true

est_tokens() { echo $(( ${1:-0} / 4 )); }   # ~4 chars/token
chars_of()   { [ -f "$1" ] && wc -c < "$1" | tr -d ' ' || echo 0; }

# --- always-resident context ------------------------------------------------------------------
claude_md=""
for c in CLAUDE.md .claude/CLAUDE.md repo-template/CLAUDE.md; do
  [ -f "$c" ] && { claude_md="$c"; break; }
done
claude_chars=$(chars_of "$claude_md")
claude_lines=0; [ -n "$claude_md" ] && claude_lines=$(wc -l < "$claude_md" | tr -d ' ')

rules_dir=""
for d in .claude/rules repo-template/.claude/rules; do [ -d "$d" ] && { rules_dir="$d"; break; }; done
rules_chars=0; rules_n=0
if [ -n "$rules_dir" ]; then
  while IFS= read -r -d '' f; do
    rules_n=$((rules_n + 1)); rules_chars=$((rules_chars + $(chars_of "$f")))
  done < <(find "$rules_dir" -name '*.md' -type f -print0 2>/dev/null)
fi

# Skills and agents cost only their frontmatter description in the always-on listing; the body
# loads on demand. Count descriptions, not whole files, or the number is meaningless.
desc_chars() {
  awk '/^---$/{n++; next} n==1 && /^(name|description):/{inblk=1; print; next}
       n==1 && inblk && /^[a-z_-]+:/{inblk=0} n==1 && inblk{print} n>=2{exit}' "$1" 2>/dev/null | wc -c | tr -d ' '
}
skills_n=0; skills_chars=0; agents_n=0; agents_chars=0
plugdir="${GW_PLUGIN_DIR:-plugin}"
if [ -d "$plugdir" ]; then
  while IFS= read -r -d '' f; do
    skills_n=$((skills_n + 1)); skills_chars=$((skills_chars + $(desc_chars "$f")))
  done < <(find "$plugdir/skills" -name 'SKILL.md' -type f -print0 2>/dev/null)
  while IFS= read -r -d '' f; do
    agents_n=$((agents_n + 1)); agents_chars=$((agents_chars + $(desc_chars "$f")))
  done < <(find "$plugdir/agents" -name '*.md' -type f -print0 2>/dev/null)
fi

resident=$(( claude_chars + rules_chars + skills_chars + agents_chars ))

# --- lint leakage: prose whose subject is already enforced by a mechanism ----------------------
# Each probe is (regex over prose, description of the mechanism, test that the mechanism is present).
leaks=()
probe() {
  local pattern="$1" mechanism="$2" present="$3"
  [ -z "$claude_md" ] && return 0
  [ "$present" != "yes" ] && return 0
  if grep -qiE "$pattern" "$claude_md" 2>/dev/null; then leaks+=("$mechanism"); fi
  if [ -n "$rules_dir" ] && grep -rqiE "$pattern" "$rules_dir" 2>/dev/null; then leaks+=("$mechanism (in rules/)"); fi
}
have_hook() { [ -f "$plugdir/hooks/$1" ] && echo yes || echo no; }
have_file() { [ -f "$1" ] && echo yes || echo no; }
have_ci()   { grep -rqE "$1" .github/workflows/ 2>/dev/null && echo yes || echo no; }

probe 'rm -rf|force.?push|chmod 777'        'destructive-command prose -> guard-catastrophic.sh' "$(have_hook guard-catastrophic.sh)"
probe 'acceptance test|rubric'              'contract-edit prose -> guard-config.sh + pre-commit.sh' "$(have_hook guard-config.sh)"
probe 'gofmt|golangci|lint'                 'lint prose -> .golangci.yml + CI lint job' "$(have_file .golangci.yml)"
probe 'race detector|-race'                 'race-detector prose -> CI test job' "$(have_ci 'go test')"
probe 'timeout'                             'timeout prose -> job timeout-minutes' "$(have_ci 'timeout-minutes')"
probe 'sign|verified commit'                'commit-signing prose -> branch protection' "$(have_ci 'attestation')"

# --- output -----------------------------------------------------------------------------------
if [ "$json" = true ]; then
  printf '{"resident_est_tokens":%s,"claude_md":{"path":"%s","lines":%s,"est_tokens":%s},' \
    "$(est_tokens $resident)" "$claude_md" "$claude_lines" "$(est_tokens $claude_chars)"
  printf '"rules":{"files":%s,"est_tokens":%s},"skills":{"count":%s,"listing_est_tokens":%s},' \
    "$rules_n" "$(est_tokens $rules_chars)" "$skills_n" "$(est_tokens $skills_chars)"
  printf '"agents":{"count":%s,"listing_est_tokens":%s},"leak_candidates":%s}\n' \
    "$agents_n" "$(est_tokens $agents_chars)" "${#leaks[@]}"
  exit 0
fi

echo "Harness inventory — context paid on EVERY session"
echo "  CLAUDE.md         ${claude_md:-<none>}  ${claude_lines} lines, ~$(est_tokens $claude_chars) est. tokens"
echo "  rules/            ${rules_n} files, ~$(est_tokens $rules_chars) est. tokens (path-scoped rules load on demand)"
echo "  skills listing    ${skills_n} skills, ~$(est_tokens $skills_chars) est. tokens (descriptions only)"
echo "  agents listing    ${agents_n} agents, ~$(est_tokens $agents_chars) est. tokens (descriptions only)"
echo "  ------------------------------------------------------------------"
echo "  always-resident   ~$(est_tokens $resident) est. tokens per session"
[ "$claude_lines" -gt 50 ] && echo "  NOTE: CLAUDE.md is over the 50-line target — behavioural rules only; environment facts scale with the repo."
echo

if [ ${#leaks[@]} -eq 0 ]; then
  echo "Lint leakage: none found (no prose duplicating an active mechanism)."
else
  echo "Lint-leakage candidates — prose whose subject is already enforced by code:"
  printf '  %s\n' "${leaks[@]}" | sort -u
fi
echo
echo "Next step — /ablation. Do NOT delete prose on this report alone:"
echo "  1. Pick one candidate above."
echo "  2. Run 5-10 representative tasks WITH it, count compliance on the behaviour it targets."
echo "  3. Remove it, rerun the same tasks, compare."
echo "  4. Record the measurement in docs/calibration.md — including retentions."
echo "  Removing prose that measured as load-bearing is how a harness silently gets worse."
