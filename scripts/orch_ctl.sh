#!/usr/bin/env bash
# orch_ctl.sh — control the running orch_loop.sh.
#
# Usage:
#   bash orch_ctl.sh <project> <command>
#
# Commands:
#   status           Show cycle count, last activity, paused state
#   pause            Pause the loop after the current cycle and wait (SIGUSR1)
#   resume           Resume paused loop (SIGUSR2)
#   run-now          Force the next cycle to run immediately (SIGUSR2)
#   stop             Clean shutdown after current cycle and wait (SIGTERM)
#   tail             tail -f the loop log
#   reset-cycles     Reset cycle counter to 0
#   reset-state      WARNING: clear all assignments + ci_watcher_seen

set -euo pipefail
TK="${TK:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
PROJECT_ARG=${1:?usage: orch_ctl.sh <project> <command>}
CMD=${2:?usage: orch_ctl.sh <project> <command>}

source "$TK/lib/config_resolver.sh"
source "$TK/lib/process_safety.sh"
load_project_config "$PROJECT_ARG"
# shellcheck disable=SC1091
source "$TK/lib/audit_log.sh"

# Find PIDs of running `orch_loop.sh <project>` processes via exact argv match.
# Why: the previous `pgrep -af "orch_loop.sh $PROJECT"` matched any command line
# that happened to contain that substring (transient pgrep/awk pipelines, shell
# histories, or unrelated commands referencing the script in a comment),
# producing false-positive "alive" PIDs that disappeared on follow-up `ps`.
# We scan /proc directly and require argv[i] basename == "orch_loop.sh" with
# argv[i+1] == project; we exclude our own PID so the status command cannot
# match its own enumeration.
#
# Note (merge #105 + #136): the older pgrep-based path used
# orch_run_timeout from lib/process_safety.sh as a soft circuit-breaker;
# find_loop_pids is inherently bounded (pure /proc scan, no fork) and
# supersedes that wrapper here. process_safety.sh remains shipped for
# other callers that need shell-out timeouts.
find_loop_pids() {
  local project=$1
  local proc_dir=${ORCH_PROC_DIR:-/proc}
  local self=$$
  local pid_dir pid arg base i
  local -a argv
  for pid_dir in "$proc_dir"/[0-9]*; do
    [[ -e "$pid_dir" ]] || continue
    pid=${pid_dir##*/}
    [[ "$pid" == "$self" ]] && continue
    [[ -r "$pid_dir/cmdline" ]] || continue
    if ! mapfile -d '' -t argv < "$pid_dir/cmdline" 2>/dev/null; then
      continue
    fi
    [[ ${#argv[@]} -ge 2 ]] || continue
    for ((i = 0; i < ${#argv[@]} - 1; i++)); do
      arg=${argv[i]}
      base=${arg##*/}
      if [[ "$base" == "orch_loop.sh" && "${argv[i+1]}" == "$project" ]]; then
        printf '%s\n' "$pid"
        break
      fi
    done
  done
}

# Render `last_activity` epoch with an elapsed-time annotation.
# Why: the previous one-liner used `date '+%FT%TZ (%s ago)'`, where `%s` is the
# date format specifier for the *input* epoch — so the annotation printed e.g.
# "1778100325 ago" instead of "5s ago". We compute now-ts ourselves.
format_last_activity() {
  local ts=$1
  if ! [[ "$ts" =~ ^[0-9]+$ ]] || [[ "$ts" -le 0 ]]; then
    printf 'never'
    return
  fi
  local now=${ORCH_NOW_OVERRIDE:-$(date -u +%s)}
  local elapsed=$((now - ts))
  local label
  if (( elapsed < 0 )); then
    label="in the future"
  elif (( elapsed < 60 )); then
    label="${elapsed}s ago"
  elif (( elapsed < 3600 )); then
    label="$((elapsed / 60))m $((elapsed % 60))s ago"
  elif (( elapsed < 86400 )); then
    label="$((elapsed / 3600))h $((elapsed % 3600 / 60))m ago"
  else
    label="$((elapsed / 86400))d $((elapsed % 86400 / 3600))h ago"
  fi
  printf '%s (%s)' "$(date -u -d "@$ts" '+%FT%TZ')" "$label"
}

mapfile -t LOOP_PID_ARRAY < <(find_loop_pids "$PROJECT")
LOOP_PIDS="${LOOP_PID_ARRAY[*]:-}"

require_running() {
  if [[ ${#LOOP_PID_ARRAY[@]} -eq 0 ]]; then
    echo "no orch_loop.sh process running for project=$PROJECT" >&2
    exit 1
  fi
}

wait_timeout() {
  local timeout=${ORCH_CTL_WAIT_TIMEOUT:-30}
  if ! [[ "$timeout" =~ ^[0-9]+$ ]] || (( timeout < 1 )); then
    echo "ORCH_CTL_WAIT_TIMEOUT must be a positive integer number of seconds" >&2
    exit 2
  fi
  printf '%s' "$timeout"
}

pause_barrier_reached() {
  local state=$1
  local -a pids
  [[ -f "$state/orch.paused" ]] && return 0
  mapfile -t pids < <(find_loop_pids "$PROJECT")
  [[ ${#pids[@]} -eq 0 ]]
}

stop_barrier_reached() {
  local -a pids
  mapfile -t pids < <(find_loop_pids "$PROJECT")
  [[ ${#pids[@]} -eq 0 ]]
}

wait_for_barrier() {
  local label=$1
  shift
  local timeout interval deadline
  timeout=$(wait_timeout)
  interval=${ORCH_CTL_WAIT_INTERVAL:-1}
  deadline=$((SECONDS + timeout))

  while true; do
    if "$@"; then
      return 0
    fi
    if (( SECONDS >= deadline )); then
      echo "$label not acknowledged within ${timeout}s" >&2
      return 1
    fi
    sleep "$interval"
  done
}

case "$CMD" in
  status)
    state="$(state_dir)"
    cycles=$(cat "$state/orch.cycle_count" 2>/dev/null || echo 0)
    last_act=$(cat "$state/orch.last_activity" 2>/dev/null || echo 0)
    paused=$([[ -f "$state/orch.paused" ]] && echo true || echo false)
    n_assigned=$(jq 'to_entries | length' "$state/assignments.json" 2>/dev/null || echo 0)
    if [[ -n "$LOOP_PIDS" ]]; then
      pid_str="alive (pid=$LOOP_PIDS)"
    else
      pid_str="NOT RUNNING"
    fi
    echo "project:        $PROJECT"
    echo "loop:           $pid_str"
    echo "cycles_run:     $cycles"
    echo "paused:         $paused"
    echo "assignments:    $n_assigned"
    echo "last_activity:  $(format_last_activity "$last_act")"
    echo "log:            $ORCH_LOG_DIR/$PROJECT-orch-loop.log"
    echo "audit log:      $ORCH_LOG_DIR/$PROJECT.log"
    echo "state dir:      $state"
    ;;
  pause)
    require_running
    state="$(state_dir)"
    kill -USR1 "${LOOP_PID_ARRAY[@]}"
    echo "pause signal sent to $LOOP_PIDS"
    wait_for_barrier "pause" pause_barrier_reached "$state"
    echo "pause acknowledged for project=$PROJECT"
    ;;
  resume|run-now)
    require_running
    kill -USR2 "${LOOP_PID_ARRAY[@]}"
    echo "resume/run-now signal sent to $LOOP_PIDS"
    ;;
  stop)
    require_running
    kill -TERM "${LOOP_PID_ARRAY[@]}"
    echo "stop signal sent to $LOOP_PIDS (clean shutdown after current cycle)"
    wait_for_barrier "stop" stop_barrier_reached
    echo "stop acknowledged for project=$PROJECT"
    ;;
  tail)
    tail -F "$ORCH_LOG_DIR/$PROJECT-orch-loop.log"
    ;;
  reset-cycles)
    echo 0 > "$(state_dir)/orch.cycle_count"
    audit "ORCH_CTL cycle counter reset"
    ;;
  reset-state)
    read -r -p "WARNING: this clears all state for $PROJECT. Type 'yes' to confirm: " yn
    if [[ "$yn" == "yes" ]]; then
      rm -f "$(state_dir)/assignments.json" "$(state_dir)/ci_watcher_seen.txt"
      audit "ORCH_CTL FULL STATE RESET"
      echo "state cleared"
    else
      echo "aborted"
    fi
    ;;
  *)
    echo "unknown command: $CMD"
    echo "usage: orch_ctl.sh <project> {status|pause|resume|run-now|stop|tail|reset-cycles|reset-state}"
    exit 1
    ;;
esac
