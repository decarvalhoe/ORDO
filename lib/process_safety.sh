#!/usr/bin/env bash
# process_safety.sh - bounded external calls, single-flight locks, and health probes.
#
# This file is sourced by scripts that may touch tmux, gh, git, ps, or portfolio
# scans. Keep helpers dependency-light so they remain usable from sanitized tests.

: "${ORCH_STATE_BASE:=${XDG_DATA_HOME:-/root/.local/share}/orch-state}"
: "${ORCH_TIMEOUT_EXIT_CODE:=124}"
: "${ORCH_PS_TIMEOUT_SEC:=2}"
: "${ORCH_PROCESS_BUDGET_WARN_PROCS:=}"
: "${ORCH_PROCESS_BUDGET_MAX_PROCS:=}"
: "${ORCH_TMUX_LIST_PANES_TIMEOUT_SEC:=3}"

orch_run_timeout() {
  local seconds=${1:?usage: orch_run_timeout <seconds> <command> [args...]}
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$seconds" "$@"
  else
    "$@"
  fi
}

orch_process_count() {
  local cgroup_count_file
  for cgroup_count_file in \
    /sys/fs/cgroup/pids.current \
    /sys/fs/cgroup/pids/pids.current
  do
    if [[ -r "$cgroup_count_file" ]]; then
      cat "$cgroup_count_file"
      return 0
    fi
  done

  local count
  count=$(orch_run_timeout "$ORCH_PS_TIMEOUT_SEC" ps -eo pid= 2>/dev/null | wc -l | tr -d ' ') || return 1
  printf '%s\n' "${count:-0}"
}

orch_process_limit() {
  local cgroup_limit_file limit
  for cgroup_limit_file in \
    /sys/fs/cgroup/pids.max \
    /sys/fs/cgroup/pids/pids.max
  do
    if [[ -r "$cgroup_limit_file" ]]; then
      limit=$(cat "$cgroup_limit_file")
      [[ "$limit" =~ ^[0-9]+$ ]] && printf '%s\n' "$limit" && return 0
    fi
  done
  return 1
}

orch_process_budget_signal() {
  local count limit warn_limit max_limit
  count=$(orch_process_count) || {
    printf '%s\n' "fork_risk"
    return 1
  }
  limit=$(orch_process_limit || true)
  if [[ -n "$ORCH_PROCESS_BUDGET_WARN_PROCS" ]]; then
    warn_limit=$ORCH_PROCESS_BUDGET_WARN_PROCS
  elif [[ -n "$limit" ]]; then
    warn_limit=$((limit * 85 / 100))
  else
    warn_limit=30000
  fi
  if [[ -n "$ORCH_PROCESS_BUDGET_MAX_PROCS" ]]; then
    max_limit=$ORCH_PROCESS_BUDGET_MAX_PROCS
  elif [[ -n "$limit" ]]; then
    max_limit=$((limit * 95 / 100))
  else
    max_limit=32768
  fi

  if [[ "$count" -ge "$max_limit" ]]; then
    printf '%s\n' "process_budget_degraded,fork_risk"
    return 1
  fi
  if [[ "$count" -ge "$warn_limit" ]]; then
    printf '%s\n' "process_budget_degraded"
    return 0
  fi
  printf '\n'
}

orch_signal_list_add_csv() {
  local csv=${1:-}
  local -n target_ref=$2
  local old_ifs=$IFS
  local signal
  IFS=,
  for signal in $csv; do
    [[ -n "$signal" ]] && target_ref+=("$signal")
  done
  IFS=$old_ifs
}

orch_signal_list_unique_csv() {
  local -a seen=()
  local signal existing duplicate
  for signal in "$@"; do
    [[ -n "$signal" ]] || continue
    duplicate=0
    for existing in "${seen[@]}"; do
      if [[ "$existing" == "$signal" ]]; then
        duplicate=1
        break
      fi
    done
    [[ "$duplicate" -eq 0 ]] && seen+=("$signal")
  done
  local old_ifs=$IFS
  IFS=,
  printf '%s' "${seen[*]}"
  IFS=$old_ifs
}

orch_lock_root() {
  printf '%s/_locks\n' "$ORCH_STATE_BASE"
}

orch_lock_path() {
  local name=${1:?usage: orch_lock_path <name>}
  local safe=${name//[^A-Za-z0-9_.-]/_}
  printf '%s/%s.lock\n' "$(orch_lock_root)" "$safe"
}

orch_single_flight_enter() {
  local name=${1:?usage: orch_single_flight_enter <name> [ttl-sec]}
  local ttl=${2:-300}
  local lock_dir pid_file started_file now started age owner_pid
  lock_dir=$(orch_lock_path "$name")
  pid_file="$lock_dir/pid"
  started_file="$lock_dir/started"

  mkdir -p "$(dirname "$lock_dir")"
  if mkdir "$lock_dir" 2>/dev/null; then
    printf '%s\n' "$$" > "$pid_file"
    date +%s > "$started_file"
    # shellcheck disable=SC2034  # consumed by callers after sourcing
    ORCH_SINGLE_FLIGHT_LOCK_DIR="$lock_dir"
    return 0
  fi

  now=$(date +%s)
  owner_pid=$(cat "$pid_file" 2>/dev/null || true)
  started=$(cat "$started_file" 2>/dev/null || printf '0')
  age=$((now - started))
  if [[ -n "$owner_pid" && "$owner_pid" =~ ^[0-9]+$ ]] \
    && kill -0 "$owner_pid" 2>/dev/null \
    && [[ "$age" -lt "$ttl" ]]; then
    # shellcheck disable=SC2034  # consumed by callers after sourcing
    ORCH_SINGLE_FLIGHT_OWNER_PID="$owner_pid"
    # shellcheck disable=SC2034  # consumed by callers after sourcing
    ORCH_SINGLE_FLIGHT_OWNER_AGE="$age"
    return 75
  fi

  rm -rf "$lock_dir"
  if mkdir "$lock_dir" 2>/dev/null; then
    printf '%s\n' "$$" > "$pid_file"
    date +%s > "$started_file"
    # shellcheck disable=SC2034  # consumed by callers after sourcing
    ORCH_SINGLE_FLIGHT_LOCK_DIR="$lock_dir"
    return 0
  fi

  # shellcheck disable=SC2034  # consumed by callers after sourcing
  ORCH_SINGLE_FLIGHT_OWNER_PID="${owner_pid:-unknown}"
  # shellcheck disable=SC2034  # consumed by callers after sourcing
  ORCH_SINGLE_FLIGHT_OWNER_AGE="$age"
  return 75
}

orch_single_flight_release() {
  local lock_dir=${1:-${ORCH_SINGLE_FLIGHT_LOCK_DIR:-}}
  [[ -n "$lock_dir" && -d "$lock_dir" ]] || return 0
  if [[ "$(cat "$lock_dir/pid" 2>/dev/null || true)" == "$$" ]]; then
    rm -rf "$lock_dir"
  fi
}

orch_tmux_probe() {
  local restore_errexit=0 status
  if ! command -v tmux >/dev/null 2>&1; then
    return 0
  fi

  case $- in
    *e*) restore_errexit=1 ;;
  esac
  set +e
  orch_run_timeout "$ORCH_TMUX_LIST_PANES_TIMEOUT_SEC" \
    tmux list-panes -a -F '#{session_name}:#{window_index}.#{pane_index}' >/dev/null 2>&1
  status=$?
  if [[ "$restore_errexit" -eq 1 ]]; then
    set -e
  else
    set +e
  fi
  if [[ "$status" -eq "$ORCH_TIMEOUT_EXIT_CODE" || "$status" -eq 137 ]]; then
    # shellcheck disable=SC2034  # consumed by callers after sourcing
    ORCH_TMUX_DEGRADED_REASON="tmux list-panes exceeded ${ORCH_TMUX_LIST_PANES_TIMEOUT_SEC}s"
    return 1
  fi

  # A missing tmux server or absent session is handled by the caller's specific
  # tmux command. Only timeout-like failures trip the circuit breaker.
  return 0
}
