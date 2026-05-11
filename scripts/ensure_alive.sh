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
  ensure_alive.sh orch-supervisor <project-config> [--once] [--interval <seconds>] [--dry-run]
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

iso_now() {
  if [[ -n "${ORCH_NOW_OVERRIDE:-}" ]]; then
    date -u -d "@$ORCH_NOW_OVERRIDE" +%FT%TZ
  else
    date -u +%FT%TZ
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

orch_supervisor_target() {
  if [[ -n "${ORCH_SUPERVISOR_TARGET:-}" ]]; then
    printf '%s\n' "$ORCH_SUPERVISOR_TARGET"
    return
  fi

  local session window pane
  if [[ -n "${ORCH_SUPERVISOR_SESSION:-}" ]]; then
    session=$ORCH_SUPERVISOR_SESSION
  elif [[ -n "${AGENT_SESSION_PREFIX:-}" ]]; then
    session="${AGENT_SESSION_PREFIX}orchestrator"
  else
    session="${PROJECT}-orchestrator"
  fi
  window=${ORCH_SUPERVISOR_WINDOW:-0}
  pane=${ORCH_SUPERVISOR_PANE:-0}
  printf '%s:%s.%s\n' "$session" "$window" "$pane"
}

orch_supervisor_session() {
  local target=${1:?usage: orch_supervisor_session <target>}
  printf '%s\n' "${target%%:*}"
}

orch_supervisor_window() {
  local target=${1:?usage: orch_supervisor_window <target>}
  local window_pane=${target#*:}
  printf '%s\n' "${window_pane%%.*}"
}

orch_supervisor_cli_bin() {
  printf '%s\n' "${ORCH_SUPERVISOR_CLI_BIN:-${ORCH_CLI_BIN:-${SUPERVISOR_CLI_BIN:-codex}}}"
}

orch_supervisor_runtime_flags() {
  printf '%s\n' "${ORCH_SUPERVISOR_CLI_FLAGS:-${ORCH_RUNTIME_FLAGS:-${ORCH_CLI_FLAGS:-}}}"
}

orch_supervisor_workdir() {
  local candidate
  for candidate in \
    "${ORCH_SUPERVISOR_WORKDIR:-}" \
    "${SUPERVISOR_REPO:-}" \
    "${PROJECT_REPO_ROOT:-}" \
    "$TK"; do
    [[ -n "$candidate" ]] || continue
    if [[ -d "$candidate" ]]; then
      (cd "$candidate" && pwd)
      return 0
    fi
  done

  audit "ORCH_SUPERVISOR_REFUSED reason=missing-supervisor-workdir"
  return 1
}

sanitize_plan_id_part() {
  tr -cs 'A-Za-z0-9_.-' '-' | sed 's/^-//; s/-$//'
}

orch_supervisor_health_pattern() {
  printf '%s\n' "${ORCH_SUPERVISOR_HEALTH_PATTERN:-$(orch_supervisor_cli_bin)}"
}

read_orch_supervisor_pane() {
  local target=${1:?usage: read_orch_supervisor_pane <target>}
  local line
  line=$(tmux list-panes -t "$target" -F '#{pane_index}	#{pane_dead}	#{pane_dead_status}	#{pane_pid}' 2>/dev/null | head -n 1) || return 1
  [[ -n "$line" ]] || return 1
  IFS=$'\t' read -r _ ORCH_SUPERVISOR_PANE_DEAD ORCH_SUPERVISOR_PANE_STATUS ORCH_SUPERVISOR_PANE_PID <<< "$line"
}

orch_supervisor_pane_healthy() {
  local target=${1:?usage: orch_supervisor_pane_healthy <target>}
  local pattern capture

  pattern=$(orch_supervisor_health_pattern)
  [[ -n "$pattern" ]] || pattern=codex
  capture=$(tmux capture-pane -p -t "$target" -S -20 2>/dev/null || true)
  grep -E -- "$pattern" <<< "$capture" >/dev/null
}

render_orch_supervisor_recovery_plan() {
  local cfg_arg=${1:?usage: render_orch_supervisor_recovery_plan <config> <target> <reason> <workdir>}
  local target=${2:?usage: render_orch_supervisor_recovery_plan <config> <target> <reason> <workdir>}
  local reason=${3:?usage: render_orch_supervisor_recovery_plan <config> <target> <reason> <workdir>}
  local workdir=${4:?usage: render_orch_supervisor_recovery_plan <config> <target> <reason> <workdir>}
  local now target_id plan_id plan_file

  now=$(unix_now)
  target_id=$(printf '%s' "$target" | sanitize_plan_id_part)
  plan_id="orchestrator-recovery-${now}-${target_id}"
  plan_file="$(state_dir)/${plan_id}.md"
  mkdir -p "$(dirname "$plan_file")"

  cat > "$plan_file" <<EOF
# ORDO Orchestrator Recovery Plan

Plan id: $plan_id
Generated at: $(iso_now)
Target pane: $target
Relaunch reason: $reason

Current project: ${PROJECT:-unknown}
Repository: ${GH_REPO:-unknown}
Default branch: ${DEFAULT_BRANCH:-main}
Supervisor workdir: $workdir

Priority queue: ${ORCH_SUPERVISOR_PRIORITY_QUEUE:-run "bash scripts/dispatch_plan.sh $cfg_arg --ready-only --json"}
Active PRs: ${ORCH_SUPERVISOR_ACTIVE_PRS:-run "bash scripts/pr_block_signals.sh $cfg_arg --json"}
Assignments: ${ORCH_SUPERVISOR_ASSIGNMENTS:-run "bash scripts/agent_pool_status.sh $cfg_arg --tsv"}
Audit logs: ${ORCH_SUPERVISOR_AUDIT_LOGS:-${AUDIT_LOG_FILE:-${ORCH_LOG_DIR:-/var/log/orch}/${PROJECT:-project}.log}}
Opportunity findings policy: record operational blockers, slow or confusing workflows, auth/protocol failures, validation gaps, and safe remediation candidates in the final handoff.

Next action plan:
1. Re-read the operator profile and confirm project scope before mutation.
2. Inspect fleet, assignment, active PR, and audit state with read-only commands.
3. Resume or dispatch only non-colliding ready work.
4. Keep validation bounded to the rendered dispatch policy.
5. Log blockers and opportunity findings with evidence.
EOF

  printf '%s\t%s\n' "$plan_id" "$plan_file"
}

orch_supervisor_start_command() {
  local plan_file=${1:?usage: orch_supervisor_start_command <plan-file> <workdir>}
  local workdir=${2:?usage: orch_supervisor_start_command <plan-file> <workdir>}
  local command bin flags

  if [[ -n "${ORCH_SUPERVISOR_COMMAND:-}" ]]; then
    command=${ORCH_SUPERVISOR_COMMAND//\{\{PLAN_FILE\}\}/$plan_file}
    command=${command//\{\{WORKDIR\}\}/$workdir}
    printf '%s\n' "$command"
    return
  fi

  bin=$(orch_supervisor_cli_bin)
  flags=$(orch_supervisor_runtime_flags)
  if [[ "$bin" == "codex" ]]; then
    if [[ -n "$flags" ]]; then
      printf 'cd %s && exec %s exec --ephemeral -C %s %s "$(cat %s)"\n' \
        "$(shell_quote "$workdir")" \
        "$(shell_quote "$bin")" \
        "$(shell_quote "$workdir")" \
        "$flags" \
        "$(shell_quote "$plan_file")"
    else
      printf 'cd %s && exec %s exec --ephemeral -C %s "$(cat %s)"\n' \
        "$(shell_quote "$workdir")" \
        "$(shell_quote "$bin")" \
        "$(shell_quote "$workdir")" \
        "$(shell_quote "$plan_file")"
    fi
    return
  fi

  if [[ -n "$flags" ]]; then
    printf 'cd %s && exec %s %s "$(cat %s)"\n' \
      "$(shell_quote "$workdir")" \
      "$(shell_quote "$bin")" \
      "$flags" \
      "$(shell_quote "$plan_file")"
  else
    printf 'cd %s && exec %s "$(cat %s)"\n' \
      "$(shell_quote "$workdir")" \
      "$(shell_quote "$bin")" \
      "$(shell_quote "$plan_file")"
  fi
}

relaunch_orch_supervisor() {
  local cfg_arg=${1:?usage: relaunch_orch_supervisor <config> <reason> <action>}
  local reason=${2:?usage: relaunch_orch_supervisor <config> <reason> <action>}
  local action=${3:?usage: relaunch_orch_supervisor <config> <reason> <action>}
  local target session window workdir plan_record plan_id plan_file command

  target=$(orch_supervisor_target)
  session=$(orch_supervisor_session "$target")
  window=$(orch_supervisor_window "$target")
  workdir=$(orch_supervisor_workdir) || return 1
  plan_record=$(render_orch_supervisor_recovery_plan "$cfg_arg" "$target" "$reason" "$workdir")
  IFS=$'\t' read -r plan_id plan_file <<< "$plan_record"
  command=$(orch_supervisor_start_command "$plan_file" "$workdir")

  audit "ORCH_SUPERVISOR_RELAUNCH timestamp=$(iso_now) target=$target reason=$reason action=$action plan_id=$plan_id plan_file=$(shell_quote "$plan_file") workdir=$(shell_quote "$workdir") respawn_command=$(shell_quote "$command")"

  if [[ "${ORCH_SUPERVISOR_DRY_RUN:-0}" == "1" ]]; then
    printf 'dry-run: would relaunch %s reason=%s plan_id=%s\n' "$target" "$reason" "$plan_id"
    return 0
  fi

  case "$action" in
    new-session)
      tmux new-session -d -s "$session" -c "$workdir" "$command"
      ;;
    new-window)
      tmux new-window -d -t "$session:$window" -c "$workdir" "$command"
      ;;
    respawn)
      tmux respawn-pane -k -t "$target" -c "$workdir" "$command"
      ;;
    *)
      audit "ORCH_SUPERVISOR_REFUSED reason=unknown-action action=$action"
      return 2
      ;;
  esac
}

ensure_orch_supervisor_once() {
  local cfg_arg=${1:?usage: ensure_orch_supervisor_once <config-arg>}
  local target session

  target=$(orch_supervisor_target)
  session=$(orch_supervisor_session "$target")

  if ! tmux has-session -t "$session" 2>/dev/null; then
    relaunch_orch_supervisor "$cfg_arg" "missing-session" "new-session"
    return $?
  fi

  if ! read_orch_supervisor_pane "$target"; then
    relaunch_orch_supervisor "$cfg_arg" "missing-pane" "new-window"
    return $?
  fi

  if [[ "${ORCH_SUPERVISOR_PANE_DEAD:-0}" == "1" ]]; then
    relaunch_orch_supervisor "$cfg_arg" "stopped-pane" "respawn"
    return $?
  fi

  if ! orch_supervisor_pane_healthy "$target"; then
    relaunch_orch_supervisor "$cfg_arg" "non-supervisor-pane" "respawn"
    return $?
  fi

  return 0
}

run_orch_supervisor_watchdog() {
  local cfg_arg=${1:-}
  [[ -n "$cfg_arg" ]] || {
    usage
    return 2
  }
  shift || true

  local once=0 interval=${ORCH_SUPERVISOR_WATCHDOG_INTERVAL_SEC:-60}
  ORCH_SUPERVISOR_DRY_RUN=${ORCH_SUPERVISOR_DRY_RUN:-0}
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
      --dry-run)
        ORCH_SUPERVISOR_DRY_RUN=1
        shift
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

  if [[ "${ORCH_SUPERVISOR_WATCHDOG_VERBOSE:-0}" == "1" ]]; then
    audit "ORCH_SUPERVISOR_WATCHDOG_START target=$(orch_supervisor_target) interval=${interval}s once=$once dry_run=$ORCH_SUPERVISOR_DRY_RUN"
  fi
  local rc
  while true; do
    if ensure_orch_supervisor_once "$cfg_arg"; then
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

if [[ "${1:-}" == "orch-supervisor" ]]; then
  shift
  run_orch_supervisor_watchdog "$@"
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
