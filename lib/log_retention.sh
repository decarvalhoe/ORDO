#!/usr/bin/env bash
# log_retention.sh - bounded retention helpers for ORDO/Codex local logs.
#
# Covers the parent finding from ORDO #636: /var/log/orch grew multi-MB
# rotated/current files and /root/.codex/logs_2.sqlite reached ~1.1G with
# slow INSERT statements. The helpers below let an operator (or a small
# cron entry) report and enforce a configurable retention policy without
# touching any directory the agent was not explicitly told to manage.
#
# Design constraints:
# - No global filesystem scans. Targets are explicit and operator-bounded.
# - Every external call is wrapped by `log_retention_run_timeout` so a
#   stalled `du`, `find`, or `sqlite3` cannot turn this helper into a
#   long-running probe.
# - Mutation is opt-in. Pure planning (`*_plan`) is the default, applied
#   via `*_apply`. Callers wire dry-run vs apply at the CLI boundary.

_ORCH_LOG_RETENTION_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$_ORCH_LOG_RETENTION_LIB_DIR/process_safety.sh" ]]; then
  # shellcheck source=lib/process_safety.sh
  source "$_ORCH_LOG_RETENTION_LIB_DIR/process_safety.sh"
fi

: "${LOG_RETENTION_TIMEOUT_SEC:=5}"
: "${LOG_RETENTION_ORCH_DIR:=/var/log/orch}"
: "${LOG_RETENTION_CODEX_LOG_DIR:=/root/.codex/log}"
: "${LOG_RETENTION_CODEX_SQLITE:=/root/.codex/logs_2.sqlite}"
: "${LOG_RETENTION_MAX_FILE_MB:=50}"
: "${LOG_RETENTION_KEEP_ROTATIONS:=3}"
: "${LOG_RETENTION_MAX_AGE_DAYS:=14}"
: "${LOG_RETENTION_SQLITE_MAX_MB:=256}"
: "${LOG_RETENTION_SQLITE_VACUUM_MB:=512}"
: "${LOG_RETENTION_DIR_WARN_MB:=512}"
: "${LOG_RETENTION_DIR_MAX_MB:=2048}"

log_retention_run_timeout() {
  local seconds=${1:?usage: log_retention_run_timeout <seconds> <command> [args...]}
  shift
  if declare -F orch_run_timeout >/dev/null 2>&1; then
    orch_run_timeout "$seconds" "$@"
  elif command -v timeout >/dev/null 2>&1; then
    timeout "$seconds" "$@"
  else
    "$@"
  fi
}

log_retention_file_bytes() {
  local path=${1:?usage: log_retention_file_bytes <path>}
  [[ -f "$path" ]] || { printf '0\n'; return 0; }
  local size
  size=$(log_retention_run_timeout "$LOG_RETENTION_TIMEOUT_SEC" \
    stat -c '%s' -- "$path" 2>/dev/null) || size=0
  [[ "$size" =~ ^[0-9]+$ ]] || size=0
  printf '%s\n' "$size"
}

log_retention_file_age_days() {
  # Reports floor(age_days). Files in the future report 0.
  local path=${1:?usage: log_retention_file_age_days <path>}
  [[ -e "$path" ]] || { printf '0\n'; return 0; }
  local mtime now age_sec
  mtime=$(log_retention_run_timeout "$LOG_RETENTION_TIMEOUT_SEC" \
    stat -c '%Y' -- "$path" 2>/dev/null) || mtime=0
  [[ "$mtime" =~ ^[0-9]+$ ]] || mtime=0
  now=$(date +%s 2>/dev/null) || now=0
  [[ "$now" =~ ^[0-9]+$ ]] || now=0
  age_sec=$(( now - mtime ))
  (( age_sec < 0 )) && age_sec=0
  printf '%s\n' $(( age_sec / 86400 ))
}

log_retention_dir_mb() {
  # Bounded directory size in MiB. Returns 0 for missing dirs and
  # 'unknown' if du fails or times out.
  local path=${1:?usage: log_retention_dir_mb <path>}
  [[ -d "$path" ]] || { printf '0\n'; return 0; }
  local out
  out=$(log_retention_run_timeout "$LOG_RETENTION_TIMEOUT_SEC" \
    du -sm -- "$path" 2>/dev/null | awk 'NR == 1 {print $1}') || {
    printf 'unknown\n'
    return 1
  }
  [[ "$out" =~ ^[0-9]+$ ]] || out=0
  printf '%s\n' "$out"
}

log_retention_classify() {
  # Generic threshold classifier shared by host-health and CLI emitters.
  local value=${1:?usage: log_retention_classify <value> <warn> <max>}
  local warn=${2:?usage: log_retention_classify <value> <warn> <max>}
  local max=${3:?usage: log_retention_classify <value> <warn> <max>}
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

_log_retention_emit_action() {
  # Tab-delimited so callers can `cut -f` cleanly. Fields:
  #   action target reason size_bytes age_days
  local action=${1:?usage: _log_retention_emit_action <action> <target> <reason> <size> <age>}
  local target=${2:?}
  local reason=${3:?}
  local size=${4:-0}
  local age=${5:-0}
  printf '%s\t%s\t%s\t%s\t%s\n' "$action" "$target" "$reason" "$size" "$age"
}

log_retention_plan_dir() {
  # Plan retention for one directory. Emits tab-delimited action lines:
  #   truncate <file> oversize <bytes> <age_days>
  #   delete   <file> aged-out <bytes> <age_days>
  #   delete   <file> over-keep <bytes> <age_days>
  # The plan never touches the disk; apply consumes the same lines.
  local dir=${1:?usage: log_retention_plan_dir <dir>}
  local max_file_mb=${2:-$LOG_RETENTION_MAX_FILE_MB}
  local keep=${3:-$LOG_RETENTION_KEEP_ROTATIONS}
  local max_age=${4:-$LOG_RETENTION_MAX_AGE_DAYS}

  [[ -d "$dir" ]] || return 0
  [[ "$max_file_mb" =~ ^[0-9]+$ ]] || max_file_mb=50
  [[ "$keep" =~ ^[0-9]+$ ]] || keep=3
  [[ "$max_age" =~ ^[0-9]+$ ]] || max_age=14

  local max_bytes=$(( max_file_mb * 1024 * 1024 ))
  local file size age base
  declare -A rotation_count=()

  shopt -s nullglob
  local files=("$dir"/*)
  shopt -u nullglob

  for file in "${files[@]}"; do
    [[ -f "$file" ]] || continue
    size=$(log_retention_file_bytes "$file")
    age=$(log_retention_file_age_days "$file")

    if [[ "$size" -gt "$max_bytes" ]]; then
      _log_retention_emit_action truncate "$file" oversize "$size" "$age"
    fi

    if [[ "$age" -gt "$max_age" ]]; then
      _log_retention_emit_action delete "$file" aged-out "$size" "$age"
      continue
    fi

    # Rotation cap: <base>.<N> or <base>.<N>.gz beyond keep are deletable.
    if [[ "$file" =~ \.([0-9]+)(\.gz)?$ ]]; then
      local rot=${BASH_REMATCH[1]}
      if [[ "$rot" -gt "$keep" ]]; then
        _log_retention_emit_action delete "$file" over-keep "$size" "$age"
      fi
    fi
  done
}

log_retention_apply_dir() {
  # Execute the plan from log_retention_plan_dir. Truncate keeps the
  # file in place (preserving any open handle); delete uses rm -f on a
  # single explicit path. Returns 0 on success and prints applied lines
  # prefixed with `applied=` so callers can tee the audit trail.
  local dir=${1:?usage: log_retention_apply_dir <dir>}
  local action target reason size age plan_line
  while IFS=$'\t' read -r action target reason size age; do
    [[ -n "$action" && -n "$target" ]] || continue
    case "$action" in
      truncate)
        if [[ -f "$target" ]]; then
          : > "$target" 2>/dev/null || continue
          printf 'applied=truncate\t%s\t%s\t%s\t%s\n' "$target" "$reason" "$size" "$age"
        fi
        ;;
      delete)
        if [[ -f "$target" ]]; then
          rm -f -- "$target" 2>/dev/null || continue
          printf 'applied=delete\t%s\t%s\t%s\t%s\n' "$target" "$reason" "$size" "$age"
        fi
        ;;
      *)
        continue
        ;;
    esac
  done < <(log_retention_plan_dir "$dir" "${2:-}" "${3:-}" "${4:-}")
}

log_retention_plan_sqlite() {
  # Decide what to do with a Codex-style SQLite log database. Emits:
  #   checkpoint <db> over-warn <bytes> 0
  #   vacuum     <db> over-max  <bytes> 0
  # Never deletes the database. checkpoint(TRUNCATE) reclaims WAL pages
  # without locking out writers for long; vacuum is reserved for the
  # large-file path where the on-disk file itself has bloated.
  local db=${1:?usage: log_retention_plan_sqlite <db>}
  local warn_mb=${2:-$LOG_RETENTION_SQLITE_MAX_MB}
  local vacuum_mb=${3:-$LOG_RETENTION_SQLITE_VACUUM_MB}

  [[ -f "$db" ]] || return 0
  [[ "$warn_mb" =~ ^[0-9]+$ ]] || warn_mb=256
  [[ "$vacuum_mb" =~ ^[0-9]+$ ]] || vacuum_mb=512

  local bytes
  bytes=$(log_retention_file_bytes "$db")
  local mb=$(( bytes / 1024 / 1024 ))

  if [[ "$mb" -gt "$vacuum_mb" ]]; then
    _log_retention_emit_action vacuum "$db" over-max "$bytes" 0
  elif [[ "$mb" -gt "$warn_mb" ]]; then
    _log_retention_emit_action checkpoint "$db" over-warn "$bytes" 0
  fi
}

log_retention_apply_sqlite() {
  # Apply the SQLite plan. If sqlite3 is missing, emit a skip line so
  # the operator can decide whether to install it; we do not silently
  # ignore the workload. Both operations are wrapped by the timeout.
  local db=${1:?usage: log_retention_apply_sqlite <db>}
  if ! command -v sqlite3 >/dev/null 2>&1; then
    printf 'applied=skip\t%s\tsqlite3-missing\t0\t0\n' "$db"
    return 0
  fi

  local action target reason size age
  while IFS=$'\t' read -r action target reason size age; do
    [[ -n "$action" && -n "$target" ]] || continue
    case "$action" in
      checkpoint)
        if log_retention_run_timeout "$LOG_RETENTION_TIMEOUT_SEC" \
          sqlite3 "$target" "PRAGMA wal_checkpoint(TRUNCATE);" >/dev/null 2>&1; then
          printf 'applied=checkpoint\t%s\t%s\t%s\t%s\n' "$target" "$reason" "$size" "$age"
        else
          printf 'applied=skip\t%s\tcheckpoint-failed\t%s\t%s\n' "$target" "$size" "$age"
        fi
        ;;
      vacuum)
        if log_retention_run_timeout "$LOG_RETENTION_TIMEOUT_SEC" \
          sqlite3 "$target" "PRAGMA wal_checkpoint(TRUNCATE); VACUUM;" >/dev/null 2>&1; then
          printf 'applied=vacuum\t%s\t%s\t%s\t%s\n' "$target" "$reason" "$size" "$age"
        else
          printf 'applied=skip\t%s\tvacuum-failed\t%s\t%s\n' "$target" "$size" "$age"
        fi
        ;;
      *)
        continue
        ;;
    esac
  done < <(log_retention_plan_sqlite "$db" "${2:-}" "${3:-}")
}
