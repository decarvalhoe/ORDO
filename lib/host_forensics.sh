#!/usr/bin/env bash
# host_forensics.sh - bounded host forensic/log probe helpers.

if [[ -n "${ORCH_HOST_FORENSICS_LIB_LOADED:-}" ]]; then
  return 0
fi
ORCH_HOST_FORENSICS_LIB_LOADED=1

_ORCH_HOST_FORENSICS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$_ORCH_HOST_FORENSICS_LIB_DIR/process_safety.sh" ]]; then
  # shellcheck source=lib/process_safety.sh
  source "$_ORCH_HOST_FORENSICS_LIB_DIR/process_safety.sh"
fi

: "${ORCH_HOST_FORENSICS_DEGRADED_EXIT_CODE:=75}"
: "${ORCH_HOST_FORENSICS_TIMEOUT_SEC:=10}"
: "${ORCH_HOST_FORENSICS_JOURNAL_LINES:=200}"
: "${ORCH_HOST_FORENSICS_JOURNAL_MAX_LINES:=500}"
: "${ORCH_HOST_FORENSICS_JOURNAL_SINCE:=-15 min}"
: "${ORCH_HOST_FORENSICS_JOURNAL_UNTIL:=now}"

orch_host_forensics_degraded() {
  local probe=${1:?usage: orch_host_forensics_degraded <probe> <reason> [detail]}
  local reason=${2:?usage: orch_host_forensics_degraded <probe> <reason> [detail]}
  local detail=${3:-}
  detail=${detail//[[:space:]]/_}
  if [[ -n "$detail" ]]; then
    printf 'host_forensics_degraded: probe=%s reason=%s detail=%s action=refuse exit=%s\n' \
      "$probe" "$reason" "$detail" "$ORCH_HOST_FORENSICS_DEGRADED_EXIT_CODE" >&2
  else
    printf 'host_forensics_degraded: probe=%s reason=%s action=refuse exit=%s\n' \
      "$probe" "$reason" "$ORCH_HOST_FORENSICS_DEGRADED_EXIT_CODE" >&2
  fi
  return "$ORCH_HOST_FORENSICS_DEGRADED_EXIT_CODE"
}

_orch_host_forensics_numeric_limit() {
  local value=${1:?usage: _orch_host_forensics_numeric_limit <value> <max> <probe>}
  local max=${2:?usage: _orch_host_forensics_numeric_limit <value> <max> <probe>}
  local probe=${3:?usage: _orch_host_forensics_numeric_limit <value> <max> <probe>}

  if ! [[ "$value" =~ ^[0-9]+$ ]] || [[ "$value" -le 0 ]]; then
    orch_host_forensics_degraded "$probe" "invalid_line_limit" "value=${value}"
    return "$ORCH_HOST_FORENSICS_DEGRADED_EXIT_CODE"
  fi
  if [[ "$value" -gt "$max" ]]; then
    orch_host_forensics_degraded "$probe" "line_limit_exceeded" "value=${value}:max=${max}"
    return "$ORCH_HOST_FORENSICS_DEGRADED_EXIT_CODE"
  fi
  return 0
}

_orch_host_forensics_validate_journal_args() {
  local max_lines=${ORCH_HOST_FORENSICS_JOURNAL_MAX_LINES:-500}
  local arg next lines_value
  while [[ "$#" -gt 0 ]]; do
    arg=$1
    case "$arg" in
      --user-unit)
        next=${2:-}
        if [[ "$next" == *"*"* ]]; then
          orch_host_forensics_degraded "journalctl" "wildcard_user_unit" "value=${next}"
          return "$ORCH_HOST_FORENSICS_DEGRADED_EXIT_CODE"
        fi
        shift
        ;;
      --user-unit=*)
        next=${arg#--user-unit=}
        if [[ "$next" == *"*"* ]]; then
          orch_host_forensics_degraded "journalctl" "wildcard_user_unit" "value=${next}"
          return "$ORCH_HOST_FORENSICS_DEGRADED_EXIT_CODE"
        fi
        ;;
      -n|--lines)
        lines_value=${2:-}
        _orch_host_forensics_numeric_limit "$lines_value" "$max_lines" "journalctl" || return $?
        shift
        ;;
      -n[0-9]*)
        lines_value=${arg#-n}
        _orch_host_forensics_numeric_limit "$lines_value" "$max_lines" "journalctl" || return $?
        ;;
      --lines=*)
        lines_value=${arg#--lines=}
        _orch_host_forensics_numeric_limit "$lines_value" "$max_lines" "journalctl" || return $?
        ;;
    esac
    shift
  done
  return 0
}

_orch_host_forensics_journal_arg_present() {
  local wanted=${1:?usage: _orch_host_forensics_journal_arg_present <since|until|lines> [args...]}
  shift
  local arg
  while [[ "$#" -gt 0 ]]; do
    arg=$1
    case "$wanted:$arg" in
      since:--since|since:--since=*|until:--until|until:--until=*|lines:-n|lines:-n[0-9]*|lines:--lines|lines:--lines=*)
        return 0
        ;;
    esac
    shift
  done
  return 1
}

orch_host_forensics_journalctl() {
  local max_lines=${ORCH_HOST_FORENSICS_JOURNAL_MAX_LINES:-500}
  local lines=${ORCH_HOST_FORENSICS_JOURNAL_LINES:-200}
  local timeout_sec=${ORCH_HOST_FORENSICS_TIMEOUT_SEC:-10}
  local tmp_root tmp_file rc arg
  local -a original_args=("$@")
  local -a journal_args=(--no-pager)

  _orch_host_forensics_numeric_limit "$lines" "$max_lines" "journalctl" || return $?
  [[ "$timeout_sec" =~ ^[0-9]+$ && "$timeout_sec" -gt 0 ]] || timeout_sec=10
  _orch_host_forensics_validate_journal_args "$@" || return $?

  while [[ "$#" -gt 0 ]]; do
    arg=$1
    case "$arg" in
      -n|--lines)
        lines=${2:-$lines}
        shift
        ;;
      -n[0-9]*)
        lines=${arg#-n}
        ;;
      --lines=*)
        lines=${arg#--lines=}
        ;;
    esac
    shift
  done
  set -- "${original_args[@]}"

  if ! _orch_host_forensics_journal_arg_present since "$@"; then
    journal_args+=(--since "$ORCH_HOST_FORENSICS_JOURNAL_SINCE")
  fi
  if ! _orch_host_forensics_journal_arg_present until "$@"; then
    journal_args+=(--until "$ORCH_HOST_FORENSICS_JOURNAL_UNTIL")
  fi
  if ! _orch_host_forensics_journal_arg_present lines "$@"; then
    journal_args+=(-n "$lines")
  fi
  journal_args+=("$@")

  tmp_root=${ORCH_HOST_FORENSICS_TMP_ROOT:-}
  if [[ -z "$tmp_root" ]]; then
    tmp_root=$(mktemp -d -t host-forensics.XXXXXX)
    ORCH_HOST_FORENSICS_TMP_ROOT=$tmp_root
  fi
  mkdir -p "$tmp_root" 2>/dev/null || {
    orch_host_forensics_degraded "journalctl" "tmpdir_unavailable"
    return "$ORCH_HOST_FORENSICS_DEGRADED_EXIT_CODE"
  }
  tmp_file="$tmp_root/journalctl.$$"

  set +e
  if declare -F orch_run_timeout >/dev/null 2>&1; then
    orch_run_timeout "$timeout_sec" journalctl "${journal_args[@]}" > "$tmp_file" 2>&1
  elif command -v timeout >/dev/null 2>&1; then
    timeout "$timeout_sec" journalctl "${journal_args[@]}" > "$tmp_file" 2>&1
  else
    journalctl "${journal_args[@]}" > "$tmp_file" 2>&1
  fi
  rc=$?
  set -e

  if [[ "$rc" -eq "${ORCH_TIMEOUT_EXIT_CODE:-124}" || "$rc" -eq 124 || "$rc" -eq 137 ]]; then
    rm -f "$tmp_file"
    orch_host_forensics_degraded "journalctl" "timeout" "timeout=${timeout_sec}s"
    return "$ORCH_HOST_FORENSICS_DEGRADED_EXIT_CODE"
  fi

  head -n "$lines" "$tmp_file"
  rm -f "$tmp_file"
  if [[ "$rc" -ne 0 ]]; then
    orch_host_forensics_degraded "journalctl" "command_failed" "rc=${rc}"
    return "$ORCH_HOST_FORENSICS_DEGRADED_EXIT_CODE"
  fi
  return 0
}
