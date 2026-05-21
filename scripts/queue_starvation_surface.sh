#!/usr/bin/env bash
# scripts/queue_starvation_surface.sh - queue resolver phase D (#765).
#
# Usage:
#   queue_starvation_surface.sh <project_short|config_path>
#     --cycle <N>
#     --continuation-guard-json <path>
#     [--apply|--dry-run]
#     [--tsv|--json]
#
# Purpose
#   When continuation_guard.sh emits continue_required action items
#   (atomize-required, shipped-suspect-review-required, unblock-required,
#   idle-with-p0-p1-backlog) for several consecutive cycles AND no
#   autoresolver (#762 auto-close, #763 auto-atomize, #764 reclaim)
#   produces fresh ready work, the supervisor is effectively starved.
#   Without an explicit alert, the operator sees only "cycle ran in
#   <5min, nothing to do" and never gets paged.
#
#   This phase D surface reads the continuation_guard JSON output for
#   the current cycle, decides whether the cycle is "starved", tracks
#   the consecutive count in state_dir/queue_starvation_cycles.json,
#   and once the count crosses ORCH_QUEUE_STARVATION_ALERT_CYCLES
#   (default 5):
#
#     * emits a QUEUE_STARVED_NO_RESOLUTION audit row carrying the
#       consecutive count and the backlog breakdown that drove it;
#     * appends a structured entry to state_dir/intervention_queue.md
#       so the operator's runbook (docs/operator-runbook.md) can be
#       followed top-to-bottom.
#
#   The counter resets when the next cycle is not starved (typically
#   ready_count > 0 again). Same-cycle reinvocations are idempotent —
#   the counter is bumped only when --cycle advances.
#
# Mode source of truth
#   ORCH_QUEUE_STARVATION_MODE=dry-run|apply (default: dry-run). CLI
#   flags --apply and --dry-run override the env. In dry-run mode no
#   state file is written and no intervention_queue.md row is appended;
#   the script still prints the audit row(s) it would emit so the
#   operator can preview the surface before opting in.
#
# Wiring
#   orch_loop integration is tracked as a separate follow-up (per the
#   ticket scope). This script is intentionally standalone so it can
#   be exercised against a captured continuation_guard JSON snapshot
#   without booting the supervisor loop.
#
# Output
#   `cycle / consecutive / state / action / threshold / detail` rows in
#   TSV (default) or JSON. Exactly one row per invocation describing
#   the decision (starved/non-starved, counter value, whether alert
#   fired).
set -euo pipefail
TK=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

# shellcheck source=../lib/config_resolver.sh
source "$TK/lib/config_resolver.sh"

CFG_ARG=${1:?usage: queue_starvation_surface.sh <project> --cycle N --continuation-guard-json FILE [--apply|--dry-run]}
shift

CYCLE=""
GUARD_JSON_PATH=""
MODE=""
FORMAT="tsv"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --cycle)
      CYCLE=${2:?missing value for --cycle}
      shift
      ;;
    --cycle=*) CYCLE=${1#--cycle=} ;;
    --continuation-guard-json)
      GUARD_JSON_PATH=${2:?missing value for --continuation-guard-json}
      shift
      ;;
    --continuation-guard-json=*) GUARD_JSON_PATH=${1#--continuation-guard-json=} ;;
    --apply) MODE="apply" ;;
    --dry-run) MODE="dry-run" ;;
    --tsv) FORMAT="tsv" ;;
    --json) FORMAT="json" ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done

if [ -z "$CYCLE" ]; then
  echo "queue_starvation_surface: --cycle is required" >&2
  exit 2
fi
case "$CYCLE" in
  ''|*[!0-9]*)
    echo "queue_starvation_surface: --cycle must be a non-negative integer" >&2
    exit 2
    ;;
esac

if [ -z "$GUARD_JSON_PATH" ]; then
  echo "queue_starvation_surface: --continuation-guard-json is required" >&2
  exit 2
fi
if [ ! -r "$GUARD_JSON_PATH" ]; then
  echo "queue_starvation_surface: cannot read $GUARD_JSON_PATH" >&2
  exit 2
fi

load_project_config "$CFG_ARG"

# shellcheck source=../lib/audit_log.sh
source "$TK/lib/audit_log.sh"
# shellcheck source=../lib/state_persist.sh
source "$TK/lib/state_persist.sh"

if [ -z "$MODE" ]; then
  MODE=${ORCH_QUEUE_STARVATION_MODE:-dry-run}
fi
case "$MODE" in
  dry-run|apply) ;;
  *)
    printf 'unknown queue-starvation mode: %s (expected dry-run|apply)\n' "$MODE" >&2
    exit 2
    ;;
esac

THRESHOLD=${ORCH_QUEUE_STARVATION_ALERT_CYCLES:-5}
case "$THRESHOLD" in
  ''|*[!0-9]*)
    printf 'ORCH_QUEUE_STARVATION_ALERT_CYCLES must be a non-negative integer, got: %s\n' "$THRESHOLD" >&2
    exit 2
    ;;
esac

guard_json=$(cat "$GUARD_JSON_PATH")
if ! jq -e 'type == "object"' >/dev/null 2>&1 <<<"$guard_json"; then
  echo "queue_starvation_surface: $GUARD_JSON_PATH is not a JSON object" >&2
  exit 2
fi

# A cycle is "starved" when the continuation_guard reports the loop
# cannot stop AND the active reasons describe an empty ready queue
# with spare capacity, rather than a dispatch/merge/rebalance action
# that would still make forward progress on its own.
#
# Concretely:
#   * decision must be `continue_required` (stop_ok would not be
#     starved; dispatch/merge/rebalance carry their own resolution
#     path and must not pollute the counter);
#   * at least one reason carries one of the ready-queue starvation
#     keywords surfaced by record_ready_queue_continuation.
decision=$(jq -r '.decision // ""' <<<"$guard_json")

starvation_reasons=$(jq -c '
  [ .reasons[]?
    | select(.reason == "atomize-required"
          or .reason == "shipped-suspect-review-required"
          or .reason == "unblock-required"
          or .reason == "idle-with-p0-p1-backlog")
  ]
' <<<"$guard_json")
starvation_reason_count=$(jq -r 'length' <<<"$starvation_reasons")

is_starved=0
if [ "$decision" = "continue_required" ] && [ "$starvation_reason_count" -gt 0 ]; then
  is_starved=1
fi

backlog_breakdown=$(jq -c '
  {
    atomize_required:           ([.[] | select(.reason == "atomize-required")            | .count] | add // 0),
    shipped_suspect_review:     ([.[] | select(.reason == "shipped-suspect-review-required") | .count] | add // 0),
    unblock_required:           ([.[] | select(.reason == "unblock-required")            | .count] | add // 0),
    idle_with_p0_p1_backlog:    ([.[] | select(.reason == "idle-with-p0-p1-backlog")     | .count] | add // 0)
  }
' <<<"$starvation_reasons")

backlog_breakdown_csv=$(jq -r '
  to_entries | map("\(.key)=\(.value)") | join(",")
' <<<"$backlog_breakdown")

# Last autoresolver actions visible in this guard snapshot, captured
# verbatim so the intervention queue carries actionable context (e.g.
# "atomize-required=3" tells the operator dispatch_plan --atomize
# would have somewhere to go).
last_autoresolver_actions=$(jq -r '
  [ .[]?
    | "\(.reason)=\(.count)"
  ] | join(",")
' <<<"$starvation_reasons")
[ -n "$last_autoresolver_actions" ] || last_autoresolver_actions="none"

state_name="queue_starvation_cycles"

current_state=$(state_get "$state_name")
prev_consecutive=$(jq -r '.consecutive_starved // 0' <<<"$current_state")
prev_last_cycle=$(jq -r '.last_cycle // -1' <<<"$current_state")
prev_first=$(jq -r '.first_starved_cycle // null' <<<"$current_state")
prev_last_alert=$(jq -r '.last_alert_cycle // null' <<<"$current_state")

# Same-cycle reinvocation: the counter must not advance, but the alert
# logic still needs to consider the existing consecutive count so a
# dry-run preview followed by an --apply on the same cycle produces a
# consistent verdict.
same_cycle=0
if [ "$prev_last_cycle" = "$CYCLE" ]; then
  same_cycle=1
fi

if [ "$is_starved" -eq 1 ]; then
  if [ "$same_cycle" -eq 1 ]; then
    new_consecutive=$prev_consecutive
    new_first=$prev_first
  else
    new_consecutive=$((prev_consecutive + 1))
    if [ "$prev_consecutive" -eq 0 ] || [ "$prev_first" = "null" ]; then
      new_first=$CYCLE
    else
      new_first=$prev_first
    fi
  fi
else
  new_consecutive=0
  new_first="null"
fi

alert_fired=0
if [ "$is_starved" -eq 1 ] && [ "$new_consecutive" -ge "$THRESHOLD" ]; then
  alert_fired=1
fi

if [ "$alert_fired" -eq 1 ]; then
  new_last_alert=$CYCLE
else
  if [ "$is_starved" -eq 0 ]; then
    new_last_alert="null"
  else
    new_last_alert=$prev_last_alert
  fi
fi

if [ "$is_starved" -eq 1 ]; then
  cycle_state="starved"
else
  cycle_state="not-starved"
fi

if [ "$alert_fired" -eq 1 ]; then
  action="alert"
elif [ "$is_starved" -eq 1 ]; then
  action="track"
else
  action="reset"
fi

audit "QUEUE_STARVATION_SURFACE cycle=${CYCLE} state=${cycle_state} consecutive=${new_consecutive} threshold=${THRESHOLD} action=${action} decision=${decision:-unknown} backlog=${backlog_breakdown_csv:-none} project=${PROJECT} mode=${MODE}"

if [ "$alert_fired" -eq 1 ]; then
  audit "QUEUE_STARVED_NO_RESOLUTION cycles=${new_consecutive} cycle=${CYCLE} threshold=${THRESHOLD} backlog_breakdown=${backlog_breakdown_csv:-none} last_autoresolver_actions=${last_autoresolver_actions} project=${PROJECT} mode=${MODE}"
fi

if [ "$MODE" = "apply" ]; then
  if [ "$new_first" = "null" ]; then
    first_arg="null"
  else
    first_arg="$new_first"
  fi
  if [ "$new_last_alert" = "null" ]; then
    last_alert_arg="null"
  else
    last_alert_arg="$new_last_alert"
  fi

  state_update "$state_name" "
    . + {
      consecutive_starved: ${new_consecutive},
      last_cycle: ${CYCLE},
      first_starved_cycle: ${first_arg},
      last_alert_cycle: ${last_alert_arg},
      last_state: \"${cycle_state}\",
      last_decision: \"${decision:-unknown}\",
      last_backlog_breakdown: ${backlog_breakdown}
    }
  "

  if [ "$alert_fired" -eq 1 ]; then
    intervention_path=$(state_file "intervention_queue.md")
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    {
      printf '\n## %s — QUEUE_STARVED_NO_RESOLUTION (cycle %s)\n\n' "$ts" "$CYCLE"
      printf -- '- project: %s\n' "$PROJECT"
      printf -- '- consecutive starved cycles: %s (threshold=%s)\n' "$new_consecutive" "$THRESHOLD"
      printf -- '- first starved cycle: %s\n' "$new_first"
      printf -- '- continuation_guard decision: %s\n' "${decision:-unknown}"
      printf -- '- backlog breakdown: %s\n' "${backlog_breakdown_csv:-none}"
      printf -- '- last autoresolver action items: %s\n' "$last_autoresolver_actions"
      printf -- '- recommended operator actions:\n'
      printf -- '  - review docs/operator-runbook.md (queue starvation section)\n'
      printf -- '  - run dispatch_plan --atomize --dry-run if atomize_required>0\n'
      printf -- '  - review shipped_suspect rows if shipped_suspect_review>0\n'
      printf -- '  - unblock or record explicit blockers if unblock_required>0\n'
      printf -- '  - add fresh P0/P1 requirements if idle_with_p0_p1_backlog>0\n'
      printf -- '  - if the autoresolvers cannot make progress, pause the loop\n'
    } >> "$intervention_path"
    audit "QUEUE_STARVATION_INTERVENTION appended path=${intervention_path} cycle=${CYCLE} consecutive=${new_consecutive}"
  fi
fi

emit_row() {
  local row
  row=$(jq -nc \
    --arg project "$PROJECT" \
    --argjson cycle "$CYCLE" \
    --argjson consecutive "$new_consecutive" \
    --argjson threshold "$THRESHOLD" \
    --arg state "$cycle_state" \
    --arg action "$action" \
    --arg decision "${decision:-unknown}" \
    --argjson backlog "$backlog_breakdown" \
    --arg mode "$MODE" \
    '{
      project:$project,
      cycle:$cycle,
      consecutive:$consecutive,
      threshold:$threshold,
      state:$state,
      action:$action,
      decision:$decision,
      backlog:$backlog,
      mode:$mode
    }')
  if [ "$FORMAT" = "json" ]; then
    printf '%s\n' "$row" | jq '.'
    return 0
  fi
  printf 'project\tcycle\tconsecutive\tthreshold\tstate\taction\tdecision\tbacklog\tmode\n'
  printf '%s\n' "$row" \
    | jq -r '[
        .project,
        (.cycle|tostring),
        (.consecutive|tostring),
        (.threshold|tostring),
        .state,
        .action,
        .decision,
        (.backlog | to_entries | map("\(.key)=\(.value)") | join(",")),
        .mode
      ] | @tsv'
}

emit_row
