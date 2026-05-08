#!/usr/bin/env bash
# lib/capacity_report.sh — derive structured capacity reports from portfolio
# state, so that orchestrator narratives never claim "all agents busy" from
# anecdotal pane inspection.
#
# The goal of this helper is to reduce capacity reasoning to a single JSON
# object computed from explicit, audit-able sources:
#
#   - the project agent pool already produced by `agent_pool_status.sh` and
#     summarized inside `scripts/portfolio_status.sh` (label sets for free,
#     parkable, local_work, blocked, dirty_after_pr);
#   - `state/<project>/assignments.json` records of dispatched work;
#   - explicit profile metadata (`ORDO_RESERVED_AGENTS`,
#     `ORDO_RESERVED_AGENTS_<ALIAS>`) for agent slots that must be excluded
#     from dispatch — the `orch` slot is NOT reserved by name convention;
#   - explicit profile metadata (`ORDO_SUPERVISOR_SESSIONS`) for tmux
#     sessions that act as control panes outside the agent fleet matrix.
#
# Public API:
#
#   capacity_report_from_summary <summary-json>
#       Emit a JSON capacity report on stdout. The summary is the per-project
#       object produced by `portfolio_status.sh project_summary_json`. Reads
#       the optional environment variables documented above plus the standard
#       `ORCH_STATE_BASE` for assignments lookup.
#
#   capacity_report_assignments_path <alias>
#       Echo the assignments.json path that capacity_report_from_summary will
#       consume (or an empty string when ORCH_STATE_BASE is unset).
#
# This file is sourced; it does nothing on its own.

capacity_report_assignments_path() {
  local alias=${1:?usage: capacity_report_assignments_path <alias>}
  local base="${ORCH_STATE_BASE:-}"
  if [[ -z "$base" ]]; then
    printf ''
    return 0
  fi
  printf '%s/%s/assignments.json' "$base" "$alias"
}

capacity_report_load_assignments() {
  local path=${1-}
  if [[ -n "$path" && -s "$path" ]]; then
    if jq -e 'type == "object"' "$path" >/dev/null 2>&1; then
      cat "$path"
      return 0
    fi
  fi
  printf '{}\n'
}

capacity_report_alias_var_suffix() {
  local alias=${1:?usage: capacity_report_alias_var_suffix <alias>}
  printf '%s' "$alias" | tr '[:lower:]' '[:upper:]' | tr -c '[:alnum:]' '_'
}

capacity_report_reserved_for() {
  local alias=${1:?usage: capacity_report_reserved_for <alias>}
  local suffix var val
  suffix=$(capacity_report_alias_var_suffix "$alias")
  var="ORDO_RESERVED_AGENTS_${suffix}"
  val="${!var:-}"
  if [[ -z "$val" ]]; then
    val="${ORDO_RESERVED_AGENTS:-}"
  fi
  printf '%s' "$val"
}

capacity_report_supervisor_sessions() {
  printf '%s' "${ORDO_SUPERVISOR_SESSIONS:-}"
}

capacity_report_csv_to_json() {
  local csv=${1-}
  if [[ -z "$csv" ]]; then
    printf '[]'
    return 0
  fi
  printf '%s' "$csv" | jq -Rc '
    split(",")
    | map(gsub("^[[:space:]]+|[[:space:]]+$"; ""))
    | map(select(length > 0))
    | unique
  '
}

capacity_report_from_summary() {
  local summary=${1:?usage: capacity_report_from_summary <summary-json>}
  local alias assignments_path assignments_json reserved_json supervisor_json

  alias=$(printf '%s' "$summary" | jq -r '.alias // ""')
  assignments_path=$(capacity_report_assignments_path "$alias")
  assignments_json=$(capacity_report_load_assignments "$assignments_path")
  reserved_json=$(capacity_report_csv_to_json "$(capacity_report_reserved_for "$alias")")
  supervisor_json=$(capacity_report_csv_to_json "$(capacity_report_supervisor_sessions)")

  jq -nc \
    --argjson summary "$summary" \
    --argjson assignments "$assignments_json" \
    --argjson reserved "$reserved_json" \
    --argjson supervisors "$supervisor_json" \
    --arg assignments_path "$assignments_path" \
    '
      ($summary.alias // "") as $alias
      | ($summary.agents.free // []) as $free_labels
      | ($summary.agents.parkable // []) as $parkable_labels
      | ($summary.agents.local_work // []) as $local_work_labels
      | ($summary.agents.blocked // []) as $blocked_labels
      | ($summary.agents.dirty_after_pr // []) as $dirty_after_pr_labels
      | ($reserved // []) as $reserved_set
      | ($supervisors // []) as $supervisor_set

      | (
          $assignments
          | to_entries
          | map({
              agent: .key,
              issue: (.value.issue // .value.ticket // null),
              branch: (.value.branch // null),
              workdir: (.value.workdir // null),
              dispatched_at: (.value.dispatched_at // null)
            })
        ) as $assignment_list
      | ($assignment_list | map(.agent)) as $assignment_agents

      | ($free_labels - $reserved_set) as $dispatch_free
      | ($parkable_labels - $reserved_set) as $dispatch_parkable

      # Switchable: an assignment record exists, but the live pool reports the
      # agent as free or parkable. The recorded assignment cannot prove
      # physical occupancy — the agent is either available now or its work
      # already lives in an open PR.
      | (
          [
            $assignment_list[]
            | select(
                (.agent | IN($free_labels[])) or
                (.agent | IN($parkable_labels[]))
              )
            | {agent: .agent, issue: .issue, source: (
                if (.agent | IN($free_labels[])) then "free-pane" else "parkable-pr" end
              )}
          ]
        ) as $switchable

      # Panes with work: agents whose live state implies in-flight work —
      # local-only branches, dirty-after-pr (uncommitted edits on a synced
      # branch), or otherwise blocked (dirty / behind / conflict).
      | (
          ($local_work_labels + $dirty_after_pr_labels + $blocked_labels)
          | unique
        ) as $panes_with_work

      | (
          $parkable_labels
          | map({agent: ., role: "parkable", evidence: "open_pr_no_active_work"})
        ) as $open_prs_no_active_work

      | (
          # busy_claim_valid: orchestrator may only narrate "all agents busy"
          # when free + parkable + switchable + non-reserved free panes are
          # all empty. Reserved slots are NOT counted as busy; supervisor
          # sessions are reported separately.
          (($dispatch_free | length) == 0)
          and (($dispatch_parkable | length) == 0)
          and (($switchable | length) == 0)
        ) as $busy_claim_valid

      | {
          alias: $alias,
          configured_slots: ($summary.counts.agents // 0),
          active_assignments: $assignment_list,
          active_assignments_count: ($assignment_list | length),
          panes_with_work: $panes_with_work,
          panes_with_work_count: ($panes_with_work | length),
          open_prs_no_active_work: $open_prs_no_active_work,
          open_prs_no_active_work_count: ($open_prs_no_active_work | length),
          parkable_pr_owners: $parkable_labels,
          free_pane_ready: $dispatch_free,
          free_pane_ready_count: ($dispatch_free | length),
          dispatch_parkable: $dispatch_parkable,
          switchable: $switchable,
          switchable_count: ($switchable | length),
          supervisor_sessions: $supervisor_set,
          supervisor_sessions_count: ($supervisor_set | length),
          reserved_agents: $reserved_set,
          reserved_agents_count: ($reserved_set | length),
          busy_claim_valid: $busy_claim_valid,
          evidence_sources: {
            assignments_path: (if $assignments_path == "" then null else $assignments_path end),
            portfolio_status: "scripts/portfolio_status.sh",
            agent_inventory: "lib/agent_inventory.sh"
          }
        }
    '
}

capacity_report_partial_for() {
  local alias=${1:?usage: capacity_report_partial_for <alias>}
  local assignments_path supervisor_json reserved_json
  assignments_path=$(capacity_report_assignments_path "$alias")
  reserved_json=$(capacity_report_csv_to_json "$(capacity_report_reserved_for "$alias")")
  supervisor_json=$(capacity_report_csv_to_json "$(capacity_report_supervisor_sessions)")

  jq -nc \
    --arg alias "$alias" \
    --arg assignments_path "$assignments_path" \
    --argjson reserved "$reserved_json" \
    --argjson supervisors "$supervisor_json" \
    '{
      alias: $alias,
      configured_slots: 0,
      active_assignments: [],
      active_assignments_count: 0,
      panes_with_work: [],
      panes_with_work_count: 0,
      open_prs_no_active_work: [],
      open_prs_no_active_work_count: 0,
      parkable_pr_owners: [],
      free_pane_ready: [],
      free_pane_ready_count: 0,
      dispatch_parkable: [],
      switchable: [],
      switchable_count: 0,
      supervisor_sessions: $supervisors,
      supervisor_sessions_count: ($supervisors | length),
      reserved_agents: $reserved,
      reserved_agents_count: ($reserved | length),
      busy_claim_valid: false,
      evidence_sources: {
        assignments_path: (if $assignments_path == "" then null else $assignments_path end),
        portfolio_status: "scripts/portfolio_status.sh",
        agent_inventory: "lib/agent_inventory.sh"
      },
      degraded: true
    }'
}
