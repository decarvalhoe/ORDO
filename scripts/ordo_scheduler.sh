#!/usr/bin/env bash
# scripts/ordo_scheduler.sh — operator entry point of the durable scheduler (#810, epic #806).
#
# Usage:
#   ordo_scheduler.sh <project_short|config_path> <command> [args...] [--json]
#
# Commands:
#   tick [--max-picks N]      one scheduling pass: sweep stale leases, apply
#                             timeouts and wait deadlines, heartbeat the leases
#                             this worker owns, pick queued runs up to the
#                             fan-out limit (ORDO_SCHED_MAX_FANOUT)
#   run-once                  a tick limited to a single pick (manual stepping)
#   enqueue --title T [--ticket REF] [--priority N] [--budget JSON]
#           [--metadata JSON] [--depends-on run_a,run_b] [--readiness JSON]
#           [--not-before TS] [--expires-at TS] [--max-retries N]
#           [--runtime-target T --text-file F] [--run-id ID]
#                             create a queued run (prints its id and budgets)
#   resume <run_id> [--requeue] [--reason R]
#                             re-lease a waiting/blocked/approval_required run
#                             (or put it back in the queue with --requeue);
#                             fail-closed when the run is not ready (exit 3)
#   cancel <run_id> [--reason R]
#                             cancel any non-terminal run and release its lease
#   recover                   rebuild projections, expire stale leases, requeue
#                             runs whose local owner process is gone
#   status [run_id]           capacity, counts and per-run summary (or one run)
#
# The command word may appear anywhere after the project: the unified CLI
# appends it (`ordo resume <project> <run_id>` runs
# `ordo_scheduler.sh <project> <run_id> resume`).
#
# Output is JSON with --json (the `ordo` CLI passes it through); without it a
# short human summary is printed. Errors are ONE JSON line on stderr and the
# exit code follows the agentic-control-plane table (docs/exit-codes.md):
# 2 usage, 3 refused/not ready, 4 not found, 5 invalid transition,
# 7 budget exhausted, 8 lease lost. Reference: docs/architecture/scheduler.md.
#
# Lease ownership: leases are owned by <ORDO_SCHED_WORKER_ID>@<host>:<pid>.
# The pid defaults to this script's parent (the supervisor loop or the
# operator shell) so `recover` can tell a dead owner from a live one.
set -euo pipefail

TK="${TK:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
export TK

ORDO_SCHED_COMMANDS="tick run-once enqueue resume cancel recover status"

usage() {
  sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

sched_error() {
  # sched_error <code> <message> [details-json] -> prints the error object, returns the exit code
  local code=$1 message=$2 details=${3:-{\}}
  if declare -F ordo_contracts_error >/dev/null 2>&1; then
    ordo_contracts_error scheduler "$code" "$message" "$details"
    return $?
  fi
  printf '{"error":{"code":"%s","message":"%s","module":"scheduler","details":%s}}\n' "$code" "$message" "$details" >&2
  case "$code" in
    usage|bad_argument|unknown_command) return 2 ;;
    not_found) return 4 ;;
    *) return 1 ;;
  esac
}

is_command() {
  local word=$1 c
  for c in $ORDO_SCHED_COMMANDS; do
    [[ "$c" == "$word" ]] && return 0
  done
  return 1
}

PROJECT_ARG=""
COMMAND=""
JSON=0
ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --json)
      JSON=1
      shift
      ;;
    --requeue)
      ARGS+=("$1")
      shift
      ;;
    --*)
      # Every other option takes a value; keep the pair together.
      if [[ $# -lt 2 ]]; then
        sched_error usage "option $1 requires a value" "$(printf '{"option":"%s"}' "$1")"
        exit $?
      fi
      ARGS+=("$1" "$2")
      shift 2
      ;;
    *)
      if [[ -z "$PROJECT_ARG" ]]; then
        PROJECT_ARG=$1
      elif [[ -z "$COMMAND" ]] && is_command "$1"; then
        COMMAND=$1
      else
        ARGS+=("$1")
      fi
      shift
      ;;
  esac
done

if [[ -z "$PROJECT_ARG" ]]; then
  usage >&2
  sched_error usage "missing <project>" '{"hint":"ordo_scheduler.sh <project> <command> [args]"}'
  exit $?
fi
if [[ -z "$COMMAND" ]]; then
  usage >&2
  sched_error usage "missing <command> (one of: ${ORDO_SCHED_COMMANDS})" \
    "$(printf '{"known":"%s"}' "$ORDO_SCHED_COMMANDS")"
  exit $?
fi

# shellcheck disable=SC1091
source "$TK/lib/config_resolver.sh"
# Resolve first: load_project_config dies inside the resolver on a missing
# path, before this script could map it to a structured not_found.
if ! resolve_config_path "$PROJECT_ARG" >/dev/null 2>&1; then
  sched_error not_found "project config not found: ${PROJECT_ARG}" "$(printf '{"project":"%s"}' "$PROJECT_ARG")"
  exit $?
fi
load_project_config "$PROJECT_ARG"
# shellcheck disable=SC1091
source "$TK/lib/audit_log.sh"
# shellcheck disable=SC1091
source "$TK/lib/state_persist.sh"
# shellcheck disable=SC1091
source "$TK/lib/ordo_scheduler.sh"

: "${ORDO_SCHED_WORKER_PID:=$PPID}"
export ORDO_SCHED_WORKER_PID

# Operators act as operators: resume/cancel/enqueue carry an operator actor
# unless the caller passed --actor explicitly.
operator_actor() {
  printf '{"type":"operator","id":"%s"}' "${ORDO_OPERATOR:-${USER:-operator}}"
}

has_actor_opt() {
  local a
  for a in "${ARGS[@]+"${ARGS[@]}"}"; do
    [[ "$a" == "--actor" ]] && return 0
  done
  return 1
}

# Human rendering of the JSON result. --json prints the object verbatim.
render() {
  local json=$1
  if [[ "$JSON" == 1 ]]; then
    printf '%s\n' "$json"
    return 0
  fi
  case "$COMMAND" in
    status)
      if printf '%s' "$json" | jq -e 'has("runs")' >/dev/null 2>&1; then
        printf '%s' "$json" | jq -r '
          "scheduler status now=\(.now) worker=\(.worker) capacity=\(.capacity.in_use)/\(.capacity.max_fanout) available=\(.capacity.available)",
          "counts: \(.counts | to_entries | map("\(.key)=\(.value)") | join(" "))",
          (.runs[] | "\(.run_id) \(.state) prio=\(.priority // "-") attempts=\(.attempts) not_before=\(.not_before // "-") lease=\(.lease.owner // "-") exhausted=\(.exhausted | join(",") | if . == "" then "-" else . end) title=\(.title // "-")")'
      else
        printf '%s' "$json" | jq -r '"\(.run_id) \(.state) prio=\(.priority // "-") attempts=\(.attempts) ready=\(.readiness.ready) (\(.readiness.reason)) lease=\(.lease.owner // "-") exhausted=\(.budgets.exhausted | join(",") | if . == "" then "-" else . end)"'
      fi
      ;;
    tick|run-once)
      printf '%s' "$json" | jq -r '"tick now=\(.now) worker=\(.worker) slots_used=\(.slots_used_before) capacity=\(.capacity) picked=\(.picks) expired_leases=\(.expired_leases | length) requeued=\(.requeued | length) failed=\(.failed | length) expired=\(.expired | length) timed_out=\(.timed_out | length) heartbeats=\(.heartbeats | length) skipped=\(.skipped | length) errors=\(.errors | length)",
        (.picked[] | "picked \(.run_id) lease=\(.lease_id) attempt=\(.attempt_no)"),
        (.requeued[] | "requeued \(.run_id) reason=\(.reason) not_before=\(.not_before)"),
        (.failed[] | "\(.action) \(.run_id) reason=\(.reason)"),
        (.skipped[] | "skipped \(.run_id) reason=\(.reason)")'
      ;;
    recover)
      printf '%s' "$json" | jq -r '"recover rebuilt=\(.rebuilt) expired_leases=\(.expired_leases) reconciled=\(.reconciled | length) repaired=\(.repaired | length) remote=\(.remote | length) errors=\(.errors | length)",
        (.reconciled[] | "reconciled \(.run_id) action=\(.action) reason=\(.reason)")'
      ;;
    *)
      printf '%s' "$json" | jq -r '"\(.run_id) \(.state)" + (if .reason then " reason=\(.reason)" else "" end) + (if .lease_id then " lease=\(.lease_id)" else "" end)'
      ;;
  esac
}

result=""
rc=0
case "$COMMAND" in
  tick)
    result=$(ordo_scheduler_tick "${ARGS[@]+"${ARGS[@]}"}") || rc=$?
    ;;
  run-once)
    result=$(ordo_scheduler_tick --max-picks 1 "${ARGS[@]+"${ARGS[@]}"}") || rc=$?
    ;;
  enqueue)
    if has_actor_opt; then
      result=$(ordo_scheduler_enqueue "${ARGS[@]+"${ARGS[@]}"}") || rc=$?
    else
      result=$(ordo_scheduler_enqueue --actor "$(operator_actor)" "${ARGS[@]+"${ARGS[@]}"}") || rc=$?
    fi
    ;;
  resume|cancel)
    fn="ordo_scheduler_${COMMAND}"
    if [[ "${#ARGS[@]}" -eq 0 || "${ARGS[0]}" == --* ]]; then
      sched_error usage "${COMMAND} needs a <run_id>" "$(printf '{"command":"%s"}' "$COMMAND")"
      exit $?
    fi
    run_id=${ARGS[0]}
    rest=("${ARGS[@]:1}")
    if has_actor_opt; then
      result=$("$fn" "$run_id" "${rest[@]+"${rest[@]}"}") || rc=$?
    else
      result=$("$fn" "$run_id" --actor "$(operator_actor)" "${rest[@]+"${rest[@]}"}") || rc=$?
    fi
    ;;
  recover)
    result=$(ordo_scheduler_recover "${ARGS[@]+"${ARGS[@]}"}") || rc=$?
    ;;
  status)
    result=$(ordo_scheduler_status "${ARGS[@]+"${ARGS[@]}"}") || rc=$?
    ;;
esac

if [[ -n "$result" ]]; then
  render "$result"
fi
exit "$rc"
