#!/usr/bin/env bash
# scripts/portfolio_status.sh - summarize multi-product fleet capacity.
#
# Usage:
#   portfolio_status.sh <portfolio-config> [--tsv|--json] [--yolo-priority]
#
# A project is "external_wait" when open PRs are blocked only by pending checks
# or merge gates. Clean agents on default branches are "free"; clean agents
# whose work is already represented by an open PR are "parkable".
set -euo pipefail
TK=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

source "$TK/lib/portfolio_config.sh"
source "$TK/lib/process_safety.sh"
# shellcheck source=lib/lane_registry.sh
source "$TK/lib/lane_registry.sh"
source "$TK/lib/capacity_report.sh"

PORTFOLIO_ARG=${1:?usage: portfolio_status.sh <portfolio-config> [--tsv|--json|--lanes] [--yolo-priority]}
FORMAT="tsv"
LANES_ONLY=0
shift
while [ "$#" -gt 0 ]; do
  case "$1" in
    --tsv) FORMAT="tsv" ;;
    --json) FORMAT="json" ;;
    --lanes) LANES_ONLY=1 ;;
    --yolo-priority) PORTFOLIO_YOLO_PRIORITY=1 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done

# #312: --lanes prints the central capability-lane registry as JSON and exits.
# This is the discoverable surface for "what lanes does ORDO know about?" so
# dispatch authors can register a new lane and see it appear here without
# re-implementing lane discovery inside every consumer.
if [[ "$LANES_ONLY" -eq 1 ]]; then
  lane_items=()
  while IFS= read -r lane_id; do
    [[ -n "$lane_id" ]] || continue
    description=""
    env_prefix=""
    require_command=""
    if meta_line=$(lane_registry_meta "$lane_id"); then
      IFS='|' read -r _ description env_prefix require_command <<<"$meta_line"
    fi
    lane_items+=("$(jq -nc \
      --arg id "$lane_id" \
      --arg description "$description" \
      --arg env_prefix "$env_prefix" \
      --arg require_command "$require_command" \
      '{lane:$id,description:$description,env_prefix:$env_prefix,require_command:$require_command}')")
  done < <(lane_registry_lanes)
  printf '%s\n' "${lane_items[@]}" \
    | jq -s --arg schema_version "ordo.lane_registry.v1" \
        '{schema_version:$schema_version, lanes:.}'
  exit 0
fi

load_portfolio_config "$PORTFOLIO_ARG"
portfolio_require_priorities || exit 14
priority_mode=$(portfolio_priority_mode)
: "${PORTFOLIO_SINGLE_FLIGHT_TTL_SEC:=180}"
: "${PORTFOLIO_CHILD_TIMEOUT_SEC:=20}"

portfolio_partial=0
portfolio_health_signals=()
portfolio_lock_name="portfolio_status.${PORTFOLIO_NAME:-portfolio}"
portfolio_lock_acquired=0
if orch_single_flight_enter "$portfolio_lock_name" "$PORTFOLIO_SINGLE_FLIGHT_TTL_SEC"; then
  portfolio_lock_acquired=1
else
  portfolio_partial=1
  portfolio_health_signals+=("process_budget_degraded" "fork_risk")
  printf 'portfolio_status degraded: overlapping scan owner_pid=%s age=%ss\n' \
    "${ORCH_SINGLE_FLIGHT_OWNER_PID:-unknown}" "${ORCH_SINGLE_FLIGHT_OWNER_AGE:-unknown}" >&2
fi
cleanup_portfolio_lock() {
  if [[ "$portfolio_lock_acquired" -eq 1 ]]; then
    orch_single_flight_release "$(orch_lock_path "$portfolio_lock_name")"
  fi
}
trap cleanup_portfolio_lock EXIT

budget_signal=$(orch_process_budget_signal || true)
if [[ -n "$budget_signal" ]]; then
  orch_signal_list_add_csv "$budget_signal" portfolio_health_signals
  if [[ "$budget_signal" == *fork_risk* ]]; then
    portfolio_partial=1
  fi
fi

project_meta_json() {
  local cfg=${1:?usage: project_meta_json <config>}
  bash -c '
    set -euo pipefail
    cfg=$1
    # shellcheck disable=SC1090
    source "$cfg"
    jq -nc \
      --arg project "${PROJECT:-}" \
      --arg repo "${GH_REPO:-}" \
      --arg default_branch "${DEFAULT_BRANCH:-main}" \
      --arg config "$cfg" \
      "{project:\$project,repo:\$repo,default_branch:\$default_branch,config:\$config}"
  ' _ "$cfg"
}

project_summary_json() {
  local alias=${1:?usage: project_summary_json <alias> <config>}
  local cfg=${2:?usage: project_summary_json <alias> <config>}
  local priority=${3:?usage: project_summary_json <alias> <config> <priority>}
  local meta pool prs child_signal_json
  local -a child_signals=()

  meta=$(project_meta_json "$cfg")
  if ! pool=$(orch_run_timeout "$PORTFOLIO_CHILD_TIMEOUT_SEC" bash "$TK/scripts/agent_pool_status.sh" "$cfg" --json 2>/dev/null); then
    pool='[]'
    child_signals+=("process_budget_degraded")
  fi
  if ! printf '%s\n' "$pool" | jq -e 'type == "array"' >/dev/null 2>&1; then
    pool='[]'
    child_signals+=("process_budget_degraded")
  fi
  if ! prs=$(orch_run_timeout "$PORTFOLIO_CHILD_TIMEOUT_SEC" bash "$TK/scripts/pr_block_signals.sh" "$cfg" --json 2>/dev/null); then
    prs='[]'
    child_signals+=("process_budget_degraded")
  fi
  if ! printf '%s\n' "$prs" | jq -e 'type == "array"' >/dev/null 2>&1; then
    prs='[]'
    child_signals+=("process_budget_degraded")
  fi
  child_signal_json=$(printf '%s\n' "${child_signals[@]}" | jq -R . | jq -s 'map(select(length > 0)) | unique')

  jq -nc \
    --arg alias "$alias" \
    --arg priority "$priority" \
    --arg priority_mode "$priority_mode" \
    --argjson meta "$meta" \
    --argjson agents "$pool" \
    --argjson prs "$prs" \
    --argjson child_health "$child_signal_json" \
    '
      def has_signal($item; $signal):
        (($item.signals // []) | index($signal)) != null;
      def clean($agent):
        (($agent.dirty // "0") == "0");
      def on_default($agent):
        (($agent.branch // "") == ($meta.default_branch // "main"));
      def has_pr($agent):
        (($agent.pr // "") != "");
      def dirty_after_pr_agent($agent):
        has_signal($agent; "dirty_after_pr");
      def unsafe_agent($agent):
        (clean($agent) | not)
        or has_signal($agent; "conflict")
        or has_signal($agent; "needs-rebase")
        or has_signal($agent; "pr-behind")
        or has_signal($agent; "behind-upstream");
      def free_agent($agent):
        clean($agent) and (has_pr($agent) | not) and on_default($agent);
      def parkable_agent($agent):
        clean($agent) and has_pr($agent) and (unsafe_agent($agent) | not);
      def local_work_agent($agent):
        clean($agent)
        and (has_pr($agent) | not)
        and (($agent.branch // "") != "")
        and (on_default($agent) | not);
      def pr_signal_count($signal):
        [$prs[]? | select(has_signal(.; $signal))] | length;

      ($agents // []) as $a
      | ($prs // []) as $p
      | ([$a[]? | select(free_agent(.))]) as $free
      | ([$a[]? | select(parkable_agent(.))]) as $parkable
      | ([$a[]? | select(local_work_agent(.))]) as $local_work
      | ([$a[]? | select(unsafe_agent(.))]) as $blocked_agents
      | ([$a[]? | select(has_pr(.))]) as $submitted
      | ([$a[]? | select((.dirty // "0") != "0")]) as $dirty
      | ([$a[]? | select(dirty_after_pr_agent(.))]) as $dirty_after_pr
      | (pr_signal_count("merge-ready")) as $merge_ready
      | (pr_signal_count("ci-pending")) as $ci_pending
      | (pr_signal_count("ci-failed")) as $ci_failed
      | (pr_signal_count("needs-rebase")) as $needs_rebase
      | (pr_signal_count("merge-conflict")) as $conflicts
      | (pr_signal_count("changes-requested")) as $changes_requested
      | (pr_signal_count("review-required")) as $review_required
      | (pr_signal_count("deploy-gate-external-wait")) as $deploy_gate_wait
      | ($p | length) as $open_prs
      | (
          if (($dirty_after_pr | length) > 0) then "action_required"
          elif (($ci_failed + $needs_rebase + $conflicts + $changes_requested) > 0) then "action_required"
          elif ($merge_ready > 0) then "merge_ready"
          elif ($open_prs > 0 and $ci_pending > 0) then "external_wait"
          elif ($open_prs > 0 and $review_required > 0) then "review_wait"
          elif ($open_prs > 0) then "blocked_or_review"
          else "dispatchable"
          end
        ) as $gate_state
      | (
          if ($gate_state == "external_wait" and (($free | length) + ($parkable | length)) > 0) then "rebalance_recommended"
          elif (($free | length) > 0) then "dispatch_capacity_available"
          else ""
          end
        ) as $rebalance_signal
      | {
          alias: $alias,
          priority: ($priority | tonumber),
          priority_mode: $priority_mode,
          project: ($meta.project // $alias),
          repo: ($meta.repo // ""),
          default_branch: ($meta.default_branch // "main"),
          config: ($meta.config // ""),
          gate_state: $gate_state,
          rebalance_signal: $rebalance_signal,
          counts: {
            agents: ($a | length),
            free: ($free | length),
            parkable: ($parkable | length),
            submitted: ($submitted | length),
            dirty: ($dirty | length),
            dirty_after_pr: ($dirty_after_pr | length),
            local_work: ($local_work | length),
            blocked_agents: ($blocked_agents | length),
            open_prs: $open_prs,
            merge_ready: $merge_ready,
            ci_pending: $ci_pending,
            ci_failed: $ci_failed,
            needs_rebase: $needs_rebase,
            conflicts: $conflicts,
            review_required: $review_required,
            deploy_gate_wait: $deploy_gate_wait
          },
          health_signals: (
            ($child_health // [])
            + [$a[]?.signals[]? | select(. == "tmux_degraded" or . == "process_budget_degraded" or . == "fork_risk")]
            | unique
          ),
          agents: {
            free: ($free | map(.label)),
            parkable: ($parkable | map(.label)),
            local_work: ($local_work | map(.label)),
            dirty_after_pr: ($dirty_after_pr | map(.label)),
            blocked: ($blocked_agents | map(.label))
          },
          prs: $p
        }
    '
}

project_partial_summary_json() {
  local alias=${1:?usage: project_partial_summary_json <alias> <config> <priority>}
  local cfg=${2:?usage: project_partial_summary_json <alias> <config> <priority>}
  local priority=${3:?usage: project_partial_summary_json <alias> <config> <priority>}
  local meta health_json

  meta=$(project_meta_json "$cfg")
  health_json=$(printf '%s\n' "${portfolio_health_signals[@]}" | jq -R . | jq -s 'map(select(length > 0)) | unique')
  jq -nc \
    --arg alias "$alias" \
    --arg priority "$priority" \
    --arg priority_mode "$priority_mode" \
    --argjson meta "$meta" \
    --argjson health "$health_json" \
    '{
      alias: $alias,
      priority: ($priority | tonumber),
      priority_mode: $priority_mode,
      project: ($meta.project // $alias),
      repo: ($meta.repo // ""),
      default_branch: ($meta.default_branch // "main"),
      config: ($meta.config // ""),
      gate_state: "unknown",
      rebalance_signal: "process_budget_degraded",
      health_signals: $health,
      counts: {
        agents: 0,
        free: 0,
        parkable: 0,
        submitted: 0,
        dirty: 0,
        dirty_after_pr: 0,
        local_work: 0,
        blocked_agents: 0,
        open_prs: 0,
        merge_ready: 0,
        ci_pending: 0,
        ci_failed: 0,
        needs_rebase: 0,
        conflicts: 0,
        review_required: 0
      },
      agents: {free: [], parkable: [], local_work: [], dirty_after_pr: [], blocked: []},
      prs: []
    }'
}

json_items=()

while IFS='|' read -r alias cfg; do
  priority=$(portfolio_project_priority "$alias")
  if [[ "$portfolio_partial" -eq 1 ]]; then
    summary=$(project_partial_summary_json "$alias" "$cfg" "$priority")
    capacity=$(capacity_report_partial_for "$alias")
  else
    summary=$(project_summary_json "$alias" "$cfg" "$priority")
    capacity=$(capacity_report_from_summary "$summary")
  fi
  summary=$(jq -nc \
    --argjson summary "$summary" \
    --argjson capacity "$capacity" \
    '$summary + {capacity_report: $capacity}')
  json_items+=("$summary")
done < <(portfolio_project_entries)

json_report=$(printf '%s\n' "${json_items[@]}" | jq -s 'sort_by(-.priority, .alias)')

if [ "$FORMAT" = "json" ]; then
  printf '%s\n' "$json_report"
else
  printf 'alias\tpriority\tproject\trepo\tdefault_branch\tagents\tfree\tparkable\tsubmitted\tdirty\tlocal_work\topen_prs\tmerge_ready\tci_pending\tci_failed\tneeds_rebase\tconflicts\tgate_state\trebalance_signal\tfree_agents\tparkable_agents\thealth_signals\tdirty_after_pr\tdirty_after_pr_agents\n'
  printf '%s\n' "$json_report" | jq -r '.[] | [
    .alias,
    .priority,
    .project,
    .repo,
    .default_branch,
    .counts.agents,
    .counts.free,
    .counts.parkable,
    .counts.submitted,
    .counts.dirty,
    .counts.local_work,
    .counts.open_prs,
    .counts.merge_ready,
    .counts.ci_pending,
    .counts.ci_failed,
    .counts.needs_rebase,
    .counts.conflicts,
    .gate_state,
    .rebalance_signal,
    (.agents.free | join(",")),
    (.agents.parkable | join(",")),
    ((.health_signals // []) | join(",")),
    (.counts.dirty_after_pr // 0),
    ((.agents.dirty_after_pr // []) | join(","))
  ] | @tsv'
fi
