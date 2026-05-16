#!/usr/bin/env bash
# host_load_gate.sh - optional host pressure gate for dispatch and validators.
#
# Source this library from operational scripts, then call:
#   orch_host_load_gate <context> [off|warn|refuse]
#
# The gate is intentionally opt-in. It runs only when ORCH_HOST_LOAD_GATE=1
# (or ORCH_HOST_GATE=1) is set, or when the supplied mode / ORCH_HOST_GATE_MODE
# is not "off". Missing host metrics are skipped so the gate remains portable
# across Linux, macOS, containers, and minimal CI environments.
#
# shellcheck disable=SC2178 # Bash namerefs point at caller-owned arrays.

if [[ -n "${ORCH_HOST_LOAD_GATE_LIB_LOADED:-}" ]]; then
  return 0
fi
ORCH_HOST_LOAD_GATE_LIB_LOADED=1

_ORCH_HOST_GATE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/process_safety.sh
source "$_ORCH_HOST_GATE_LIB_DIR/process_safety.sh"

: "${ORCH_HOST_GATE_DEGRADED_EXIT_CODE:=75}"
: "${ORCH_HOST_GATE_LOAD_PER_CPU_MAX:=2}"
: "${ORCH_HOST_GATE_FORK_LATENCY_MAX_MS:=${ORCH_VALIDATOR_FORK_LATENCY_MAX_MS:-750}}"
: "${ORCH_HOST_GATE_DISK_PATHS:=/}"
: "${ORCH_HOST_GATE_DISK_USED_MAX_PCT:=90}"
: "${ORCH_HOST_GATE_DF_TIMEOUT_SEC:=2}"
: "${ORCH_HOST_GATE_PS_TIMEOUT_SEC:=${ORCH_PS_TIMEOUT_SEC:-2}}"

_orch_host_gate_truthy() {
  case "${1:-}" in
    1|yes|true|on|force) return 0 ;;
    *) return 1 ;;
  esac
}

_orch_host_gate_mode_normalize() {
  local mode=${1:-off}
  case "$mode" in
    1|yes|true|on) printf 'refuse\n' ;;
    0|no|false|disabled|disable|none) printf 'off\n' ;;
    off|warn|refuse) printf '%s\n' "$mode" ;;
    *) printf 'invalid\n' ;;
  esac
}

_orch_host_gate_enabled() {
  local mode=${1:-off}
  _orch_host_gate_truthy "${ORCH_HOST_LOAD_GATE:-${ORCH_HOST_GATE:-}}" && return 0
  [[ "$mode" != "off" ]]
}

_orch_host_gate_cpu_count() {
  if [[ "${ORCH_HOST_GATE_CPU_COUNT:-}" =~ ^[0-9]+$ ]] \
    && [[ "$ORCH_HOST_GATE_CPU_COUNT" -gt 0 ]]; then
    printf '%s\n' "$ORCH_HOST_GATE_CPU_COUNT"
    return 0
  fi
  if command -v getconf >/dev/null 2>&1; then
    local count
    count=$(getconf _NPROCESSORS_ONLN 2>/dev/null || true)
    if [[ "$count" =~ ^[0-9]+$ ]] && [[ "$count" -gt 0 ]]; then
      printf '%s\n' "$count"
      return 0
    fi
  fi
  if command -v nproc >/dev/null 2>&1; then
    nproc 2>/dev/null && return 0
  fi
  if command -v sysctl >/dev/null 2>&1; then
    sysctl -n hw.ncpu 2>/dev/null && return 0
  fi
  printf '1\n'
}

_orch_host_gate_float_ge() {
  local lhs=${1:?usage: _orch_host_gate_float_ge <lhs> <rhs>}
  local rhs=${2:?usage: _orch_host_gate_float_ge <lhs> <rhs>}
  awk -v lhs="$lhs" -v rhs="$rhs" 'BEGIN { exit !((lhs + 0) >= (rhs + 0)) }'
}

_orch_host_gate_add_reason() {
  local -n _orch_host_gate_reasons_ref=$1
  local reason=${2:?usage: _orch_host_gate_add_reason <array-name> <reason>}
  reason=${reason//[[:space:]]/_}
  _orch_host_gate_reasons_ref+=("$reason")
}

_orch_host_gate_load_check() {
  local -n _orch_host_gate_reasons_ref=$1
  local load_file=${ORCH_HOST_GATE_LOADAVG_FILE:-}
  local load_avg max_load cpu_count

  if [[ -n "$load_file" ]]; then
    [[ -r "$load_file" ]] || return 0
    read -r load_avg _ < "$load_file" || return 0
  elif [[ -r /proc/loadavg ]]; then
    read -r load_avg _ < /proc/loadavg || return 0
  else
    return 0
  fi

  [[ "$load_avg" =~ ^[0-9]+([.][0-9]+)?$ ]] || return 0
  max_load=${ORCH_HOST_GATE_LOAD_AVG_MAX:-}
  if [[ -z "$max_load" ]]; then
    cpu_count=$(_orch_host_gate_cpu_count)
    max_load=$(awk -v cpus="$cpu_count" -v per="$ORCH_HOST_GATE_LOAD_PER_CPU_MAX" \
      'BEGIN { printf "%.2f", (cpus + 0) * (per + 0) }')
  fi
  [[ "$max_load" =~ ^[0-9]+([.][0-9]+)?$ ]] || return 0

  if _orch_host_gate_float_ge "$load_avg" "$max_load"; then
    _orch_host_gate_add_reason "$1" \
      "load_average:one_min=${load_avg}:threshold=${max_load}:cpus=$(_orch_host_gate_cpu_count)"
  fi
  return 0
}

_orch_host_gate_fork_check() {
  local -n _orch_host_gate_reasons_ref=$1
  local max_ms=${ORCH_HOST_GATE_FORK_LATENCY_MAX_MS:-}
  local latency_ms

  [[ "$max_ms" =~ ^[0-9]+$ ]] || return 0
  if [[ -n "${ORCH_HOST_GATE_FORK_LATENCY_MS:-}" ]]; then
    latency_ms=$ORCH_HOST_GATE_FORK_LATENCY_MS
  else
    latency_ms=$(orch_fork_latency_ms) || {
      _orch_host_gate_add_reason "$1" "fork_latency:unavailable:threshold_ms=${max_ms}"
      return 0
    }
  fi
  [[ "$latency_ms" =~ ^[0-9]+$ ]] || return 0

  if [[ "$latency_ms" -ge "$max_ms" ]]; then
    _orch_host_gate_add_reason "$1" \
      "fork_latency:ms=${latency_ms}:threshold_ms=${max_ms}"
  fi
  return 0
}

_orch_host_gate_disk_lines() {
  if [[ -n "${ORCH_HOST_GATE_DF_FILE:-}" ]]; then
    [[ -r "$ORCH_HOST_GATE_DF_FILE" ]] || return 0
    cat "$ORCH_HOST_GATE_DF_FILE"
    return 0
  fi

  local path
  for path in $ORCH_HOST_GATE_DISK_PATHS; do
    orch_run_timeout "$ORCH_HOST_GATE_DF_TIMEOUT_SEC" df -P "$path" 2>/dev/null || true
  done
}

_orch_host_gate_disk_check() {
  local -n _orch_host_gate_reasons_ref=$1
  local max_pct=${ORCH_HOST_GATE_DISK_USED_MAX_PCT:-}
  [[ "$max_pct" =~ ^[0-9]+$ ]] || return 0
  [[ "$max_pct" -gt 0 ]] || return 0

  local degraded
  degraded=$(_orch_host_gate_disk_lines | awk -v max="$max_pct" '
    /^Filesystem[[:space:]]/ { next }
    NF >= 6 {
      pct = $5
      gsub(/%/, "", pct)
      if (pct ~ /^[0-9]+$/ && pct + 0 >= max + 0) {
        printf "disk_pressure:path=%s:used_pct=%s:threshold_pct=%s\n", $6, pct, max
      }
    }
  ' || true)

  local reason
  while IFS= read -r reason; do
    [[ -n "$reason" ]] && _orch_host_gate_add_reason "$1" "$reason"
  done <<< "$degraded"
  return 0
}

_orch_host_gate_ps_lines() {
  if [[ -n "${ORCH_HOST_GATE_PS_FILE:-}" ]]; then
    [[ -r "$ORCH_HOST_GATE_PS_FILE" ]] || return 0
    cat "$ORCH_HOST_GATE_PS_FILE"
    return 0
  fi

  orch_run_timeout "$ORCH_HOST_GATE_PS_TIMEOUT_SEC" \
    ps -e -o pid=,ppid=,etimes=,pcpu=,args= --no-headers 2>/dev/null || true
}

_orch_host_gate_process_marker_check() {
  local -n _orch_host_gate_reasons_ref=$1
  local marker_re=${ORCH_HOST_GATE_PROCESS_MARKER_RE:-${ORCH_HOST_GATE_PROCESS_MARKER_PATTERNS:-}}
  [[ -n "$marker_re" ]] || return 0

  local match
  match=$(_orch_host_gate_ps_lines | awk -v re="$marker_re" '
    $0 ~ re {
      count += 1
      if (first_pid == "") {
        first_pid = $1
      }
    }
    END {
      if (count > 0) {
        printf "process_marker:count=%d:first_pid=%s:pattern=configured\n", count, first_pid
      }
    }
  ' || true)
  [[ -n "$match" ]] && _orch_host_gate_add_reason "$1" "$match"
  return 0
}

_orch_host_gate_process_budget_check() {
  local -n _orch_host_gate_reasons_ref=$1
  _orch_host_gate_truthy "${ORCH_HOST_GATE_PROCESS_BUDGET:-0}" || return 0

  local signal status
  set +e
  signal=$(orch_process_budget_signal)
  status=$?
  set -e
  if [[ -n "$signal" || "$status" -ne 0 ]]; then
    _orch_host_gate_add_reason "$1" "process_budget:signals=${signal:-unknown}"
  fi
  return 0
}

_orch_host_gate_reasons_join() {
  local old_ifs=$IFS
  IFS=';'
  printf '%s' "$*"
  IFS=$old_ifs
}

_orch_host_gate_audit() {
  if declare -F audit >/dev/null 2>&1; then
    audit "$*"
  fi
}

orch_host_load_gate() {
  local context=${1:-host}
  local mode
  mode=$(_orch_host_gate_mode_normalize "${2:-${ORCH_HOST_GATE_MODE:-off}}")
  if [[ "$mode" == "off" ]] \
    && _orch_host_gate_truthy "${ORCH_HOST_LOAD_GATE:-${ORCH_HOST_GATE:-}}"; then
    mode=$(_orch_host_gate_mode_normalize "${ORCH_HOST_GATE_DEFAULT_MODE:-refuse}")
  fi

  if [[ "$mode" == "invalid" ]]; then
    printf 'host_load_gate: invalid mode: %s\n' "${2:-${ORCH_HOST_GATE_MODE:-off}}" >&2
    return 2
  fi
  _orch_host_gate_enabled "$mode" || return 0

  local -a reasons=()
  _orch_host_gate_load_check reasons
  _orch_host_gate_fork_check reasons
  _orch_host_gate_disk_check reasons
  _orch_host_gate_process_marker_check reasons
  _orch_host_gate_process_budget_check reasons

  local reason_text
  reason_text=$(_orch_host_gate_reasons_join "${reasons[@]}")
  if [[ "${#reasons[@]}" -eq 0 ]]; then
    _orch_host_gate_audit "HOST_GATE pass context=${context} mode=${mode}"
    if _orch_host_gate_truthy "${ORCH_HOST_GATE_VERBOSE:-0}"; then
      printf 'host_ok: context=%s mode=%s\n' "$context" "$mode" >&2
    fi
    return 0
  fi

  if _orch_host_gate_truthy "${ORCH_HOST_GATE_OVERRIDE:-0}"; then
    local override_reason=${ORCH_HOST_GATE_OVERRIDE_REASON:-unspecified}
    printf 'host_degraded: context=%s action=override reasons=%s override_reason=%s\n' \
      "$context" "$reason_text" "${override_reason//[[:space:]]/_}" >&2
    _orch_host_gate_audit \
      "HOST_GATE override context=${context} mode=${mode} reasons=${reason_text} override_reason=${override_reason//[[:space:]]/_}"
    return 0
  fi

  if [[ "$mode" == "warn" ]]; then
    printf 'host_degraded: context=%s action=warn reasons=%s\n' \
      "$context" "$reason_text" >&2
    _orch_host_gate_audit \
      "HOST_GATE warn context=${context} mode=${mode} reasons=${reason_text}"
    return 0
  fi

  printf 'host_degraded: context=%s action=refuse reasons=%s exit=%s\n' \
    "$context" "$reason_text" "$ORCH_HOST_GATE_DEGRADED_EXIT_CODE" >&2
  _orch_host_gate_audit \
    "HOST_GATE refuse context=${context} mode=${mode} reasons=${reason_text} exit=${ORCH_HOST_GATE_DEGRADED_EXIT_CODE}"
  return "$ORCH_HOST_GATE_DEGRADED_EXIT_CODE"
}

# Issue #710: pre-dispatch loadavg/nproc probe. orch_host_load_gate
# bundles fork latency, disk, ps, and process-budget checks behind a
# single opt-in switch; the dispatcher needs a lighter, unconditional
# probe that only inspects the 1-minute loadavg vs CPU count so it
# can refuse to promote an assignment on a saturated host without
# engaging the heavier per-validator probes.
#
# Returns 0 when the loadavg/cpus ratio is below
# ORCH_HOST_LOAD_DISPATCH_BACKOFF_RATIO (default 0.85), when loadavg
# is unreadable, when CPU count cannot be determined, or when the
# threshold is malformed. Returns
# ORCH_HOST_GATE_DEGRADED_EXIT_CODE (75) when the host is overloaded.
# Exposes ORCH_HOST_LOAD_DISPATCH_BACKOFF_LAST_RATIO,
# ORCH_HOST_LOAD_DISPATCH_BACKOFF_LAST_LOADAVG, and
# ORCH_HOST_LOAD_DISPATCH_BACKOFF_LAST_CPUS so callers can include the
# observed values in their own audit rows.
orch_host_load_dispatch_backoff_check() {
  local context=${1:-dispatch}
  local threshold=${ORCH_HOST_LOAD_DISPATCH_BACKOFF_RATIO:-0.85}
  local load_file=${ORCH_HOST_GATE_LOADAVG_FILE:-/proc/loadavg}
  local load_avg cpus ratio

  ORCH_HOST_LOAD_DISPATCH_BACKOFF_LAST_RATIO=""
  ORCH_HOST_LOAD_DISPATCH_BACKOFF_LAST_LOADAVG=""
  ORCH_HOST_LOAD_DISPATCH_BACKOFF_LAST_CPUS=""

  [[ "$threshold" =~ ^[0-9]+([.][0-9]+)?$ ]] || return 0
  [[ -r "$load_file" ]] || return 0
  read -r load_avg _ < "$load_file" || return 0
  [[ "$load_avg" =~ ^[0-9]+([.][0-9]+)?$ ]] || return 0

  cpus=$(_orch_host_gate_cpu_count)
  [[ "$cpus" =~ ^[0-9]+$ ]] && [[ "$cpus" -gt 0 ]] || return 0

  ratio=$(awk -v l="$load_avg" -v c="$cpus" \
    'BEGIN { printf "%.4f", (l + 0) / (c + 0) }')

  export ORCH_HOST_LOAD_DISPATCH_BACKOFF_LAST_RATIO=$ratio
  export ORCH_HOST_LOAD_DISPATCH_BACKOFF_LAST_LOADAVG=$load_avg
  export ORCH_HOST_LOAD_DISPATCH_BACKOFF_LAST_CPUS=$cpus

  if _orch_host_gate_float_ge "$ratio" "$threshold"; then
    printf 'host_overloaded: context=%s loadavg=%s cpus=%s ratio=%s threshold=%s remediation=wait-or-ignore-host-load-or-validation_policy=ci-delegated\n' \
      "$context" "$load_avg" "$cpus" "$ratio" "$threshold" >&2
    _orch_host_gate_audit \
      "HOST_LOAD_BACKOFF refuse context=${context} loadavg=${load_avg} cpus=${cpus} ratio=${ratio} threshold=${threshold} exit=${ORCH_HOST_GATE_DEGRADED_EXIT_CODE}"
    return "$ORCH_HOST_GATE_DEGRADED_EXIT_CODE"
  fi

  _orch_host_gate_audit \
    "HOST_LOAD_BACKOFF pass context=${context} loadavg=${load_avg} cpus=${cpus} ratio=${ratio} threshold=${threshold}"
  return 0
}
