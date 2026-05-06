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

ready_count_for_config() {
  local cfg=${1:?usage: ready_count_for_config <config>}
  local plan
  plan=$(bash "$TK/scripts/dispatch_plan.sh" "$cfg" --ready-only --json 2>/dev/null || printf '[]')
  jq -r 'length' <<< "$plan" 2>/dev/null || printf '0'
}

ready_top_for_config() {
  local cfg=${1:?usage: ready_top_for_config <config>}
  local plan
  plan=$(bash "$TK/scripts/dispatch_plan.sh" "$cfg" --ready-only --json 2>/dev/null || printf '[]')
  jq -r '.[0]? | if . == null then "" else "#\(.issue) \(.title)" end' <<< "$plan" 2>/dev/null || true
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
    ready_count=$(ready_count_for_config "$cfg")
    if [ "$ready_count" -gt 0 ]; then
      ready_top=$(ready_top_for_config "$cfg")
      if [ "$free" -gt 0 ]; then
        add_action_item "dispatch_required" "reason" "$alias" "$priority" "dispatch-required" \
          "${free} free agent(s), ${parkable} parkable agent(s), ${ready_count} ready issue(s); next=${ready_top}" "$ready_count"
      else
        add_action_item "rebalance_required" "reason" "$alias" "$priority" "rebalance-required" \
          "${parkable} parkable agent(s), ${ready_count} ready issue(s); next=${ready_top}" "$ready_count"
      fi
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
  if has_action_state "dispatch_required"; then
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
