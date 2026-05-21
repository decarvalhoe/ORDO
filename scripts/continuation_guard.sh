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

# #668: capture portfolio_status stderr so we can detect the
# "overlapping scan" degraded marker and extract the lock owner PID.
# portfolio_status logs `portfolio_status degraded: overlapping scan
# owner_pid=<pid> age=<sec>s` whenever it cannot acquire its
# single-flight lock, and then emits a partial JSON snapshot. A partial
# snapshot is not proof of a clean queue, so continuation_guard must
# refuse stop_ok while a prior scan is still in flight.
status_stderr_file=$(mktemp)
status_json=$(bash "$TK/scripts/portfolio_status.sh" "$ORCH_PORTFOLIO_CONFIG_PATH" --json "${PRIORITY_ARGS[@]}" 2> "$status_stderr_file")
status_stderr_content=$(cat "$status_stderr_file" 2>/dev/null || printf '')
rm -f "$status_stderr_file"

scan_overlap=0
scan_owner_pid="unknown"
scan_owner_age="unknown"
overlap_line=$(grep -F 'portfolio_status degraded: overlapping scan' <<< "$status_stderr_content" | tail -1 || true)
if [ -n "$overlap_line" ]; then
  scan_overlap=1
  parsed_pid=$(printf '%s' "$overlap_line" | sed -n 's/.*owner_pid=\([^ ]*\).*/\1/p')
  parsed_age=$(printf '%s' "$overlap_line" | sed -n 's/.*age=\([^ ]*\).*/\1/p')
  [ -n "$parsed_pid" ] && scan_owner_pid="$parsed_pid"
  [ -n "$parsed_age" ] && scan_owner_age="$parsed_age"
fi

# JSON-based fallback: stderr can be lost when callers redirect 2>/dev/null
# or pipe through wrappers. portfolio_status's partial-summary fingerprint
# is unambiguous: every project entry carries
# rebalance_signal=process_budget_degraded together with the fork_risk
# health signal. Detect that shape so the guard never falls through to
# stop_ok on a partial snapshot.
if [ "$scan_overlap" -eq 0 ]; then
  if jq -e '
    (type == "array")
    and (length as $total
         | ($total > 0)
         and (([.[] | select(
                  (.rebalance_signal // "") == "process_budget_degraded"
                  and ((.health_signals // []) | index("fork_risk") != null)
                )] | length) == $total))
  ' <<< "$status_json" >/dev/null 2>&1; then
    scan_overlap=1
  fi
fi

# Track which queues this guard run evaluated, so the orchestrator's
# status line and audit trail can name them explicitly (#379 AC: "the
# status line must say which queue was evaluated"). The PR queue is
# always consulted via portfolio_status; the issue queue is consulted
# when capacity exists; cross-repo portfolio is implied by multi-project
# input.
declare -A queues_evaluated_set=()
queues_evaluated_set["pr"]=1
project_count=$(jq -r 'length' <<< "$status_json")
if [ "${project_count:-0}" -ge 2 ]; then
  queues_evaluated_set["cross_repo_portfolio"]=1
fi

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
  local p0_p1_count p0_p1_csv assigned_orphan_count assigned_orphan_csv

  [ "$capacity" -gt 0 ] || return 0

  full_plan=$(full_plan_for_config "$cfg")
  queues_evaluated_set["issue"]=1
  atomize_count=$(jq -r '[.[]? | select(.status == "atomize" or .status == "stale_parent")] | length' <<< "$full_plan")
  shipped_suspect_count=$(jq -r '[.[]? | select(.status == "shipped_suspect")] | length' <<< "$full_plan")
  blocked_count=$(jq -r '[.[]? | select(.status == "blocked")] | length' <<< "$full_plan")
  # #764: when the ready queue is drained but issues are still flagged as
  # `assigned` to a GitHub login that does not map to any active fleet
  # slot, the dispatch surface is invisible to --ready-only forever. The
  # guard MUST surface this so the orchestrator's queue-resolver phase C
  # (reclaim_orphan_assignments.sh) can release the orphan and let the
  # row fall back to ready on the next dispatch_plan run.
  assigned_orphan_count=$(jq -r '[.[]? | select(.status == "assigned" and ((.assignees // []) | length > 0))] | length' <<< "$full_plan")
  assigned_orphan_csv=$(jq -r '[.[]? | select(.status == "assigned" and ((.assignees // []) | length > 0)) | "#\(.issue)/\((.assignees // []) | join(","))"] | join(";")' <<< "$full_plan")

  # #379 AC: when ready_count==0 but the full plan still carries
  # P0/P1 root-cause issues (atomize-needed or otherwise non-ready),
  # the orchestrator MUST surface them explicitly. Waiting for a single
  # PR is allowed only when every dispatchable P0/P1 is blocked with
  # explicit proof.
  p0_p1_count=$(jq -r '[.[]? | select((.priority == "P0" or .priority == "P1") and (.status != "shipped_suspect"))] | length' <<< "$full_plan")
  if [ "$p0_p1_count" -gt 0 ]; then
    p0_p1_csv=$(jq -r '[.[]? | select((.priority == "P0" or .priority == "P1") and (.status != "shipped_suspect")) | "\(.priority):#\(.issue)/\(.status)"] | join(",")' <<< "$full_plan")
    detail="ready_queue_empty; available_capacity=${capacity}; p0_p1_backlog=${p0_p1_count} (${p0_p1_csv}); action=atomize/unblock/dispatch root-cause issues before scheduling another idle poll"
    add_action_item "continue_required" "reason" "$alias" "$priority" "idle-with-p0-p1-backlog" "$detail" "$p0_p1_count"
  fi

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
  if [ "$assigned_orphan_count" -gt 0 ]; then
    detail="ready_queue_empty; available_capacity=${capacity}; assigned_issues=${assigned_orphan_count} (${assigned_orphan_csv}); action=reclaim_orphan_assignments.sh --apply (release assignees not in AGENT_GH_LOGINS so the row falls back to ready)"
    add_action_item "continue_required" "reason" "$alias" "$priority" "assigned-orphan-reclaim-required" "$detail" "$assigned_orphan_count"
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
    queues_evaluated_set["issue"]=1
    ready_count=$(jq -r 'length' <<< "$ready_plan")
    # #379 AC: highlight P0/P1 ready issues in the dispatch-required
    # detail so the orchestrator cannot silently downgrade them to
    # "wait for poll".
    ready_p0_p1_csv=$(jq -r '[.[]? | select(.priority == "P0" or .priority == "P1") | "\(.priority):#\(.issue)"] | join(",")' <<< "$ready_plan")
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
        dispatch_detail="agent=${agent} issue=${ready_item:-unknown}; available_capacity=${capacity} ready_issues=${ready_count}"
        if [ -n "$ready_p0_p1_csv" ]; then
          dispatch_detail+="; p0_p1_ready=${ready_p0_p1_csv}"
        fi
        add_action_item "dispatch_required" "reason" "$alias" "$priority" "dispatch-required" \
          "$dispatch_detail" 1
        ready_index=$((ready_index + 1))
      done

      for agent in "${parkable_agents[@]}"; do
        if [ "$ready_index" -ge "$ready_count" ]; then
          break
        fi
        ready_item=$(ready_item_for_plan "$ready_plan" "$ready_index")
        rebalance_detail="agent=${agent} issue=${ready_item:-unknown}; blocker=park-or-switch-required; action=auto_rebalance --apply; available_capacity=${capacity} ready_issues=${ready_count}"
        if [ -n "$ready_p0_p1_csv" ]; then
          rebalance_detail+="; p0_p1_ready=${ready_p0_p1_csv}"
        fi
        add_action_item "rebalance_required" "reason" "$alias" "$priority" "rebalance-required" \
          "$rebalance_detail" 1
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

# #668: surface the overlapping-scan condition as a reason so it appears
# in the standard reasons[] payload alongside the explicit decision
# override below. The detail carries the lock owner PID and concrete
# retry guidance — the orchestrator (or operator) must wait for the
# in-flight scan to complete before drawing any stop conclusion.
if [ "$scan_overlap" -eq 1 ]; then
  scan_detail="overlapping portfolio_status scan in flight; owner_pid=${scan_owner_pid} age=${scan_owner_age}; retry=rerun continuation_guard after the active scan finishes (typical wait: seconds) or after PORTFOLIO_SINGLE_FLIGHT_TTL_SEC (default 180s) expires; partial snapshot is not proof of a clean queue"
  add_item "reason" "_portfolio" "0" "portfolio-scan-overlap" "$scan_detail" 1
fi

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

# #668: scan_in_progress takes precedence over every other decision. A
# partial snapshot cannot be downgraded to stop_ok, nor can it justify
# a dispatch/merge/rebalance action because the JSON we are looking at
# is not the authoritative view of the portfolio.
if [ "$scan_overlap" -eq 1 ]; then
  decision="scan_in_progress"
  exit_code=10
fi

queues_evaluated_csv=""
for q in pr issue cross_repo_portfolio; do
  if [ -n "${queues_evaluated_set[$q]:-}" ]; then
    queues_evaluated_csv+="${queues_evaluated_csv:+,}${q}"
  fi
done

if [ "$FORMAT" = "json" ]; then
  jq -nc \
    --arg decision "$decision" \
    --arg queues "$queues_evaluated_csv" \
    --argjson scan_overlap "$scan_overlap" \
    --arg scan_owner_pid "$scan_owner_pid" \
    --arg scan_owner_age "$scan_owner_age" \
    --argjson reasons "$reasons_json" \
    --argjson warnings "$warnings_json" \
    '{decision:$decision,queues_evaluated:($queues|split(",")|map(select(length>0))),scan_overlap:($scan_overlap == 1),scan_owner_pid:$scan_owner_pid,scan_owner_age:$scan_owner_age,reasons:$reasons,warnings:$warnings}'
else
  printf 'decision\t%s\n' "$decision"
  printf 'queues_evaluated\t%s\n' "$queues_evaluated_csv"
  if [ "$scan_overlap" -eq 1 ]; then
    printf 'scan_overlap\ttrue\n'
    printf 'scan_owner_pid\t%s\n' "$scan_owner_pid"
    printf 'scan_owner_age\t%s\n' "$scan_owner_age"
  fi
  jq -r '.[] | ["reason", .alias, .priority, .reason, .count, .detail] | @tsv' <<< "$reasons_json"
  jq -r '.[] | ["warning", .alias, .priority, .reason, .count, .detail] | @tsv' <<< "$warnings_json"
fi

exit "$exit_code"
