#!/usr/bin/env bash
# scripts/pr_block_signals.sh — surface PR states that silently block merge flow.
#
# Usage:
#   pr_block_signals.sh <project_short|config_path> [--tsv|--json]
set -euo pipefail
TK=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

source "$TK/lib/config_resolver.sh"
source "$TK/lib/process_safety.sh"

CFG_ARG=${1:?usage: pr_block_signals.sh <project> [--tsv|--json]}
FORMAT="tsv"
shift
while [ "$#" -gt 0 ]; do
  case "$1" in
    --tsv) FORMAT="tsv" ;;
    --json) FORMAT="json" ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done

load_project_config "$CFG_ARG"
source "$TK/lib/agent_inventory.sh"

: "${GH_REPO:?}" "${GH_CONFIG_DIR:?}" "${DEFAULT_BRANCH:=main}"
: "${PR_SIGNAL_LIMIT:=100}"
: "${PR_SIGNAL_GIT_TIMEOUT_SEC:=5}"
: "${PR_SIGNAL_GH_TIMEOUT_SEC:=5}"
: "${PR_SIGNAL_BASE_FETCH:=1}"

run_timeout() {
  local seconds=$1
  shift
  orch_run_timeout "$seconds" "$@"
}

owner_for_branch() {
  local branch=${1:?usage: owner_for_branch <branch>}
  local label pane workdir current
  while IFS='|' read -r label pane workdir; do
    [ -d "$workdir/.git" ] || continue
    current=$(run_timeout "$PR_SIGNAL_GIT_TIMEOUT_SEC" git -C "$workdir" branch --show-current 2>/dev/null || true)
    if [ "$current" = "$branch" ]; then
      printf '%s|%s\n' "$label" "$workdir"
      return 0
    fi
  done < <(agent_inventory_entries)
  return 1
}

base_current_for_workdir() {
  local workdir=$1
  [ -d "$workdir/.git" ] || { printf ''; return 0; }
  if [ "$PR_SIGNAL_BASE_FETCH" = "1" ]; then
    run_timeout 10 git -C "$workdir" fetch origin "$DEFAULT_BRANCH" >/dev/null 2>&1 || true
  fi
  run_timeout "$PR_SIGNAL_GIT_TIMEOUT_SEC" git -C "$workdir" rev-parse --verify "origin/$DEFAULT_BRANCH" >/dev/null 2>&1 || {
    printf ''
    return 0
  }
  if run_timeout "$PR_SIGNAL_GIT_TIMEOUT_SEC" git -C "$workdir" merge-base --is-ancestor "origin/$DEFAULT_BRANCH" HEAD >/dev/null 2>&1; then
    printf '1'
  else
    printf '0'
  fi
}

prs_json=$(run_timeout "$PR_SIGNAL_GH_TIMEOUT_SEC" env GH_CONFIG_DIR="$GH_CONFIG_DIR" gh pr list \
  --repo "$GH_REPO" \
  --base "$DEFAULT_BRANCH" \
  --state open \
  --limit "$PR_SIGNAL_LIMIT" \
  --json number 2>/dev/null || printf '[]')
prs=$(printf '%s\n' "$prs_json" | jq -r '.[].number' 2>/dev/null || true)

json_items=()
if [ "$FORMAT" = "tsv" ]; then
  printf 'pr\tbranch\thead\tagent\tmerge_state\tmergeable\treview\tci_fail\tci_pending\tbase_current\tsignals\n'
fi

for pr in $prs; do
  pr_json=$(run_timeout "$PR_SIGNAL_GH_TIMEOUT_SEC" env GH_CONFIG_DIR="$GH_CONFIG_DIR" gh pr view "$pr" --repo "$GH_REPO" \
    --json number,headRefName,headRefOid,isDraft,mergeStateStatus,mergeable,reviewDecision,autoMergeRequest,statusCheckRollup 2>/dev/null || printf '{}')

  branch=$(printf '%s' "$pr_json" | jq -r '.headRefName // ""')
  head=$(printf '%s' "$pr_json" | jq -r '(.headRefOid // "")[0:8]')
  is_draft=$(printf '%s' "$pr_json" | jq -r '.isDraft // false')
  merge_state=$(printf '%s' "$pr_json" | jq -r '.mergeStateStatus // ""')
  mergeable=$(printf '%s' "$pr_json" | jq -r '.mergeable // ""')
  review=$(printf '%s' "$pr_json" | jq -r '.reviewDecision // ""')
  auto_merge=$(printf '%s' "$pr_json" | jq -r '.autoMergeRequest // empty')
  ci_fail=$(printf '%s' "$pr_json" | jq '[.statusCheckRollup[]? | select(((.conclusion // "") as $c | ["FAILURE","TIMED_OUT","CANCELLED","ACTION_REQUIRED","STARTUP_FAILURE"] | index($c)) or ((.state // "") as $s | ["FAILURE","ERROR"] | index($s)))] | length')
  ci_pending=$(printf '%s' "$pr_json" | jq '[.statusCheckRollup[]? | select(((.status // "") as $s | ["QUEUED","IN_PROGRESS","REQUESTED","WAITING","PENDING"] | index($s)) or ((.state // "") as $st | ["PENDING","EXPECTED"] | index($st)))] | length')
  ci_total=$(printf '%s' "$pr_json" | jq '[.statusCheckRollup[]?] | length')
  deploy_gate_pending=$(printf '%s' "$pr_json" | jq '
    def is_pending: (((.status // "") as $s | ["QUEUED","IN_PROGRESS","REQUESTED","WAITING","PENDING"] | index($s)) or ((.state // "") as $st | ["PENDING","EXPECTED"] | index($st)));
    def gate_name: ((.name // .context // "") | ascii_downcase);
    [.statusCheckRollup[]? | select(is_pending) | select(gate_name | test("deploy.*(gate|health|dev)"))] | length')

  owner_entry=$(owner_for_branch "$branch" || true)
  agent=${owner_entry%%|*}
  workdir=${owner_entry#*|}
  [ "$agent" = "$owner_entry" ] && [ -z "$workdir" ] && agent=""
  base_current=$(base_current_for_workdir "$workdir")

  blocker_signals=()
  [ "$is_draft" = "true" ] && blocker_signals+=("draft")
  case "$merge_state" in
    BEHIND) blocker_signals+=("pr-behind") ;;
    DIRTY) blocker_signals+=("merge-conflict") ;;
    UNKNOWN) blocker_signals+=("merge-state-unknown") ;;
    UNSTABLE) blocker_signals+=("merge-state-unstable") ;;
    BLOCKED) blocker_signals+=("merge-blocked") ;;
  esac
  case "$mergeable" in
    CONFLICTING) blocker_signals+=("merge-conflict") ;;
    UNKNOWN|"") blocker_signals+=("mergeable-unknown") ;;
  esac
  case "$review" in
    REVIEW_REQUIRED) blocker_signals+=("review-required") ;;
    CHANGES_REQUESTED) blocker_signals+=("changes-requested") ;;
  esac
  [ "$ci_total" -eq 0 ] && blocker_signals+=("checks-missing")
  [ "$ci_fail" -gt 0 ] && blocker_signals+=("ci-failed")
  [ "$ci_pending" -gt 0 ] && blocker_signals+=("ci-pending")
  [ -n "$auto_merge" ] && blocker_signals+=("auto-merge-armed")
  [ "$base_current" = "0" ] && blocker_signals+=("needs-rebase")
  [ "$deploy_gate_pending" -gt 0 ] && blocker_signals+=("deploy-gate-external-wait")

  signals=("${blocker_signals[@]}")
  if [ "$ci_total" -gt 0 ] && [ "$ci_fail" -eq 0 ] && [ "$ci_pending" -eq 0 ]; then
    signals+=("ci-pass")
  fi
  if [ "${#blocker_signals[@]}" -eq 0 ] \
    && [ "$ci_total" -gt 0 ] \
    && [ "$ci_fail" -eq 0 ] \
    && [ "$ci_pending" -eq 0 ] \
    && { [ "$merge_state" = "CLEAN" ] || [ "$merge_state" = "HAS_HOOKS" ]; } \
    && [ "$mergeable" = "MERGEABLE" ]; then
    signals+=("merge-ready")
  fi

  signal_text=$(IFS=,; printf '%s' "${signals[*]}")
  if [ "$FORMAT" = "json" ]; then
    json_items+=("$(jq -nc \
      --arg pr "$pr" \
      --arg branch "$branch" \
      --arg head "$head" \
      --arg agent "$agent" \
      --arg merge_state "$merge_state" \
      --arg mergeable "$mergeable" \
      --arg review "$review" \
      --arg ci_fail "$ci_fail" \
      --arg ci_pending "$ci_pending" \
      --arg deploy_gate_pending "$deploy_gate_pending" \
      --arg base_current "$base_current" \
      --arg signals "$signal_text" \
      '{pr:$pr,branch:$branch,head:$head,agent:$agent,merge_state:$merge_state,mergeable:$mergeable,review:$review,ci_fail:($ci_fail|tonumber),ci_pending:($ci_pending|tonumber),deploy_gate_pending:($deploy_gate_pending|tonumber),base_current:$base_current,signals:($signals | split(",") | map(select(length > 0)))}')")
  else
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$pr" "$branch" "$head" "$agent" "$merge_state" "$mergeable" "$review" \
      "$ci_fail" "$ci_pending" "$base_current" "$signal_text"
  fi
done

if [ "$FORMAT" = "json" ]; then
  printf '%s\n' "${json_items[@]}" | jq -s '.'
fi
