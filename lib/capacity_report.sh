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

# capacity_report_busy_claim_aggregate <portfolio-json>
#   Reduce a `portfolio_status.sh --json` document into a single rollup
#   object that captures the portfolio-wide busy-claim verdict plus the
#   per-project facts an operator needs to triage a refusal:
#
#   {
#     "schema_version": "ordo.capacity_busy_claim.v1",
#     "busy_claim_valid": <bool>,           # true only when every project agrees
#     "free_pane_ready_total": <int>,
#     "switchable_total": <int>,
#     "parkable_total": <int>,
#     "supervisor_total": <int>,
#     "projects": [
#       {alias, busy_claim_valid, free_pane_ready_count, dispatch_parkable,
#        switchable_count, panes_with_work_count, supervisor_sessions_count,
#        evidence_sources}, …
#     ],
#     "refusals": [
#       {alias, free_pane_ready, dispatch_parkable, switchable},
#       …                                   # only projects that flipped the gate
#     ]
#   }
#
#   The refusals array is the operator's punch list: each entry names the
#   project that flipped `busy_claim_valid=false` and exposes the specific
#   capacity facts that did so.
capacity_report_busy_claim_aggregate() {
  local portfolio=${1:?usage: capacity_report_busy_claim_aggregate <portfolio-json>}
  printf '%s' "$portfolio" | jq -c '
    (map(.capacity_report // {})) as $caps
    | {
        schema_version: "ordo.capacity_busy_claim.v1",
        busy_claim_valid: (
          ($caps | length) > 0
          and all($caps[]; (.busy_claim_valid // false) == true)
        ),
        free_pane_ready_total: ([$caps[] | (.free_pane_ready_count // 0)] | add // 0),
        switchable_total:      ([$caps[] | (.switchable_count // 0)] | add // 0),
        parkable_total:        ([$caps[] | ((.parkable_pr_owners // []) | length)] | add // 0),
        supervisor_total:      ([$caps[] | (.supervisor_sessions_count // 0)] | add // 0),
        projects: (map({
          alias:                     (.alias // .capacity_report.alias // ""),
          busy_claim_valid:          (.capacity_report.busy_claim_valid // false),
          free_pane_ready_count:     (.capacity_report.free_pane_ready_count // 0),
          free_pane_ready:           (.capacity_report.free_pane_ready // []),
          dispatch_parkable:         (.capacity_report.dispatch_parkable // []),
          switchable_count:          (.capacity_report.switchable_count // 0),
          switchable:                (.capacity_report.switchable // []),
          panes_with_work_count:     (.capacity_report.panes_with_work_count // 0),
          supervisor_sessions_count: (.capacity_report.supervisor_sessions_count // 0),
          evidence_sources:          (.capacity_report.evidence_sources // {})
        })),
        refusals: (
          map(select((.capacity_report.busy_claim_valid // false) != true)
              | {
                  alias:             (.alias // .capacity_report.alias // ""),
                  free_pane_ready:   (.capacity_report.free_pane_ready // []),
                  dispatch_parkable: (.capacity_report.dispatch_parkable // []),
                  switchable:        (.capacity_report.switchable // []),
                  evidence_sources:  (.capacity_report.evidence_sources // {})
                })
        )
      }
  '
}

# capacity_report_busy_claim_render <portfolio-json>
#   Human-readable rollup for stdout. One header line + one line per
#   project + a single verdict line. Every line carries the alias so
#   operators can grep without parsing JSON.
capacity_report_busy_claim_render() {
  local portfolio=${1:?usage: capacity_report_busy_claim_render <portfolio-json>}
  local rollup
  rollup=$(capacity_report_busy_claim_aggregate "$portfolio")
  printf '%s' "$rollup" | jq -r '
    "# capacity_busy_claim schema=\(.schema_version) verdict=\(.busy_claim_valid) free_total=\(.free_pane_ready_total) switchable_total=\(.switchable_total) parkable_total=\(.parkable_total) supervisor_total=\(.supervisor_total)",
    (.projects[] |
      "capacity_busy_claim alias=\(.alias) busy_claim_valid=\(.busy_claim_valid) free=\(.free_pane_ready_count) parkable=\(.dispatch_parkable | length) switchable=\(.switchable_count) panes_with_work=\(.panes_with_work_count) supervisor=\(.supervisor_sessions_count) assignments_path=\(.evidence_sources.assignments_path // "null")"
    ),
    "capacity_busy_claim verdict=\(.busy_claim_valid)"
  '
}

# capacity_report_busy_claim_assert <portfolio-json> [<context>]
#   Operator-callable gate: render the rollup, emit a structured audit
#   line, and exit non-zero when the portfolio-wide
#   `busy_claim_valid` is false. Refusal exit code is
#   `ORCH_CAPACITY_BUSY_CLAIM_REFUSED_EXIT_CODE` (default 87).
#
#   The audit shape is:
#     CAPACITY_BUSY_CLAIM action=<assert|refuse>
#       verdict=<bool> context=<tag>
#       free_total=<n> switchable_total=<n> parkable_total=<n>
#       supervisor_total=<n> refusing_aliases=<csv>
#
#   Callers that just want the rollup printed without a refusal can use
#   `capacity_report_busy_claim_render`. The assert path is what the
#   orchestrator narrative invokes BEFORE saying "all agents busy".
: "${ORCH_CAPACITY_BUSY_CLAIM_REFUSED_EXIT_CODE:=87}"
capacity_report_busy_claim_assert() {
  local portfolio=${1:?usage: capacity_report_busy_claim_assert <portfolio-json> [<context>]}
  local context=${2:-capacity_busy_claim}
  local rollup
  rollup=$(capacity_report_busy_claim_aggregate "$portfolio")

  local verdict free_total switchable_total parkable_total supervisor_total refusing
  verdict=$(printf '%s' "$rollup" | jq -r '.busy_claim_valid')
  free_total=$(printf '%s' "$rollup" | jq -r '.free_pane_ready_total')
  switchable_total=$(printf '%s' "$rollup" | jq -r '.switchable_total')
  parkable_total=$(printf '%s' "$rollup" | jq -r '.parkable_total')
  supervisor_total=$(printf '%s' "$rollup" | jq -r '.supervisor_total')
  refusing=$(printf '%s' "$rollup" | jq -r '[.refusals[].alias] | join(",")')

  local action=assert
  if [[ "$verdict" != "true" ]]; then
    action=refuse
  fi

  local audit_msg
  audit_msg=$(printf 'CAPACITY_BUSY_CLAIM action=%s verdict=%s context=%s free_total=%s switchable_total=%s parkable_total=%s supervisor_total=%s refusing_aliases=%s' \
    "$action" "$verdict" "$context" \
    "$free_total" "$switchable_total" "$parkable_total" "$supervisor_total" \
    "${refusing:-none}")
  if declare -F audit >/dev/null 2>&1; then
    audit "$audit_msg"
  else
    printf 'AUDIT LOG: %s %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$audit_msg" >&2
  fi

  capacity_report_busy_claim_render "$portfolio"

  if [[ "$verdict" != "true" ]]; then
    return "$ORCH_CAPACITY_BUSY_CLAIM_REFUSED_EXIT_CODE"
  fi
  return 0
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
