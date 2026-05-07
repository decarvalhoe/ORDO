#!/usr/bin/env bash
# host_health.sh - bounded host/session health probes for operator preflights.

_ORCH_HOST_HEALTH_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$_ORCH_HOST_HEALTH_LIB_DIR/process_safety.sh" ]]; then
  # shellcheck source=lib/process_safety.sh
  source "$_ORCH_HOST_HEALTH_LIB_DIR/process_safety.sh"
fi

: "${HOST_HEALTH_TIMEOUT_SEC:=2}"
: "${HOST_HEALTH_LOG_DIR:=/var/log}"
: "${HOST_HEALTH_WTMP_WARN_MB:=512}"
: "${HOST_HEALTH_WTMP_MAX_MB:=2048}"
: "${HOST_HEALTH_JOURNAL_WARN_MB:=2048}"
: "${HOST_HEALTH_JOURNAL_MAX_MB:=4096}"
: "${HOST_HEALTH_VAR_LOG_WARN_MB:=8192}"
: "${HOST_HEALTH_VAR_LOG_MAX_MB:=16384}"
: "${HOST_HEALTH_VAR_LOG_WARN_PCT:=80}"
: "${HOST_HEALTH_VAR_LOG_MAX_PCT:=90}"
: "${HOST_HEALTH_SESSION_WARN:=50}"
: "${HOST_HEALTH_SESSION_MAX:=100}"

host_health_run_timeout() {
  local seconds=${1:?usage: host_health_run_timeout <seconds> <command> [args...]}
  shift
  if declare -F orch_run_timeout >/dev/null 2>&1; then
    orch_run_timeout "$seconds" "$@"
  elif command -v timeout >/dev/null 2>&1; then
    timeout "$seconds" "$@"
  else
    "$@"
  fi
}

host_health_du_mb() {
  local path=${1:?usage: host_health_du_mb <path>}
  local out
  [[ -e "$path" ]] || {
    printf '0\n'
    return 0
  }
  out=$(host_health_run_timeout "$HOST_HEALTH_TIMEOUT_SEC" du -sm -- "$path" 2>/dev/null | awk 'NR == 1 {print $1}') || {
    printf 'unknown\n'
    return 1
  }
  [[ "$out" =~ ^[0-9]+$ ]] || out=0
  printf '%s\n' "$out"
}

host_health_wtmp_mb() {
  local log_dir=${HOST_HEALTH_LOG_DIR:-/var/log}
  local total=0 size file
  shopt -s nullglob
  local files=("$log_dir/wtmp" "$log_dir"/wtmp.[0-9]*)
  shopt -u nullglob
  for file in "${files[@]}"; do
    size=$(host_health_du_mb "$file" 2>/dev/null || printf '0')
    [[ "$size" =~ ^[0-9]+$ ]] || size=0
    total=$((total + size))
  done
  printf '%s\n' "$total"
}

host_health_journal_mb() {
  local journal_dir=${HOST_HEALTH_JOURNAL_DIR:-${HOST_HEALTH_LOG_DIR:-/var/log}/journal}
  host_health_du_mb "$journal_dir"
}

host_health_var_log_mb() {
  host_health_du_mb "${HOST_HEALTH_LOG_DIR:-/var/log}"
}

host_health_var_log_pct() {
  local log_dir=${HOST_HEALTH_LOG_DIR:-/var/log}
  local out
  if [[ -n "${HOST_HEALTH_VAR_LOG_PCT:-}" ]]; then
    printf '%s\n' "$HOST_HEALTH_VAR_LOG_PCT"
    return 0
  fi
  out=$(host_health_run_timeout "$HOST_HEALTH_TIMEOUT_SEC" df -P -- "$log_dir" 2>/dev/null | awk 'NR == 2 {gsub("%", "", $5); print $5}') || {
    printf 'unknown\n'
    return 1
  }
  [[ "$out" =~ ^[0-9]+$ ]] || out=0
  printf '%s\n' "$out"
}

host_health_session_count() {
  local out
  if [[ -n "${HOST_HEALTH_SESSION_COUNT_FILE:-}" && -r "$HOST_HEALTH_SESSION_COUNT_FILE" ]]; then
    awk 'NF {count++} END {print count + 0}' "$HOST_HEALTH_SESSION_COUNT_FILE"
    return 0
  fi

  if command -v loginctl >/dev/null 2>&1; then
    out=$(host_health_run_timeout "$HOST_HEALTH_TIMEOUT_SEC" loginctl list-sessions --no-legend --no-pager 2>/dev/null || true)
    awk 'NF {count++} END {print count + 0}' <<< "$out"
    return 0
  fi

  if command -v who >/dev/null 2>&1; then
    out=$(host_health_run_timeout "$HOST_HEALTH_TIMEOUT_SEC" who 2>/dev/null || true)
    awk 'NF {count++} END {print count + 0}' <<< "$out"
    return 0
  fi

  printf '0\n'
}

host_health_classify_metric() {
  local value=${1:?usage: host_health_classify_metric <value> <warn> <max>}
  local warn=${2:?usage: host_health_classify_metric <value> <warn> <max>}
  local max=${3:?usage: host_health_classify_metric <value> <warn> <max>}

  if ! [[ "$value" =~ ^[0-9]+$ ]]; then
    printf 'unknown\n'
  elif [[ "$max" =~ ^[0-9]+$ && "$value" -gt "$max" ]]; then
    printf 'critical\n'
  elif [[ "$warn" =~ ^[0-9]+$ && "$value" -gt "$warn" ]]; then
    printf 'warning\n'
  else
    printf 'ok\n'
  fi
}
