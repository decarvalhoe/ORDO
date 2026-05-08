#!/usr/bin/env bash
# scripts/continuation_guard.sh - refuse a clean stop while useful work exists.
#
# Usage:
#   continuation_guard.sh <portfolio-config> [--tsv|--json] [--yolo-priority] [--strict-actions]
#
# Exit codes:
#   0  stop_ok
#   10 continuation/action required
#   14 portfolio priority config missing/incomplete
set -euo pipefail
TK=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

source "$TK/lib/portfolio_config.sh"

PORTFOLIO_ARG=${1:?usage: continuation_guard.sh <portfolio-config> [--tsv|--json] [--yolo-priority] [--strict-actions]}
FORMAT="tsv"
STRICT_ACTIONS=0
PRIORITY_ARGS=()
shift
while [ "$#" -gt 0 ]; do
  case "$1" in
    --tsv) FORMAT="tsv" ;;
    --json) FORMAT="json" ;;
    --yolo-priority)
      # shellcheck disable=SC2034  # consumed by portfolio_config.sh helpers
      PORTFOLIO_YOLO_PRIORITY=1
      PRIORITY_ARGS+=(--yolo-priority)
      ;;
    --strict-actions) STRICT_ACTIONS=1 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done

load_portfolio_config "$PORTFOLIO_ARG"
portfolio_require_priorities || exit 14

status_json=$(bash "$TK/scripts/portfolio_status.sh" "$ORCH_PORTFOLIO_CONFIG_PATH" --json "${PRIORITY_ARGS[@]}")

json_items=()
action_states=()

add_item() {
  local kind=${1:?} alias=${2:?} priority=${3:?} reason=${4:?} detail=${5:-}
  local count=${6:-1}
  json_items+=("$(jq -nc \
    --arg kind "$kind" \
    --arg alias "$alias" \
    --arg priority "$priority" \
    --arg reason "$reason" \
    --arg detail "$detail" \
    --arg count "$count" \
    '{kind:$kind,alias:$alias,priority:($priority|tonumber),reason:$reason,detail:$detail,count:($count|tonumber)}')")
}

add_action_item() {
  local action_state=${1:?} kind=${2:?} alias=${3:?} priority=${4:?} reason=${5:?} detail=${6:-}
  local count=${7:-1}
  add_item "$kind" "$alias" "$priority" "$reason" "$detail" "$count"
  action_states+=("$action_state")
}

has_action_state() {
  local wanted=${1:?usage: has_action_state <state>}
  local state
  for state in "${action_states[@]}"; do
    [ "$state" = "$wanted" ] && return 0
  done
  return 1
}

plan_for_config() {
  local cfg=${1:?usage: plan_for_config <config> [dispatch-plan-args...]}
  shift
  local plan
  plan=$(bash "$TK/scripts/dispatch_plan.sh" "$cfg" "$@" --json 2>/dev/null || printf '[]')
  if jq -e 'type == "array"' <<< "$plan" >/dev/null 2>&1; then
    printf '%s\n' "$plan"
  else
    printf '[]\n'
  fi
}

ready_plan_for_config() {
  local cfg=${1:?usage: ready_plan_for_config <config>}
  plan_for_config "$cfg" --ready-only
}

full_plan_for_config() {
  local cfg=${1:?usage: full_plan_for_config <config>}
  plan_for_config "$cfg"
}

ready_item_for_plan() {
  local plan=${1:?usage: ready_item_for_plan <plan-json> <index>}
  local index=${2:?usage: ready_item_for_plan <plan-json> <index>}
  jq -r --argjson index "$index" '
    .[$index]?
    | if . == null then "" else "#\(.issue) \(.title)" end
  ' <<< "$plan" 2>/dev/null || true
}

ensure_agent_labels() {
  local prefix=${1:?usage: ensure_agent_labels <prefix> <count> <array-name>}
  local expected=${2:?usage: ensure_agent_labels <prefix> <count> <array-name>}
  local labels_name=${3:?usage: ensure_agent_labels <prefix> <count> <array-name>}
  local next
  local -n labels_ref=$labels_name

  while [ "${#labels_ref[@]}" -lt "$expected" ]; do
    next=$(( ${#labels_ref[@]} + 1 ))
    labels_ref+=("${prefix}-${next}")
  done
}

record_idle_agent_blockers() {
  local alias=${1:?} priority=${2:?} ready_count=${3:?} used_count=${4:?}
  shift 4
  local capacity=$# blocker index agent

  if [ "$used_count" -ge "$capacity" ]; then
    return 0
  fi

  blocker="ready-queue-exhausted"
  if [ "$ready_count" -eq 0 ]; then
    blocker="no-ready-issue"
  fi

  index=0
  for agent in "$@"; do
    if [ "$index" -ge "$used_count" ]; then
      add_item "warning" "$alias" "$priority" "idle-ready-agent-blocker" \
        "agent=${agent} blocker=${blocker}; available_capacity=${capacity} ready_issues=${ready_count}" 1
    fi
    index=$((index + 1))
  done
}

record_ready_queue_continuation() {
  local alias=${1:?} priority=${2:?} capacity=${3:?} cfg=${4:?}
  local full_plan atomize_count shipped_suspect_count blocked_count detail

  [ "$capacity" -gt 0 ] || return 0

  full_plan=$(full_plan_for_config "$cfg")
  atomize_count=$(jq -r '[.[]? | select(.status == "atomize" or .status == "stale_parent")] | length' <<< "$full_plan")
  shipped_suspect_count=$(jq -r '[.[]? | select(.status == "shipped_suspect")] | length' <<< "$full_plan")
  blocked_count=$(jq -r '[.[]? | select(.status == "blocked")] | length' <<< "$full_plan")

  if [ "$atomize_count" -gt 0 ]; then
    detail="ready_queue_empty; available_capacity=${capacity}; atomize_candidates=${atomize_count}; action=dispatch_plan --atomize --dry-run"
    add_action_item "continue_required" "reason" "$alias" "$priority" "atomize-required" "$detail" "$atomize_count"
  fi
  if [ "$shipped_suspect_count" -gt 0 ]; then
    detail="ready_queue_empty; available_capacity=${capacity}; shipped_suspect=${shipped_suspect_count}; action=review shipped evidence or rerun ready plan with explicit include"
    add_action_item "continue_required" "reason" "$alias" "$priority" "shipped-suspect-review-required" "$detail" "$shipped_suspect_count"
  fi
  if [ "$blocked_count" -gt 0 ]; then
    detail="ready_queue_empty; available_capacity=${capacity}; blocked_issues=${blocked_count}; action=record or dispatch unblock work"
    add_action_item "continue_required" "reason" "$alias" "$priority" "unblock-required" "$detail" "$blocked_count"
  fi
}

while IFS= read -r project_b64; do
  project_json=$(printf '%s' "$project_b64" | base64 -d)
  alias=$(jq -r '.alias' <<< "$project_json")
  priority=$(jq -r '.priority' <<< "$project_json")
  cfg=$(jq -r '.config' <<< "$project_json")
  gate_state=$(jq -r '.gate_state' <<< "$project_json")
  free=$(jq -r '.counts.free // 0' <<< "$project_json")
  parkable=$(jq -r '.counts.parkable // 0' <<< "$project_json")
  merge_ready=$(jq -r '.counts.merge_ready // 0' <<< "$project_json")
  ci_failed=$(jq -r '.counts.ci_failed // 0' <<< "$project_json")
  conflicts=$(jq -r '.counts.conflicts // 0' <<< "$project_json")
  needs_rebase=$(jq -r '.counts.needs_rebase // 0' <<< "$project_json")
  review_required=$(jq -r '.counts.review_required // 0' <<< "$project_json")
  open_prs=$(jq -r '.counts.open_prs // 0' <<< "$project_json")
  draft_prs=$(jq -r '.counts.draft_prs // 0' <<< "$project_json")
  failed_draft_prs=$(jq -r '.counts.failed_draft_prs // 0' <<< "$project_json")
  clean_unblocker_prs=$(jq -r '.counts.clean_unblocker_prs // 0' <<< "$project_json")
  backlog_signal=$(jq -r '.backlog_signal // ""' <<< "$project_json")
  clean_unblocker_pr_csv=$(jq -r '(.clean_unblocker_pr_numbers // []) | join(",")' <<< "$project_json")

  # Backlog escalation (#353). The clean-unblocker case must take priority
  # over any other reason the loop emits, including merge-ready and the
  # downstream dispatch/rebalance work, because merging the unblocker is
  # what makes the downstream PRs become merge-ready in the first place.
  # Without this branch the orchestrator would keep dispatching new work
  # while the integration queue stays effectively blocked.
  if [ "$clean_unblocker_prs" -gt 0 ]; then
    add_action_item "merge_required" "reason" "$alias" "$priority" \
      "backlog-clean-unblocker-ready" \
      "clean draft PR(s)=${clean_unblocker_pr_csv:-unknown} can unblock pack: total=${open_prs} drafts=${draft_prs} failed=${ci_failed}; action=mark ready -> merge through gated path -> rerun dependent failed PRs" \
      "$clean_unblocker_prs"
  elif [ "$backlog_signal" = "drafts_and_ci_blocked" ]; then
    add_action_item "continue_required" "reason" "$alias" "$priority" \
      "backlog-drafts-and-ci-blocked" \
      "total=${open_prs} drafts=${draft_prs} failed=${ci_failed}; action=mark ready and remediate CI before further dispatch" \
      "$open_prs"
  elif [ "$backlog_signal" = "drafts_blocked" ]; then
    add_action_item "continue_required" "reason" "$alias" "$priority" \
      "backlog-drafts-blocked" \
      "total=${open_prs} drafts=${draft_prs}; action=mark ready or close stale drafts before further dispatch" \
      "$draft_prs"
  elif [ "$backlog_signal" = "ci_blocked" ]; then
    add_action_item "continue_required" "reason" "$alias" "$priority" \
      "backlog-ci-blocked" \
      "total=${open_prs} failed=${ci_failed}; action=rerun or fix failed CI before further dispatch" \
      "$ci_failed"
  fi

  if [ "$failed_draft_prs" -gt 0 ] && [ "$clean_unblocker_prs" -eq 0 ]; then
    add_item "warning" "$alias" "$priority" "failed-draft-prs" \
      "${failed_draft_prs} draft PR(s) with failed CI; rerun or unmark-and-fix once integration is unblocked" \
      "$failed_draft_prs"
  fi

  if [ "$merge_ready" -gt 0 ]; then
    add_item "reason" "$alias" "$priority" "merge-ready" "${merge_ready} PR(s) can be merged" "$merge_ready"
  fi
  if [ "$ci_failed" -gt 0 ]; then
    add_item "reason" "$alias" "$priority" "ci-failed" "${ci_failed} PR(s) need CI remediation" "$ci_failed"
  fi
  if [ "$conflicts" -gt 0 ]; then
    add_item "reason" "$alias" "$priority" "merge-conflict" "${conflicts} PR(s) need conflict remediation" "$conflicts"
  fi
  if [ "$STRICT_ACTIONS" -eq 1 ] && [ "$needs_rebase" -gt 0 ]; then
    add_item "reason" "$alias" "$priority" "needs-rebase" "${needs_rebase} PR(s) need rebase/update" "$needs_rebase"
  elif [ "$needs_rebase" -gt 0 ]; then
    add_item "warning" "$alias" "$priority" "needs-rebase" "${needs_rebase} PR(s) remain action-required or intentionally gated" "$needs_rebase"
  fi
  if [ "$STRICT_ACTIONS" -eq 1 ] && [ "$review_required" -gt 0 ]; then
    add_item "reason" "$alias" "$priority" "review-required" "${review_required} PR(s) need review" "$review_required"
  elif [ "$review_required" -gt 0 ]; then
    add_item "warning" "$alias" "$priority" "review-required" "${review_required} PR(s) remain review-gated" "$review_required"
  fi

  if [ $((free + parkable)) -gt 0 ]; then
    ready_plan=$(ready_plan_for_config "$cfg")
    ready_count=$(jq -r 'length' <<< "$ready_plan")
    mapfile -t free_agents < <(jq -r '.agents.free[]? // empty' <<< "$project_json")
    mapfile -t parkable_agents < <(jq -r '.agents.parkable[]? // empty' <<< "$project_json")
    ensure_agent_labels "free" "$free" free_agents
    ensure_agent_labels "parkable" "$parkable" parkable_agents

    if [ "$ready_count" -gt 0 ]; then
      capacity=$((free + parkable))
      ready_index=0
      for agent in "${free_agents[@]}"; do
        if [ "$ready_index" -ge "$ready_count" ]; then
          break
        fi
        ready_item=$(ready_item_for_plan "$ready_plan" "$ready_index")
        add_action_item "dispatch_required" "reason" "$alias" "$priority" "dispatch-required" \
          "agent=${agent} issue=${ready_item:-unknown}; available_capacity=${capacity} ready_issues=${ready_count}" 1
        ready_index=$((ready_index + 1))
      done

      for agent in "${parkable_agents[@]}"; do
        if [ "$ready_index" -ge "$ready_count" ]; then
          break
        fi
        ready_item=$(ready_item_for_plan "$ready_plan" "$ready_index")
        add_action_item "rebalance_required" "reason" "$alias" "$priority" "rebalance-required" \
          "agent=${agent} issue=${ready_item:-unknown}; blocker=park-or-switch-required; action=auto_rebalance --apply; available_capacity=${capacity} ready_issues=${ready_count}" 1
        ready_index=$((ready_index + 1))
      done

      record_idle_agent_blockers "$alias" "$priority" "$ready_count" "$ready_index" \
        "${free_agents[@]}" "${parkable_agents[@]}"
    else
      record_ready_queue_continuation "$alias" "$priority" $((free + parkable)) "$cfg"
      record_idle_agent_blockers "$alias" "$priority" "$ready_count" 0 \
        "${free_agents[@]}" "${parkable_agents[@]}"
    fi
  fi

  if [ "$open_prs" -gt 0 ] && [ "$gate_state" = "external_wait" ]; then
    add_item "warning" "$alias" "$priority" "external-wait" "${open_prs} PR(s) waiting on external CI/gates" "$open_prs"
  fi
done < <(jq -r '.[] | @base64' <<< "$status_json")

reasons_json=$(printf '%s\n' "${json_items[@]:-}" | jq -s '[.[] | select(.kind == "reason")] | sort_by(-.priority, .alias, .reason)')
warnings_json=$(printf '%s\n' "${json_items[@]:-}" | jq -s '[.[] | select(.kind == "warning")] | sort_by(-.priority, .alias, .reason)')
reason_count=$(jq -r 'length' <<< "$reasons_json")
decision="stop_ok"
exit_code=0
if [ "$reason_count" -gt 0 ]; then
  # Decision priority (#353): merge_required wins over dispatch_required
  # so a clean unblocker is merged before more agents are sent at the
  # backlog. Otherwise the existing chain stands.
  if has_action_state "merge_required"; then
    decision="merge_required"
  elif has_action_state "dispatch_required"; then
    decision="dispatch_required"
  elif has_action_state "rebalance_required"; then
    decision="rebalance_required"
  else
    decision="continue_required"
  fi
  exit_code=10
fi

if [ "$FORMAT" = "json" ]; then
  jq -nc \
    --arg decision "$decision" \
    --argjson reasons "$reasons_json" \
    --argjson warnings "$warnings_json" \
    '{decision:$decision,reasons:$reasons,warnings:$warnings}'
else
  printf 'decision\t%s\n' "$decision"
  jq -r '.[] | ["reason", .alias, .priority, .reason, .count, .detail] | @tsv' <<< "$reasons_json"
  jq -r '.[] | ["warning", .alias, .priority, .reason, .count, .detail] | @tsv' <<< "$warnings_json"
fi

exit "$exit_code"
