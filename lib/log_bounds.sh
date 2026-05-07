#!/usr/bin/env bash
# log_bounds.sh - small rotation helpers for ORDO-managed local logs.

: "${ORCH_LOG_MAX_BYTES:=5242880}"
: "${ORCH_LOG_ROTATE_KEEP:=3}"

orch_log_rotate_if_needed() {
  local log_file=${1:?usage: orch_log_rotate_if_needed <log-file> [max-bytes] [keep]}
  local max_bytes=${2:-$ORCH_LOG_MAX_BYTES}
  local keep=${3:-$ORCH_LOG_ROTATE_KEEP}
  local size i

  [[ "$max_bytes" =~ ^[0-9]+$ ]] || max_bytes=5242880
  [[ "$keep" =~ ^[0-9]+$ ]] || keep=3
  [[ "$max_bytes" -gt 0 ]] || return 0
  [[ -f "$log_file" ]] || return 0

  size=$(wc -c < "$log_file" 2>/dev/null | tr -d ' ') || return 0
  [[ "${size:-0}" =~ ^[0-9]+$ ]] || return 0
  [[ "$size" -gt "$max_bytes" ]] || return 0

  mkdir -p "$(dirname "$log_file")" 2>/dev/null || true

  if [[ "$keep" -eq 0 ]]; then
    : > "$log_file"
    return 0
  fi

  rm -f "$log_file.$keep" 2>/dev/null || true
  for ((i = keep - 1; i >= 1; i--)); do
    [[ -f "$log_file.$i" ]] && mv "$log_file.$i" "$log_file.$((i + 1))"
  done
  mv "$log_file" "$log_file.1" 2>/dev/null || return 0
  : > "$log_file"
}
