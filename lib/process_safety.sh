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
: "${ORCH_VALIDATOR_FORK_LATENCY_MAX_MS:=750}"
: "${ORCH_VALIDATOR_FORK_DEGRADED_EXIT_CODE:=75}"
: "${ORCH_VALIDATOR_SEMAPHORE:=1}"
: "${ORCH_VALIDATOR_SEMAPHORE_WAIT_SEC:=900}"
: "${ORCH_VALIDATOR_SEMAPHORE_FILE:=/tmp/ordo-validators.lock}"
# Hard cap on the per-call TTL of orch_single_flight locks. Callers cannot
# request a window wider than this (default 1h). Stale locks beyond the cap
# are reclaimed instead of blocking forever — see #146.
: "${ORCH_SINGLE_FLIGHT_TTL_MAX_SEC:=3600}"

orch_run_timeout() {
  local seconds=${1:?usage: orch_run_timeout <seconds> <command> [args...]}
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$seconds" "$@"
  else
    "$@"
  fi
}

orch_now_ns() {
  local ns seconds
  ns=$(date +%s%N 2>/dev/null || true)
  if [[ "$ns" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$ns"
    return 0
  fi
  seconds=$(date +%s)
  printf '%s000000000\n' "$seconds"
}

orch_fork_latency_ms() {
  local start_ns end_ns
  start_ns=$(orch_now_ns)
  bash -c true >/dev/null 2>&1 || return 1
  end_ns=$(orch_now_ns)
  printf '%s\n' $(((end_ns - start_ns) / 1000000))
}

orch_validator_fork_preflight() {
  local validator=${1:-validator}
  local max_ms=${ORCH_VALIDATOR_FORK_LATENCY_MAX_MS:-750}
  local latency_ms
  [[ "$max_ms" =~ ^[0-9]+$ ]] || max_ms=750
  latency_ms=$(orch_fork_latency_ms) || latency_ms=$((max_ms + 1))
  if [[ "$latency_ms" -ge "$max_ms" ]]; then
    printf 'validators_degraded: validator=%s fork_latency_ms=%s threshold_ms=%s action=ci-delegated exit=%s\n' \
      "$validator" "$latency_ms" "$max_ms" "$ORCH_VALIDATOR_FORK_DEGRADED_EXIT_CODE" >&2
    return "$ORCH_VALIDATOR_FORK_DEGRADED_EXIT_CODE"
  fi
  return 0
}

orch_validator_run_with_semaphore() {
  local validator=${1:?usage: orch_validator_run_with_semaphore <validator> <command> [args...]}
  shift
  local wait_sec=${ORCH_VALIDATOR_SEMAPHORE_WAIT_SEC:-900}
  local lock_file=${ORCH_VALIDATOR_SEMAPHORE_FILE:-/tmp/ordo-validators.lock}
  local lock_dir status

  if [[ "${ORCH_VALIDATOR_SEMAPHORE:-1}" == "0" || "${ORCH_VALIDATOR_SEMAPHORE:-1}" == "off" ]]; then
    "$@"
    return $?
  fi

  [[ "$wait_sec" =~ ^[0-9]+$ ]] || wait_sec=900
  lock_dir=$(dirname "$lock_file")
  if ! mkdir -p "$lock_dir" 2>/dev/null; then
    printf 'validators_degraded: validator=%s reason=semaphore_unavailable lock=%s action=ci-delegated exit=%s\n' \
      "$validator" "$lock_file" "$ORCH_VALIDATOR_FORK_DEGRADED_EXIT_CODE" >&2
    return "$ORCH_VALIDATOR_FORK_DEGRADED_EXIT_CODE"
  fi

  if ! command -v flock >/dev/null 2>&1; then
    printf 'validators_degraded: validator=%s reason=flock_unavailable action=ci-delegated exit=%s\n' \
      "$validator" "$ORCH_VALIDATOR_FORK_DEGRADED_EXIT_CODE" >&2
    return "$ORCH_VALIDATOR_FORK_DEGRADED_EXIT_CODE"
  fi

  (
    if ! flock -w "$wait_sec" 9; then
      printf 'validators_degraded: validator=%s reason=semaphore_timeout wait_sec=%s lock=%s action=ci-delegated exit=%s\n' \
        "$validator" "$wait_sec" "$lock_file" "$ORCH_VALIDATOR_FORK_DEGRADED_EXIT_CODE" >&2
      exit "$ORCH_VALIDATOR_FORK_DEGRADED_EXIT_CODE"
    fi
    printf 'validator_semaphore: validator=%s lock=%s action=acquired\n' "$validator" "$lock_file" >&2
    "$@"
  ) 9>"$lock_file"
  status=$?
  return "$status"
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

# Resolve a writable lock root and write it into the variable named by $1.
# Prefers $ORCH_STATE_BASE/_locks; if that path cannot be created (e.g. CI
# runner with read-only $HOME, see #146) the lock root is redirected once to
# a per-process mktemp dir and ORCH_STATE_BASE is updated in-place so
# subsequent calls in the same shell reuse the same fallback.
#
# Uses a nameref instead of stdout because the fallback must mutate
# ORCH_STATE_BASE in the *caller's* shell — capturing via "$(_orch_lock_root_resolve)"
# would lose that mutation in a subshell.
_orch_lock_root_resolve_to() {
  local _orch_out_var=${1:?usage: _orch_lock_root_resolve_to <var-name>}
  # Avoid `local -n` here: a nameref pointing at a caller variable that
  # shares its name with any local declared in this function would silently
  # be shadowed (bash binds the nameref to the local, not the caller's
  # variable). Use eval-based assignment instead so the caller-named
  # variable is the sole writable target.
  local _orch_root_path="$ORCH_STATE_BASE/_locks"
  if mkdir -p "$_orch_root_path" 2>/dev/null && [[ -w "$_orch_root_path" ]]; then
    printf -v "$_orch_out_var" '%s' "$_orch_root_path"
    return 0
  fi

  if [[ -z "${ORCH_STATE_BASE_FALLBACK:-}" ]]; then
    local _orch_fallback
    _orch_fallback=$(mktemp -d -t orch-state.XXXXXX 2>/dev/null) || return 1
    # shellcheck disable=SC2034  # exported for diagnostics
    ORCH_STATE_BASE_FALLBACK="$_orch_fallback"
    ORCH_STATE_BASE="$_orch_fallback"
    if [[ -w /dev/stderr ]]; then
      printf 'orch_single_flight: state base unwritable, fell back to %s\n' \
        "$_orch_fallback" >&2
    fi
  else
    ORCH_STATE_BASE="$ORCH_STATE_BASE_FALLBACK"
  fi

  _orch_root_path="$ORCH_STATE_BASE/_locks"
  mkdir -p "$_orch_root_path" 2>/dev/null || return 1
  printf -v "$_orch_out_var" '%s' "$_orch_root_path"
  return 0
}

orch_lock_root() {
  local root
  if _orch_lock_root_resolve_to root; then
    printf '%s\n' "$root"
    return 0
  fi
  # No writable root anywhere — surface the configured path so callers can
  # log it; subsequent mkdir attempts will fail loudly.
  printf '%s/_locks\n' "$ORCH_STATE_BASE"
  return 1
}

orch_lock_path() {
  local name=${1:?usage: orch_lock_path <name>}
  local safe=${name//[^A-Za-z0-9_.-]/_}
  printf '%s/%s.lock\n' "$(orch_lock_root)" "$safe"
}

# Acquire a directory-based single-flight lock for $name. Returns:
#   0  — lock acquired (caller must call orch_single_flight_release on exit)
#   75 — another live owner holds the lock within TTL (EX_TEMPFAIL)
#
# The lock is reclaimed when:
#   * the recorded owner PID is no longer alive (stale process),
#   * the lock age exceeds the (capped) TTL,
#   * the lock metadata is corrupt (missing/empty pid or started file).
#
# TTL is bounded by ORCH_SINGLE_FLIGHT_TTL_MAX_SEC (default 1h). Callers may
# request a smaller TTL but never a larger one — this prevents 20-day stale
# locks from blocking CI scans (#146).
orch_single_flight_enter() {
  local name=${1:?usage: orch_single_flight_enter <name> [ttl-sec]}
  local ttl=${2:-300}
  if ! [[ "$ttl" =~ ^[0-9]+$ ]]; then
    ttl=300
  fi
  if [[ "$ttl" -gt "$ORCH_SINGLE_FLIGHT_TTL_MAX_SEC" ]]; then
    ttl=$ORCH_SINGLE_FLIGHT_TTL_MAX_SEC
  fi
  local lock_root safe lock_dir pid_file started_file now started age owner_pid alive
  if ! _orch_lock_root_resolve_to lock_root; then
    # No writable state base, even after fallback — degrade closed.
    # shellcheck disable=SC2034  # consumed by callers after sourcing
    ORCH_SINGLE_FLIGHT_OWNER_PID="unknown"
    # shellcheck disable=SC2034  # consumed by callers after sourcing
    ORCH_SINGLE_FLIGHT_OWNER_AGE=0
    return 75
  fi
  safe=${name//[^A-Za-z0-9_.-]/_}
  lock_dir="$lock_root/$safe.lock"
  pid_file="$lock_dir/pid"
  started_file="$lock_dir/started"

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
  if ! [[ "$started" =~ ^[0-9]+$ ]]; then
    started=0
  fi
  age=$((now - started))
  alive=0
  if [[ -n "$owner_pid" && "$owner_pid" =~ ^[0-9]+$ ]] \
    && kill -0 "$owner_pid" 2>/dev/null; then
    alive=1
  fi

  if [[ "$alive" -eq 1 && "$age" -lt "$ttl" ]]; then
    # shellcheck disable=SC2034  # consumed by callers after sourcing
    ORCH_SINGLE_FLIGHT_OWNER_PID="$owner_pid"
    # shellcheck disable=SC2034  # consumed by callers after sourcing
    ORCH_SINGLE_FLIGHT_OWNER_AGE="$age"
    return 75
  fi

  # Stale: dead owner, missing/corrupt metadata, or age >= ttl. Reclaim.
  rm -rf "$lock_dir" 2>/dev/null || true
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
