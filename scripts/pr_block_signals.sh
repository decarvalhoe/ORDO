#!/usr/bin/env bash
# scripts/pr_block_signals.sh — surface PR states that silently block merge flow.
#
# Usage:
#   pr_block_signals.sh <project_short|config_path> [--tsv|--json]
set -euo pipefail
TK=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

source "$TK/lib/config_resolver.sh"
source "$TK/lib/process_safety.sh"
source "$TK/lib/check_rollup_summary.sh"

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
# Body inclusion is opt-out (#358). Consumers like pr_ops_queue.sh need
# the PR body to extract linked-issue refs ("Closes #N", "Refs #N").
# Setting PR_SIGNAL_INCLUDE_BODY=0 strips it from the JSON output.
: "${PR_SIGNAL_INCLUDE_BODY:=1}"

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
  printf 'pr\tbranch\thead\tagent\tmerge_state\tmergeable\treview\tci_aggregate\tci_fail\tci_pending\tbase_current\tci_failed_names\tsignals\n'
fi

for pr in $prs; do
  pr_json=$(run_timeout "$PR_SIGNAL_GH_TIMEOUT_SEC" env GH_CONFIG_DIR="$GH_CONFIG_DIR" gh pr view "$pr" --repo "$GH_REPO" \
    --json number,headRefName,headRefOid,baseRefName,updatedAt,body,isDraft,mergeStateStatus,mergeable,reviewDecision,autoMergeRequest,statusCheckRollup 2>/dev/null || printf '{}')

  branch=$(printf '%s' "$pr_json" | jq -r '.headRefName // ""')
  head=$(printf '%s' "$pr_json" | jq -r '(.headRefOid // "")[0:8]')
  base_branch=$(printf '%s' "$pr_json" | jq -r '.baseRefName // ""')
  updated_at=$(printf '%s' "$pr_json" | jq -r '.updatedAt // ""')
  if [ "$PR_SIGNAL_INCLUDE_BODY" = "1" ]; then
    body_text=$(printf '%s' "$pr_json" | jq -r '.body // ""')
  else
    body_text=""
  fi
  is_draft=$(printf '%s' "$pr_json" | jq -r '.isDraft // false')
  merge_state=$(printf '%s' "$pr_json" | jq -r '.mergeStateStatus // ""')
  mergeable=$(printf '%s' "$pr_json" | jq -r '.mergeable // ""')
  review=$(printf '%s' "$pr_json" | jq -r '.reviewDecision // ""')
  auto_merge=$(printf '%s' "$pr_json" | jq -r '.autoMergeRequest // empty')
  # Project-agnostic rollup summary (#346): single source of truth for
  # multi-check evaluation. Surfaces failed/cancelled check NAMES so the
  # portfolio summary cannot under-report a multi-check matrix as
  # success — see lib/check_rollup_summary.sh and
  # docs/orchestrator-injected-rules.md.
  rollup_json=$(printf '%s' "$pr_json" | jq -c '.statusCheckRollup // []')
  rollup_summary=$(ordo_check_rollup_summary "$rollup_json")
  ci_aggregate=$(printf '%s' "$rollup_summary" | jq -r '.aggregate')
  case "$ci_aggregate" in
    success) ci_status="pass" ;;
    failed_or_cancelled) ci_status="fail" ;;
    pending) ci_status="pending" ;;
    *) ci_status="unknown" ;;
  esac
  ci_fail=$(printf '%s' "$rollup_summary" | jq '(.failed | length) + (.cancelled | length)')
  ci_pending=$(printf '%s' "$rollup_summary" | jq '.pending | length')
  ci_total=$(printf '%s' "$rollup_summary" | jq '.total')
  ci_failed_check_names=$(printf '%s' "$rollup_summary" \
    | jq -c '[(.failed[]?.name), (.cancelled[]?.name)]')
  ci_failed_urls=$(printf '%s' "$rollup_summary" \
    | jq -c '[(.failed[]?.url?), (.cancelled[]?.url?)] | map(select(type == "string" and length > 0))')
  ci_pending_urls=$(printf '%s' "$rollup_summary" \
    | jq -c '[.pending[]?.url? | select(type == "string" and length > 0)]')
  deploy_gate_pending=$(printf '%s' "$pr_json" | jq '
    def is_pending: (((.status // "") as $s | ["QUEUED","IN_PROGRESS","REQUESTED","WAITING","PENDING"] | index($s)) or ((.state // "") as $st | ["PENDING","EXPECTED"] | index($st)));
    def gate_name: ((.name // .context // "") | ascii_downcase);
    [.statusCheckRollup[]? | select(is_pending) | select(gate_name | test("deploy.*(gate|health|dev)"))] | length')

  owner_entry=$(owner_for_branch "$branch" || true)
  agent=${owner_entry%%|*}
  workdir=${owner_entry#*|}
  [ "$agent" = "$owner_entry" ] && [ -z "$workdir" ] && agent=""
  base_current=$(base_current_for_workdir "$workdir")

  pr_head_full=$(printf '%s' "$pr_json" | jq -r '.headRefOid // ""')
  head_local_full=""
  if [ -n "$workdir" ] && [ -d "$workdir/.git" ]; then
    head_local_full=$(run_timeout "$PR_SIGNAL_GIT_TIMEOUT_SEC" git -C "$workdir" rev-parse HEAD 2>/dev/null || true)
  fi

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
  if [ "$base_current" = "0" ]; then
    if [ -n "$head_local_full" ] && [ -n "$pr_head_full" ] && [ "$head_local_full" != "$pr_head_full" ]; then
      blocker_signals+=("remote-rebased-local-stale")
    else
      blocker_signals+=("needs-rebase")
    fi
  fi
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
  ci_failed_names_text=$(printf '%s' "$ci_failed_check_names" | jq -r 'join(",")')
  if [ "$FORMAT" = "json" ]; then
    json_items+=("$(jq -nc \
      --arg pr "$pr" \
      --arg branch "$branch" \
      --arg head "$head" \
      --arg head_full "$pr_head_full" \
      --arg base_branch "$base_branch" \
      --arg updated_at "$updated_at" \
      --arg body_text "$body_text" \
      --arg agent "$agent" \
      --arg merge_state "$merge_state" \
      --arg mergeable "$mergeable" \
      --arg review "$review" \
      --arg is_draft "$is_draft" \
      --arg ci_aggregate "$ci_aggregate" \
      --arg ci_status "$ci_status" \
      --arg ci_fail "$ci_fail" \
      --arg ci_pending "$ci_pending" \
      --arg ci_total "$ci_total" \
      --arg deploy_gate_pending "$deploy_gate_pending" \
      --arg base_current "$base_current" \
      --arg signals "$signal_text" \
      --argjson ci_failed_check_names "$ci_failed_check_names" \
      --argjson ci_failed_urls "$ci_failed_urls" \
      --argjson ci_pending_urls "$ci_pending_urls" \
      --argjson ci_rollup "$rollup_summary" \
      '{pr:$pr,branch:$branch,head:$head,head_full:$head_full,base_branch:$base_branch,updated_at:$updated_at,body_text:$body_text,agent:$agent,merge_state:$merge_state,mergeable:$mergeable,review:$review,is_draft:($is_draft == "true"),ci_aggregate:$ci_aggregate,ci_status:$ci_status,ci_fail:($ci_fail|tonumber),ci_pending:($ci_pending|tonumber),ci_total:($ci_total|tonumber),ci_failed_check_names:$ci_failed_check_names,ci_failed_urls:$ci_failed_urls,ci_pending_urls:$ci_pending_urls,ci_rollup:$ci_rollup,deploy_gate_pending:($deploy_gate_pending|tonumber),base_current:$base_current,signals:($signals | split(",") | map(select(length > 0)))}')")
  else
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$pr" "$branch" "$head" "$agent" "$merge_state" "$mergeable" "$review" \
      "$ci_aggregate" "$ci_fail" "$ci_pending" "$base_current" "$ci_failed_names_text" "$signal_text"
  fi
done

if [ "$FORMAT" = "json" ]; then
  printf '%s\n' "${json_items[@]}" | jq -s '.'
fi
