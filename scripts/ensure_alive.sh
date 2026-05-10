#!/usr/bin/env bash
# ensure_alive.sh — generic tmux watchdog (3-tier inspired by Overstory).
#
# Usage:
#   bash ensure_alive.sh <session> <window> "<start_cmd>" [match_pattern]
#   bash ensure_alive.sh orch-loop <project-config> [--once] [--interval <seconds>]
#
# Tier 0 (mechanical) — checks every 15s if the matching process is running.
# If not, runs respawn-pane with the start_cmd.
#
# Example: keep ci_watcher_daemon.sh alive in demo-ciwatch:0
#   bash ensure_alive.sh demo-ciwatch 0 "bash $TK/scripts/ci_watcher_daemon.sh demo"

set -euo pipefail

TK="${TK:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# shellcheck source=lib/log_bounds.sh
source "$TK/lib/log_bounds.sh"

usage() {
  cat <<'USAGE' >&2
usage:
  ensure_alive.sh <session> <window> <cmd> [match_pattern]
  ensure_alive.sh orch-loop <project-config> [--once] [--interval <seconds>]
USAGE
}

shell_quote() {
  printf '%q' "$1"
}

unix_now() {
  if [[ -n "${ORCH_NOW_OVERRIDE:-}" ]]; then
    printf '%s\n' "$ORCH_NOW_OVERRIDE"
  else
    date -u +%s
  fi
}

orch_loop_watchdog_target() {
  if [[ -n "${ORCH_LOOP_SERVICE_TARGET:-}" ]]; then
    printf '%s\n' "$ORCH_LOOP_SERVICE_TARGET"
    return
  fi

  local session window pane
  if [[ -n "${ORCH_LOOP_SERVICE_SESSION:-}" ]]; then
    session=$ORCH_LOOP_SERVICE_SESSION
  elif [[ -n "${AGENT_SESSION_PREFIX:-}" ]]; then
    session="${AGENT_SESSION_PREFIX}loop-svc"
  else
    session="${PROJECT}-loop-svc"
  fi
  window=${ORCH_LOOP_SERVICE_WINDOW:-0}
  pane=${ORCH_LOOP_SERVICE_PANE:-0}
  printf '%s:%s.%s\n' "$session" "$window" "$pane"
}

orch_loop_watchdog_session() {
  local target=${1:?usage: orch_loop_watchdog_session <target>}
  printf '%s\n' "${target%%:*}"
}

orch_loop_start_command() {
  local cfg_arg=${1:?usage: orch_loop_start_command <config-arg>}
  if [[ -n "${ORCH_LOOP_SERVICE_COMMAND:-}" ]]; then
    printf '%s\n' "$ORCH_LOOP_SERVICE_COMMAND"
    return
  fi

  local confirm
  confirm=${ORCH_LOOP_DAEMON_CONFIRM:-${ORCH_DAEMON_CONFIRM:-${ORCH_CLI_BIN:-${SUPERVISOR_CLI_BIN:-}}}}
  if [[ -z "$confirm" ]]; then
    audit "ORCH_LOOP_WATCHDOG_REFUSED reason=missing-daemon-confirm"
    return 1
  fi

  printf 'bash %s %s --daemon-confirm %s\n' \
    "$(shell_quote "scripts/orch_loop.sh")" \
    "$(shell_quote "$cfg_arg")" \
    "$(shell_quote "$confirm")"
}

require_orch_supervisor_workdir() {
  if [[ -z "${ORCH_SUPERVISOR_WORKDIR:-}" ]]; then
    audit "ORCH_LOOP_WATCHDOG_REFUSED reason=missing-supervisor-workdir"
    return 1
  fi
  if [[ ! -d "$ORCH_SUPERVISOR_WORKDIR" ]]; then
    audit "ORCH_LOOP_WATCHDOG_REFUSED reason=invalid-supervisor-workdir workdir=$(shell_quote "$ORCH_SUPERVISOR_WORKDIR")"
    return 1
  fi
  (cd "$ORCH_SUPERVISOR_WORKDIR" && pwd)
}

orch_loop_watchdog_state_file() {
  printf '%s/orch_loop_watchdog_respawns.tsv\n' "$(state_dir)"
}

record_orch_loop_death_or_alert() {
  local target=${1:?usage: record_orch_loop_death_or_alert <target> <pid> <status>}
  local previous_pid=${2:-unknown}
  local previous_status=${3:-unknown}
  local now window max file tmp cutoff count

  now=$(unix_now)
  window=${ORCH_LOOP_WATCHDOG_WINDOW_SEC:-300}
  max=${ORCH_LOOP_WATCHDOG_MAX_RESPAWNS:-3}
  file=$(orch_loop_watchdog_state_file)
  tmp=$(mktemp)
  cutoff=$((now - window))

  if [[ -f "$file" ]]; then
    awk -v cutoff="$cutoff" '$1 ~ /^[0-9]+$/ && $1 >= cutoff { print $1 }' "$file" > "$tmp"
  fi
  printf '%s\n' "$now" >> "$tmp"
  count=$(wc -l < "$tmp" | tr -d ' ')
  mv "$tmp" "$file"

  if (( count > max )); then
    audit "ORCH_LOOP_WATCHDOG_OPEN_LOOP target=$target previous_pid=$previous_pid previous_status=$previous_status previous_exit_or_signal=$previous_status death_count=$count window_sec=$window max_respawns=$max action=refuse-respawn"
    return 1
  fi

  return 0
}

read_orch_loop_pane() {
  local target=${1:?usage: read_orch_loop_pane <target>}
  local line
  line=$(tmux list-panes -t "$target" -F '#{pane_index}	#{pane_dead}	#{pane_dead_status}	#{pane_pid}' 2>/dev/null | head -n 1) || return 1
  [[ -n "$line" ]] || return 1
  IFS=$'\t' read -r _ ORCH_LOOP_PANE_DEAD ORCH_LOOP_PANE_STATUS ORCH_LOOP_PANE_PID <<< "$line"
}

ensure_orch_loop_service_once() {
  local cfg_arg=${1:?usage: ensure_orch_loop_service_once <config-arg>}
  local workdir command target session window

  workdir=$(require_orch_supervisor_workdir) || return 1
  command=$(orch_loop_start_command "$cfg_arg") || return 1
  target=$(orch_loop_watchdog_target)
  session=$(orch_loop_watchdog_session "$target")
  window=${ORCH_LOOP_SERVICE_WINDOW:-0}

  if ! tmux has-session -t "$session" 2>/dev/null; then
    tmux new-session -d -s "$session" -c "$workdir" "$command"
    audit "ORCH_LOOP_WATCHDOG_CREATED target=$target reason=missing-session workdir=$(shell_quote "$workdir") respawn_command=$(shell_quote "$command")"
    return 0
  fi

  if ! read_orch_loop_pane "$target"; then
    tmux new-window -d -t "$session:$window" -c "$workdir" "$command"
    audit "ORCH_LOOP_WATCHDOG_CREATED target=$target reason=missing-pane workdir=$(shell_quote "$workdir") respawn_command=$(shell_quote "$command")"
    return 0
  fi

  if [[ "${ORCH_LOOP_PANE_DEAD:-0}" == "1" ]]; then
    if ! record_orch_loop_death_or_alert "$target" "${ORCH_LOOP_PANE_PID:-unknown}" "${ORCH_LOOP_PANE_STATUS:-unknown}"; then
      return 2
    fi
    tmux respawn-pane -k -t "$target" -c "$workdir" "$command"
    audit "ORCH_LOOP_WATCHDOG_RESPAWN target=$target previous_pid=${ORCH_LOOP_PANE_PID:-unknown} previous_status=${ORCH_LOOP_PANE_STATUS:-unknown} previous_exit_or_signal=${ORCH_LOOP_PANE_STATUS:-unknown} workdir=$(shell_quote "$workdir") respawn_command=$(shell_quote "$command")"
    return 0
  fi

  return 0
}

run_orch_loop_watchdog() {
  local cfg_arg=${1:-}
  [[ -n "$cfg_arg" ]] || {
    usage
    return 2
  }
  shift || true

  local once=0 interval=${ORCH_LOOP_WATCHDOG_INTERVAL_SEC:-60}
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --once)
        once=1
        shift
        ;;
      --interval)
        interval=${2:?missing value for --interval}
        shift 2
        ;;
      *)
        usage
        return 2
        ;;
    esac
  done

  # shellcheck source=lib/config_resolver.sh
  source "$TK/lib/config_resolver.sh"
  load_project_config "$cfg_arg"
  # shellcheck source=lib/audit_log.sh
  source "$TK/lib/audit_log.sh"

  if [[ "${ORCH_LOOP_WATCHDOG_VERBOSE:-0}" == "1" ]]; then
    audit "ORCH_LOOP_WATCHDOG_START target=$(orch_loop_watchdog_target) interval=${interval}s once=$once"
  fi
  local rc
  while true; do
    if ensure_orch_loop_service_once "$cfg_arg"; then
      rc=0
    else
      rc=$?
    fi
    if [[ "$once" -eq 1 ]]; then
      return "$rc"
    fi
    sleep "$interval"
  done
}

if [[ "${1:-}" == "orch-loop" ]]; then
  shift
  run_orch_loop_watchdog "$@"
  exit $?
fi

SESSION=${1:?usage: ensure_alive.sh <session> <window> <cmd> [match_pattern]}
WINDOW=${2:?usage: ensure_alive.sh <session> <window> <cmd> [match_pattern]}
START_CMD=${3:?usage: ensure_alive.sh <session> <window> <cmd> [match_pattern]}
MATCH_PATTERN=${4:-$START_CMD}

TARGET="$SESSION:$WINDOW"
LOG="/var/log/orch/watchdog-$SESSION.log"
mkdir -p "$(dirname "$LOG")" 2>/dev/null

log() {
  orch_log_rotate_if_needed "$LOG"
  printf '[%s] %s\n' "$(date -u +%FT%TZ)" "$*" | tee -a "$LOG"
  orch_log_rotate_if_needed "$LOG"
}

ensure_session_exists() {
  if ! tmux has-session -t "$SESSION" 2>/dev/null; then
    tmux new-session -d -s "$SESSION" "$START_CMD"
    log "created tmux session $SESSION and started: $START_CMD"
    return
  fi
  if ! tmux list-windows -t "$SESSION" -F '#I' 2>/dev/null | grep -qx "$WINDOW"; then
    tmux new-window -d -t "$TARGET" "$START_CMD"
    log "created tmux window $TARGET"
  fi
}

is_running() {
  pgrep -af "$MATCH_PATTERN" >/dev/null 2>&1
}

start_it() {
  ensure_session_exists
  tmux respawn-pane -k -t "$TARGET" "$START_CMD"
  sleep 2
  log "respawned: $START_CMD in $TARGET"
}

log "watchdog started for $TARGET (match=$MATCH_PATTERN)"

while true; do
  ensure_session_exists
  if ! is_running; then
    start_it
  fi
  sleep 15
done
