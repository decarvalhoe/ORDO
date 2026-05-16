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
# shellcheck source=lib/classifier_outage.sh
source "$TK/lib/classifier_outage.sh"

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
# #672 — adopted workdir metadata captured once per scan so every project
# summary can reconcile RBOK-style dedicated worktrees against the neutral
# fleet capacity buckets.
PORTFOLIO_ADOPTED_WORKDIRS_JSON=$(portfolio_adopted_workdirs_json 2>/dev/null || printf '[]')
: "${PORTFOLIO_SINGLE_FLIGHT_TTL_SEC:=180}"
: "${PORTFOLIO_CHILD_TIMEOUT_SEC:=20}"
# Backlog escalation thresholds (#353). Defaults catch the canonical
# "many drafts + many failed CI + one clean unblocker" pattern that the
# orchestrator was missing during the 2026-05-08 PRAXIS portfolio run.
# Operators can tune these per profile; values are project-neutral.
: "${PORTFOLIO_BACKLOG_MIN_OPEN_PRS:=4}"
: "${PORTFOLIO_BACKLOG_DRAFT_RATIO_PCT:=80}"
: "${PORTFOLIO_BACKLOG_FAILED_RATIO_PCT:=80}"

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

# #410: scan Claude CLI debug logs for fail-closed classifier events once per
# sweep. The summary is reused by every project's `project_summary_json` /
# `project_partial_summary_json` call so the per-sweep scan cost is paid once
# regardless of fleet size. A read failure or absent log dir produces an empty
# summary; the per-project counts then resolve to 0.
classifier_outage_empty_summary() {
  jq -nc '{total:0, scanned_files:0, by_session:{}, files:[], log_dirs:[], patterns_source:"unavailable"}'
}
CLASSIFIER_OUTAGE_SUMMARY=$(classifier_outage_summary_json 2>/dev/null \
  || classifier_outage_empty_summary)

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

# #410: extract the project's tmux session names from AGENT_PANES so the
# classifier-outage detector can attribute fail-closed events to projects
# without sourcing the project config in the parent shell.
#
# AGENT_PANES entries are `label|session:window.pane|workdir`; we slice
# everything before the first `:` of part 2. Sessions are de-duplicated
# because a multi-pane fleet may share a single tmux session across labels
# (e.g. `claude|shared:0.0|...`, `codex|shared:0.1|...`).
project_session_names() {
  local cfg=${1:?usage: project_session_names <config>}
  bash -c '
    set -euo pipefail
    cfg=$1
    # shellcheck disable=SC1090
    source "$cfg"
    if [ -n "${AGENT_PANES+x}" ] && [ "${#AGENT_PANES[@]}" -gt 0 ]; then
      for entry in "${AGENT_PANES[@]}"; do
        IFS="|" read -r _ pane _ <<<"$entry"
        [ -n "$pane" ] || continue
        sess=${pane%%:*}
        [ -n "$sess" ] || continue
        printf "%s\n" "$sess"
      done | sort -u
    fi
  ' _ "$cfg"
}

project_summary_json() {
  local alias=${1:?usage: project_summary_json <alias> <config>}
  local cfg=${2:?usage: project_summary_json <alias> <config>}
  local priority=${3:?usage: project_summary_json <alias> <config> <priority>}
  local meta pool prs child_signal_json sessions classifier_count adopted_for_alias
  local -a child_signals=()

  meta=$(project_meta_json "$cfg")
  adopted_for_alias=$(portfolio_adopted_workdirs_for_project "$alias" \
    "${PORTFOLIO_ADOPTED_WORKDIRS_JSON:-[]}" 2>/dev/null || printf '[]')
  # #410: per-project classifier-fallback count from the fleet-wide outage
  # summary (computed once in `compute_classifier_outage_summary`). A project
  # with no AGENT_PANES (or whose sessions never wrote a fail-closed line)
  # contributes 0; that is the desired default for fleets without Claude
  # debug logging enabled.
  sessions=$(project_session_names "$cfg" 2>/dev/null || true)
  classifier_count=$(printf '%s' "${CLASSIFIER_OUTAGE_SUMMARY:-$(classifier_outage_empty_summary)}" \
    | jq -r --arg sessions "$sessions" '
        ($sessions | split("\n") | map(select(length > 0))) as $names
        | [ $names[] as $n | (.by_session[$n] // 0) ] | add // 0
      ')
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
    --argjson backlog_min_open "${PORTFOLIO_BACKLOG_MIN_OPEN_PRS}" \
    --argjson backlog_draft_pct "${PORTFOLIO_BACKLOG_DRAFT_RATIO_PCT}" \
    --argjson backlog_failed_pct "${PORTFOLIO_BACKLOG_FAILED_RATIO_PCT}" \
    --argjson classifier_fallback_count "${classifier_count:-0}" \
    --argjson adopted_workdirs "${adopted_for_alias:-[]}" \
    '
      def has_signal($item; $signal):
        (($item.signals // []) | index($signal)) != null;
      # #672 — adopted workdir reconciliation.
      # An agent is adopted when its label, assigned workdir, or live pane
      # path matches a declared adopted-workdir record. We rewrite its
      # capacity_class to `adopted` so it is no longer counted as
      # switch_required or local_work drift, and stamp the record onto the
      # agent so downstream consumers can see why.
      def adopted_match($agent):
        ($adopted_workdirs // [])
        | map(select(
            (.label // "") == ($agent.label // "")
            or ((.workdir // "") != "" and (.workdir // "") == ($agent.assigned_workdir // ""))
            or ((.workdir // "") != "" and (.workdir // "") == ($agent.workdir // ""))
            or ((.workdir // "") != "" and (.workdir // "") == ($agent.live_pane_cwd // ""))
            or ((.pane // "") != "" and (.pane // "") == ($agent.pane // ""))
          ))
        | first;
      def adopted_apply($agent):
        (adopted_match($agent)) as $m
        | if $m == null then $agent
          else
            $agent
            + {
                adopted: $m,
                capacity_class: (
                  if ((($agent.capacity_class // "") == "switch_required")
                      or (($agent.capacity_class // "") == "local_work")
                      or (($agent.capacity_class // "") == "available")
                      or (($agent.capacity_class // "") == ""))
                  then "adopted"
                  else $agent.capacity_class
                  end
                ),
                signals: (
                  (($agent.signals // [])
                   - ["needs-product-switch", "switch_required"])
                  + ["adopted_workdir"]
                  | unique
                )
              }
          end;
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
      def cap_class($agent):
        ($agent.capacity_class // "");

      (($agents // []) | map(adopted_apply(.))) as $a
      | ($prs // []) as $p
      | ([$a[]? | select((.adopted // null) == null) | select(free_agent(.))]) as $free
      | ([$a[]? | select((.adopted // null) == null) | select(parkable_agent(.))]) as $parkable
      | ([$a[]? | select((.adopted // null) == null) | select(local_work_agent(.))]) as $local_work
      | ([$a[]? | select(unsafe_agent(.))]) as $blocked_agents
      | ([$a[]? | select(has_pr(.))]) as $submitted
      | ([$a[]? | select((.dirty // "0") != "0")]) as $dirty
      | ([$a[]? | select(dirty_after_pr_agent(.))]) as $dirty_after_pr
      | ([$a[]? | select(cap_class(.) == "available")]) as $cap_available
      | ([$a[]? | select(cap_class(.) == "dispatched")]) as $cap_dispatched
      | ([$a[]? | select(cap_class(.) == "reserved")]) as $cap_reserved
      | ([$a[]? | select(cap_class(.) == "switch_required")]) as $cap_switch
      | ([$a[]? | select(cap_class(.) == "dirty_clone")]) as $cap_dirty
      | ([$a[]? | select(cap_class(.) == "pane_not_ready")]) as $cap_pane_not_ready
      | ([$a[]? | select(cap_class(.) == "clone_missing")]) as $cap_clone_missing
      | ([$a[]? | select(cap_class(.) == "local_work")]) as $cap_local_work
      | ([$a[]? | select(cap_class(.) == "adopted")]) as $cap_adopted
      | (pr_signal_count("merge-ready")) as $merge_ready
      | (pr_signal_count("ci-pending")) as $ci_pending
      | (pr_signal_count("ci-failed")) as $ci_failed
      | (pr_signal_count("needs-rebase")) as $needs_rebase
      | (pr_signal_count("merge-conflict")) as $conflicts
      | (pr_signal_count("changes-requested")) as $changes_requested
      | (pr_signal_count("review-required")) as $review_required
      | (pr_signal_count("deploy-gate-external-wait")) as $deploy_gate_wait
      | (pr_signal_count("draft")) as $draft_prs
      # Per-project sample of failed/cancelled check NAMES (#346) so the
      # portfolio summary surfaces what failed, not just a count. Project-
      # level flaky/main-CI caveats applied elsewhere MUST NOT override
      # PR-level failed/cancelled state — this list comes straight from
      # the pr_block_signals rollup summary, the single source of truth.
      | ([$p[]? | (.ci_failed_check_names // [])[]?] | unique) as $ci_failed_check_samples
      | ($p | length) as $open_prs
      # Project ci_aggregate (#346): `failed_or_cancelled` wins over
      # `pending` wins over `success`. Computed from the count signals so
      # consumers can never misread "ci=success" when a single failed
      # check is present in any PR rollup.
      | (
          if ($ci_failed > 0)                   then "failed_or_cancelled"
          elif ($ci_pending > 0)                then "pending"
          elif ($open_prs > 0)                  then "success"
          else "no_open_prs"
          end
        ) as $ci_aggregate
      # Backlog escalation (#353): a draft PR is a "clean unblocker" when
      # its CI passes and no other blocker is reported. Such a PR would
      # become merge-ready the moment it is marked ready, and merging it
      # often unlocks the dependent failed-CI pack. Detect those at the
      # project level so the orchestrator can prioritize the unblock.
      | ([
          $p[]?
          | select(has_signal(.; "draft"))
          | select(has_signal(.; "ci-pass"))
          | select(has_signal(.; "ci-failed") | not)
          | select(has_signal(.; "ci-pending") | not)
          | select(has_signal(.; "merge-conflict") | not)
          | select(has_signal(.; "needs-rebase") | not)
          | select(has_signal(.; "changes-requested") | not)
          | select(has_signal(.; "review-required") | not)
          | select(has_signal(.; "merge-blocked") | not)
          | select(has_signal(.; "merge-state-unknown") | not)
        ]) as $clean_unblocker_list
      | ($clean_unblocker_list | length) as $clean_unblocker_prs
      | ([
          $p[]?
          | select(has_signal(.; "draft"))
          | select(has_signal(.; "ci-failed"))
        ] | length) as $failed_draft_prs
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
      # Backlog escalation signal (#353). The draft and failed ratios are
      # only meaningful once $open_prs crosses $backlog_min_open, so noise
      # from one or two stale PRs does not trip the escalation. A clean
      # unblocker always wins, even when ratios are low — that is the
      # canonical "merge me first" condition the issue calls out.
      | (
          if $clean_unblocker_prs > 0 then "clean_unblocker_available"
          elif $open_prs >= $backlog_min_open
            and (($draft_prs * 100) >= ($open_prs * $backlog_draft_pct))
            and (($ci_failed * 100) >= ($open_prs * $backlog_failed_pct))
            then "drafts_and_ci_blocked"
          elif $open_prs >= $backlog_min_open
            and (($draft_prs * 100) >= ($open_prs * $backlog_draft_pct))
            then "drafts_blocked"
          elif $open_prs >= $backlog_min_open
            and (($ci_failed * 100) >= ($open_prs * $backlog_failed_pct))
            then "ci_blocked"
          else ""
          end
        ) as $backlog_signal
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
          backlog_signal: $backlog_signal,
          ci_aggregate: $ci_aggregate,
          ci_failed_check_samples: $ci_failed_check_samples,
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
            deploy_gate_wait: $deploy_gate_wait,
            draft_prs: $draft_prs,
            failed_prs: $ci_failed,
            failed_draft_prs: $failed_draft_prs,
            clean_unblocker_prs: $clean_unblocker_prs,
            classifier_fallback_count: $classifier_fallback_count
          },
          clean_unblocker_pr_numbers: ($clean_unblocker_list | map(.pr // "")),
          capacity_reconciliation: {
            configured: ($a | length),
            available: ($cap_available | length),
            dispatched: ($cap_dispatched | length),
            reserved: ($cap_reserved | length),
            switch_required: ($cap_switch | length),
            dirty_clone: ($cap_dirty | length),
            pane_not_ready: ($cap_pane_not_ready | length),
            clone_missing: ($cap_clone_missing | length),
            local_work: ($cap_local_work | length),
            adopted: ($cap_adopted | length),
            available_labels: ($cap_available | map(.label)),
            dispatched_labels: ($cap_dispatched | map(.label)),
            reserved_labels: ($cap_reserved | map(.label)),
            switch_required_labels: ($cap_switch | map(.label)),
            dirty_clone_labels: ($cap_dirty | map(.label)),
            pane_not_ready_labels: ($cap_pane_not_ready | map(.label)),
            clone_missing_labels: ($cap_clone_missing | map(.label)),
            local_work_labels: ($cap_local_work | map(.label)),
            adopted_labels: ($cap_adopted | map(.label)),
            adopted_records: ($cap_adopted | map(.adopted // {label: .label, workdir: (.assigned_workdir // .workdir // "")}))
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
            blocked: ($blocked_agents | map(.label)),
            adopted: ($cap_adopted | map(.label))
          },
          prs: $p
        }
    '
}

project_partial_summary_json() {
  local alias=${1:?usage: project_partial_summary_json <alias> <config> <priority>}
  local cfg=${2:?usage: project_partial_summary_json <alias> <config> <priority>}
  local priority=${3:?usage: project_partial_summary_json <alias> <config> <priority>}
  local meta health_json sessions classifier_count

  meta=$(project_meta_json "$cfg")
  health_json=$(printf '%s\n' "${portfolio_health_signals[@]}" | jq -R . | jq -s 'map(select(length > 0)) | unique')
  # #410: same per-project classifier-fallback count as the full summary so
  # the partial (degraded-host) row carries the same field shape.
  sessions=$(project_session_names "$cfg" 2>/dev/null || true)
  classifier_count=$(printf '%s' "${CLASSIFIER_OUTAGE_SUMMARY:-$(classifier_outage_empty_summary)}" \
    | jq -r --arg sessions "$sessions" '
        ($sessions | split("\n") | map(select(length > 0))) as $names
        | [ $names[] as $n | (.by_session[$n] // 0) ] | add // 0
      ')
  jq -nc \
    --arg alias "$alias" \
    --arg priority "$priority" \
    --arg priority_mode "$priority_mode" \
    --argjson meta "$meta" \
    --argjson health "$health_json" \
    --argjson classifier_fallback_count "${classifier_count:-0}" \
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
      backlog_signal: "",
      ci_aggregate: "unknown",
      ci_failed_check_samples: [],
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
        review_required: 0,
        draft_prs: 0,
        failed_prs: 0,
        failed_draft_prs: 0,
        clean_unblocker_prs: 0,
        classifier_fallback_count: $classifier_fallback_count
      },
      clean_unblocker_pr_numbers: [],
      capacity_reconciliation: {
        configured: 0,
        available: 0,
        dispatched: 0,
        reserved: 0,
        switch_required: 0,
        dirty_clone: 0,
        pane_not_ready: 0,
        clone_missing: 0,
        local_work: 0,
        adopted: 0,
        available_labels: [],
        dispatched_labels: [],
        reserved_labels: [],
        switch_required_labels: [],
        dirty_clone_labels: [],
        pane_not_ready_labels: [],
        clone_missing_labels: [],
        local_work_labels: [],
        adopted_labels: [],
        adopted_records: []
      },
      agents: {free: [], parkable: [], local_work: [], dirty_after_pr: [], blocked: [], adopted: []},
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
  printf 'alias\tpriority\tproject\trepo\tdefault_branch\tagents\tfree\tparkable\tsubmitted\tdirty\tlocal_work\topen_prs\tmerge_ready\tci_aggregate\tci_pending\tci_failed\tci_failed_check_samples\tneeds_rebase\tconflicts\tgate_state\trebalance_signal\tfree_agents\tparkable_agents\thealth_signals\tdirty_after_pr\tdirty_after_pr_agents\tdraft_prs\tfailed_prs\tfailed_draft_prs\tclean_unblocker_prs\tbacklog_signal\tclean_unblocker_pr_numbers\tcap_configured\tcap_available\tcap_dispatched\tcap_reserved\tcap_switch_required\tcap_dirty_clone\tcap_pane_not_ready\tcap_clone_missing\tcap_local_work\tcap_adopted\tcap_available_agents\tcap_reserved_agents\tcap_switch_required_agents\tcap_adopted_agents\tclassifier_fallback_count\n'
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
    (.ci_aggregate // "unknown"),
    .counts.ci_pending,
    .counts.ci_failed,
    ((.ci_failed_check_samples // []) | join(",")),
    .counts.needs_rebase,
    .counts.conflicts,
    .gate_state,
    .rebalance_signal,
    (.agents.free | join(",")),
    (.agents.parkable | join(",")),
    ((.health_signals // []) | join(",")),
    (.counts.dirty_after_pr // 0),
    ((.agents.dirty_after_pr // []) | join(",")),
    (.counts.draft_prs // 0),
    (.counts.failed_prs // 0),
    (.counts.failed_draft_prs // 0),
    (.counts.clean_unblocker_prs // 0),
    (.backlog_signal // ""),
    ((.clean_unblocker_pr_numbers // []) | join(",")),
    (.capacity_reconciliation.configured // 0),
    (.capacity_reconciliation.available // 0),
    (.capacity_reconciliation.dispatched // 0),
    (.capacity_reconciliation.reserved // 0),
    (.capacity_reconciliation.switch_required // 0),
    (.capacity_reconciliation.dirty_clone // 0),
    (.capacity_reconciliation.pane_not_ready // 0),
    (.capacity_reconciliation.clone_missing // 0),
    (.capacity_reconciliation.local_work // 0),
    (.capacity_reconciliation.adopted // 0),
    ((.capacity_reconciliation.available_labels // []) | join(",")),
    ((.capacity_reconciliation.reserved_labels // []) | join(",")),
    ((.capacity_reconciliation.switch_required_labels // []) | join(",")),
    ((.capacity_reconciliation.adopted_labels // []) | join(",")),
    (.counts.classifier_fallback_count // 0)
  ] | @tsv'
fi
