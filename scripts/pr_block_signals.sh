#!/usr/bin/env bash
# scripts/pr_block_signals.sh — surface PR states that silently block merge flow.
#
# Usage:
#   pr_block_signals.sh <project_short|config_path> [--tsv|--json]
# shellcheck disable=SC1091
set -euo pipefail
TK=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

# shellcheck source=lib/config_resolver.sh
source "$TK/lib/config_resolver.sh"
# shellcheck source=lib/process_safety.sh
source "$TK/lib/process_safety.sh"
# shellcheck source=lib/check_rollup_summary.sh
source "$TK/lib/check_rollup_summary.sh"
# Forge access goes through the provider adapter (#816, #818): no direct
# forge CLI call anywhere in this script.
# shellcheck source=lib/ordo_provider_adapter.sh
source "$TK/lib/ordo_provider_adapter.sh"

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
# shellcheck source=lib/agent_inventory.sh
source "$TK/lib/agent_inventory.sh"

: "${GH_REPO:?}" "${GH_CONFIG_DIR:?}" "${DEFAULT_BRANCH:=main}"
: "${PR_SIGNAL_LIMIT:=100}"
: "${PR_SIGNAL_GIT_TIMEOUT_SEC:=5}"
: "${PR_SIGNAL_GH_TIMEOUT_SEC:=5}"
: "${PR_SIGNAL_BASE_FETCH:=1}"
: "${PR_SIGNAL_REQUIRED_CONTEXT_LOOKUP:=1}"
: "${PR_SIGNAL_CHANGED_FILES_LOOKUP:=1}"
: "${PR_SIGNAL_WORKFLOW_LOOKUP:=1}"
: "${PR_SIGNAL_WORKFLOW_RUN_LIMIT:=20}"
: "${PR_SIGNAL_NO_CHECK_DOCS_PATTERN:=^docs/}"
: "${PR_SIGNAL_NO_CHECK_WORKFLOW_PATTERN:=^\\.github/workflows/}"
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
  local label _pane workdir current
  while IFS='|' read -r label _pane workdir; do
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

json_array_or_empty() {
  local payload=${1:-}
  printf '%s' "$payload" | jq -c 'if type == "array" then . else [] end' 2>/dev/null || printf '[]'
}

pr_required_contexts_json() {
  local branch=${1:-$DEFAULT_BRANCH}
  local payload

  [ "$PR_SIGNAL_REQUIRED_CONTEXT_LOOKUP" = "1" ] || { printf '[]'; return 0; }

  # ordo_provider branch_protection_get (#818): required_checks of the base
  # branch; an unprotected branch or a failed lookup is an empty list.
  payload=$(ORDO_PROVIDER_TIMEOUT_SEC="$PR_SIGNAL_GH_TIMEOUT_SEC" GH_CONFIG_DIR="$GH_CONFIG_DIR" \
    ordo_provider branch_protection_get "$branch" --repo "$GH_REPO" 2>/dev/null || true)
  [ -n "$payload" ] || { printf '[]'; return 0; }
  printf '%s' "$payload" | jq -c '[.required_checks[]?]' 2>/dev/null || printf '[]'
}

pr_changed_paths_json() {
  local pr=${1:?usage: pr_changed_paths_json <pr>}
  local payload

  [ "$PR_SIGNAL_CHANGED_FILES_LOOKUP" = "1" ] || { printf '[]'; return 0; }

  payload=$(ORDO_PROVIDER_TIMEOUT_SEC="$PR_SIGNAL_GH_TIMEOUT_SEC" GH_CONFIG_DIR="$GH_CONFIG_DIR" \
    ordo_provider pr_files "$pr" --repo "$GH_REPO" 2>/dev/null || true)
  [ -n "$payload" ] || { printf '[]'; return 0; }
  printf '%s' "$payload" | jq -c '[.files[]?.path // empty]' 2>/dev/null || printf '[]'
}

pr_scope_kind_from_paths_json() {
  local paths_json=${1:-[]}
  printf '%s' "$paths_json" | jq -r \
    --arg docs_pattern "$PR_SIGNAL_NO_CHECK_DOCS_PATTERN" \
    --arg workflow_pattern "$PR_SIGNAL_NO_CHECK_WORKFLOW_PATTERN" '
      def init: {total:0, docs:0, workflows:0, other:0};
      reduce .[]? as $path (init;
        .total += 1
        | if ($path | test($workflow_pattern)) then
            .workflows += 1
          elif ($path | test($docs_pattern)) then
            .docs += 1
          else
            .other += 1
          end
      )
      | if .total == 0 then "empty"
        elif .other > 0 then "code"
        elif .docs == .total then "docs-only"
        elif .workflows == .total then "workflow-only"
        else "docs-and-workflow"
        end
    ' 2>/dev/null || printf 'empty'
}

pr_active_workflows_json() {
  local payload

  [ "$PR_SIGNAL_WORKFLOW_LOOKUP" = "1" ] || { printf 'null'; return 0; }

  # ordo_provider workflow_list (#818): names of the active workflows. A
  # forge that cannot list workflows (details.capability="unsupported") or
  # a failed lookup reports "unknown" (null).
  payload=$(ORDO_PROVIDER_TIMEOUT_SEC="$PR_SIGNAL_GH_TIMEOUT_SEC" GH_CONFIG_DIR="$GH_CONFIG_DIR" \
    ordo_provider workflow_list --repo "$GH_REPO" --state all --limit 100 2>/dev/null || true)
  [ -n "$payload" ] || { printf 'null'; return 0; }
  printf '%s' "$payload" | jq -c '
    if (.details.capability // "") == "unsupported" then null
    else [.items[]? | select((.state // "active") == "active") | .name] end' 2>/dev/null || printf 'null'
}

pr_head_workflow_runs_json() {
  local branch=${1:?usage: pr_head_workflow_runs_json <branch> <head-oid>}
  local head_oid=${2:-}
  local payload

  [ "$PR_SIGNAL_WORKFLOW_LOOKUP" = "1" ] || { printf '[]'; return 0; }
  [ -n "$head_oid" ] || { printf '[]'; return 0; }

  payload=$(ORDO_PROVIDER_TIMEOUT_SEC="$PR_SIGNAL_GH_TIMEOUT_SEC" GH_CONFIG_DIR="$GH_CONFIG_DIR" \
    ordo_provider run_list \
      --repo "$GH_REPO" \
      --branch "$branch" \
      --commit "$head_oid" \
      --limit "$PR_SIGNAL_WORKFLOW_RUN_LIMIT" 2>/dev/null | jq -c '.items' 2>/dev/null || true)
  json_array_or_empty "$payload" | jq -c '
    [.[]? | {
      id: (.id // null),
      name: (.name // .workflow // ""),
      status: (.status // ""),
      conclusion: (.conclusion // ""),
      head_sha: (.head_sha // ""),
      url: (.url // "")
    }]
  ' 2>/dev/null || printf '[]'
}

ci_action_state_for_pr() {
  local pr=${1:?usage: ci_action_state_for_pr <pr> <branch> <base-branch> <head-oid> <ci-aggregate> <ci-total> <ci-fail> <ci-pending>}
  local branch=${2:?usage: ci_action_state_for_pr <pr> <branch> <base-branch> <head-oid> <ci-aggregate> <ci-total> <ci-fail> <ci-pending>}
  local base_branch=${3:-$DEFAULT_BRANCH}
  local head_oid=${4:-}
  local ci_aggregate=${5:-unknown}
  local ci_total=${6:-0}
  local ci_fail=${7:-0}
  local ci_pending=${8:-0}
  local ci_state next_action required_contexts changed_paths scope_kind
  local active_workflows active_workflow_count head_runs pending_head_runs

  required_contexts='[]'
  changed_paths='[]'
  active_workflows='[]'
  head_runs='[]'

  if [ "$ci_fail" -gt 0 ]; then
    ci_state="checks_failed"
    next_action="fix_or_rerun_failed_checks"
  elif [ "$ci_pending" -gt 0 ]; then
    ci_state="checks_pending"
    next_action="wait_for_checks"
  elif [ "$ci_total" -gt 0 ] && [ "$ci_aggregate" = "success" ]; then
    ci_state="checks_passed"
    next_action="merge_when_other_gates_clear"
  elif [ "$ci_total" -gt 0 ]; then
    ci_state="checks_pending"
    next_action="inspect_unknown_check_state"
  else
    required_contexts=$(pr_required_contexts_json "$base_branch")
    changed_paths=$(pr_changed_paths_json "$pr")
    scope_kind=$(pr_scope_kind_from_paths_json "$changed_paths")
    active_workflows=$(pr_active_workflows_json)
    head_runs=$(pr_head_workflow_runs_json "$branch" "$head_oid")

    if [ "$(printf '%s' "$required_contexts" | jq 'length' 2>/dev/null || printf 0)" -gt 0 ]; then
      ci_state="required_context_missing"
      next_action="record_blocker_issue_with_required_context"
    elif [ "$scope_kind" = "docs-only" ] || [ "$scope_kind" = "workflow-only" ] || [ "$scope_kind" = "docs-and-workflow" ]; then
      ci_state="checks_missing_due_path_filter"
      next_action="apply_no_check_policy_or_confirm_branch_protection"
    else
      pending_head_runs=$(printf '%s' "$head_runs" | jq '
        [.[]? | select(((.status // "") | ascii_downcase) != "completed")] | length
      ' 2>/dev/null || printf 0)
      active_workflow_count=$(printf '%s' "$active_workflows" | jq '
        if type == "array" then length else -1 end
      ' 2>/dev/null || printf -1)
      if [ "$pending_head_runs" -gt 0 ]; then
        ci_state="checks_pending"
        next_action="wait_for_checks"
      elif [ "$active_workflow_count" -eq 0 ]; then
        ci_state="no_checks_expected"
        next_action="no_ci_action_required"
      else
        ci_state="workflow_not_triggered"
        next_action="rerun_or_trigger_workflow"
      fi
    fi
  fi

  jq -nc \
    --arg state "$ci_state" \
    --arg next_action "$next_action" \
    --argjson required_contexts "$required_contexts" \
    --argjson changed_paths "$changed_paths" \
    --argjson expected_workflows "$active_workflows" \
    --argjson head_workflow_runs "$head_runs" \
    '{state:$state,next_action:$next_action,required_contexts:$required_contexts,changed_paths:$changed_paths,expected_workflows:$expected_workflows,head_workflow_runs:$head_workflow_runs}'
}

prs_json=$(ORDO_PROVIDER_TIMEOUT_SEC="$PR_SIGNAL_GH_TIMEOUT_SEC" GH_CONFIG_DIR="$GH_CONFIG_DIR" \
  ordo_provider pr_list \
    --repo "$GH_REPO" \
    --base "$DEFAULT_BRANCH" \
    --state open \
    --limit "$PR_SIGNAL_LIMIT" 2>/dev/null | jq -c '[.items[]? | {number}]' 2>/dev/null || printf '[]')
prs=$(printf '%s\n' "$prs_json" | jq -r '.[].number' 2>/dev/null || true)

# One PR row = pr_get (entity) + checks_get (rollup), projected back to the
# gh field names the extraction below consumes (#816). Enum values are
# upper-cased to keep the TSV/JSON output byte-identical.
pr_signal_fetch_pr_json() {
  local pr=${1:?usage: pr_signal_fetch_pr_json <pr>}
  local entity checks
  entity=$(ORDO_PROVIDER_TIMEOUT_SEC="$PR_SIGNAL_GH_TIMEOUT_SEC" GH_CONFIG_DIR="$GH_CONFIG_DIR" \
    ordo_provider pr_get "$pr" --repo "$GH_REPO" 2>/dev/null || printf '{}')
  checks=$(ORDO_PROVIDER_TIMEOUT_SEC="$PR_SIGNAL_GH_TIMEOUT_SEC" GH_CONFIG_DIR="$GH_CONFIG_DIR" \
    ordo_provider checks_get "$pr" --repo "$GH_REPO" 2>/dev/null || printf '{}')
  jq -cn --argjson pr "$entity" --argjson checks "$checks" '
    def up: if . == null then "" else (tostring | ascii_upcase) end;
    if ($pr | has("number")) then {
      number: $pr.number,
      headRefName: ($pr.head.ref // ""),
      headRefOid: ($pr.head.sha // ""),
      baseRefName: ($pr.base.ref // ""),
      updatedAt: ($pr.updated_at // ""),
      body: ($pr.body // ""),
      isDraft: ($pr.draft // false),
      mergeStateStatus: ($pr.merge_state | up),
      mergeable: ($pr.mergeable | up),
      reviewDecision: (if ($pr.review_decision // "none") == "none" then "" else ($pr.review_decision | up) end),
      autoMergeRequest: (if ($pr.auto_merge // false) then {enabled: true} else null end),
      statusCheckRollup: [ ($checks.checks // [])[] | {
        name: .name,
        status: (.status | up),
        conclusion: (.conclusion | up),
        detailsUrl: (.url // ""),
        workflowName: (.workflow // null)
      } ]
    } else {} end
  ' 2>/dev/null || printf '{}'
}

json_items=()
if [ "$FORMAT" = "tsv" ]; then
  printf 'pr\tbranch\thead\tagent\tmerge_state\tmergeable\treview\tci_aggregate\tci_fail\tci_pending\tbase_current\tci_failed_names\tci_actionable_state\tnext_action\tsignals\n'
fi

for pr in $prs; do
  pr_json=$(pr_signal_fetch_pr_json "$pr")

  branch=$(printf '%s' "$pr_json" | jq -r '.headRefName // ""')
  head=$(printf '%s' "$pr_json" | jq -r '(.headRefOid // "")[0:8]')
  pr_head_full=$(printf '%s' "$pr_json" | jq -r '.headRefOid // ""')
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
  ci_action_json=$(ci_action_state_for_pr "$pr" "$branch" "$base_branch" "$pr_head_full" "$ci_aggregate" "$ci_total" "$ci_fail" "$ci_pending")
  ci_actionable_state=$(printf '%s' "$ci_action_json" | jq -r '.state')
  next_action=$(printf '%s' "$ci_action_json" | jq -r '.next_action')
  ci_required_contexts=$(printf '%s' "$ci_action_json" | jq -c '.required_contexts')
  ci_changed_paths=$(printf '%s' "$ci_action_json" | jq -c '.changed_paths')
  ci_expected_workflows=$(printf '%s' "$ci_action_json" | jq -c '.expected_workflows')
  ci_head_workflow_runs=$(printf '%s' "$ci_action_json" | jq -c '.head_workflow_runs')

  owner_entry=$(owner_for_branch "$branch" || true)
  agent=${owner_entry%%|*}
  workdir=${owner_entry#*|}
  [ "$agent" = "$owner_entry" ] && [ -z "$workdir" ] && agent=""
  base_current=$(base_current_for_workdir "$workdir")

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
      --arg ci_actionable_state "$ci_actionable_state" \
      --arg next_action "$next_action" \
      --arg base_current "$base_current" \
      --arg signals "$signal_text" \
      --argjson ci_failed_check_names "$ci_failed_check_names" \
      --argjson ci_failed_urls "$ci_failed_urls" \
      --argjson ci_pending_urls "$ci_pending_urls" \
      --argjson ci_rollup "$rollup_summary" \
      --argjson ci_required_contexts "$ci_required_contexts" \
      --argjson ci_changed_paths "$ci_changed_paths" \
      --argjson ci_expected_workflows "$ci_expected_workflows" \
      --argjson ci_head_workflow_runs "$ci_head_workflow_runs" \
      '{pr:$pr,branch:$branch,head:$head,head_full:$head_full,base_branch:$base_branch,updated_at:$updated_at,body_text:$body_text,agent:$agent,merge_state:$merge_state,mergeable:$mergeable,review:$review,is_draft:($is_draft == "true"),ci_aggregate:$ci_aggregate,ci_status:$ci_status,ci_fail:($ci_fail|tonumber),ci_pending:($ci_pending|tonumber),ci_total:($ci_total|tonumber),ci_failed_check_names:$ci_failed_check_names,ci_failed_urls:$ci_failed_urls,ci_pending_urls:$ci_pending_urls,ci_rollup:$ci_rollup,deploy_gate_pending:($deploy_gate_pending|tonumber),ci_actionable_state:$ci_actionable_state,next_action:$next_action,ci_required_contexts:$ci_required_contexts,ci_changed_paths:$ci_changed_paths,ci_expected_workflows:$ci_expected_workflows,ci_head_workflow_runs:$ci_head_workflow_runs,base_current:$base_current,signals:($signals | split(",") | map(select(length > 0)))}')")
  else
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$pr" "$branch" "$head" "$agent" "$merge_state" "$mergeable" "$review" \
      "$ci_aggregate" "$ci_fail" "$ci_pending" "$base_current" "$ci_failed_names_text" \
      "$ci_actionable_state" "$next_action" "$signal_text"
  fi
done

if [ "$FORMAT" = "json" ]; then
  printf '%s\n' "${json_items[@]}" | jq -s '.'
fi
