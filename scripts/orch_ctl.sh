#!/usr/bin/env bash
# orch_ctl.sh — control the running orch_loop.sh.
#
# Usage:
#   bash orch_ctl.sh <project> <command>
#
# Commands:
#   status           Show cycle count, last activity, paused state
#   pause            Pause the loop after the current cycle (SIGUSR1)
#   resume           Resume paused loop (SIGUSR2)
#   run-now          Force the next cycle to run immediately (SIGUSR2)
#   stop             Clean shutdown after current cycle (SIGTERM)
#   tail             tail -f the loop log
#   reset-cycles     Reset cycle counter to 0
#   reset-state      WARNING: clear all assignments + ci_watcher_seen

set -euo pipefail
TK="${TK:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
PROJECT_ARG=${1:?usage: orch_ctl.sh <project> <command>}
CMD=${2:?usage: orch_ctl.sh <project> <command>}

source "$TK/lib/config_resolver.sh"
load_project_config "$PROJECT_ARG"
# shellcheck disable=SC1091
source "$TK/lib/audit_log.sh"

mapfile -t LOOP_PID_ARRAY < <(pgrep -af "orch_loop.sh $PROJECT" 2>/dev/null | awk '{print $1}')
LOOP_PIDS="${LOOP_PID_ARRAY[*]:-}"

require_running() {
  if [[ ${#LOOP_PID_ARRAY[@]} -eq 0 ]]; then
    echo "no orch_loop.sh process running for project=$PROJECT" >&2
    exit 1
  fi
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
    echo "last_activity:  $([[ "$last_act" -gt 0 ]] && date -u -d "@$last_act" '+%FT%TZ (%s ago)' || echo never)"
    echo "log:            $ORCH_LOG_DIR/$PROJECT-orch-loop.log"
    echo "audit log:      $ORCH_LOG_DIR/$PROJECT.log"
    echo "state dir:      $state"
    ;;
  pause)
    require_running
    kill -USR1 "${LOOP_PID_ARRAY[@]}"
    echo "pause signal sent to $LOOP_PIDS"
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
