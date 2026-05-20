#!/usr/bin/env bash
# log_retention.sh - operator entrypoint for ORDO/Codex log retention.
#
# Implements the parent finding from ORDO #636: periodic retention of
# /var/log/orch and /root/.codex log artefacts plus a bounded
# checkpoint/vacuum policy for /root/.codex/logs_2.sqlite. The default
# is `--dry-run` so a misconfigured cron entry cannot delete logs;
# `--apply` must be explicit.

set -euo pipefail

TK="${TK:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

usage() {
  cat <<EOF >&2
usage: log_retention.sh [--apply] [--dry-run] [--report]
                        [--orch-dir DIR] [--codex-log-dir DIR]
                        [--sqlite DB]

Reports and (with --apply) enforces a bounded retention policy on the
ORDO and Codex local log surfaces called out in ORDO #636.

Modes:
  --dry-run   (default) report planned actions, do not touch any file.
  --apply     execute the plan; truncate oversize logs, delete rotated
              files beyond the keep count, and checkpoint/vacuum the
              Codex SQLite log database.
  --report    same as --dry-run but additionally print directory totals
              and a summary line for downstream metric collection.

Targets (override via flags or LOG_RETENTION_* env vars):
  --orch-dir DIR        default \$LOG_RETENTION_ORCH_DIR (/var/log/orch)
  --codex-log-dir DIR   default \$LOG_RETENTION_CODEX_LOG_DIR
                        (/root/.codex/log)
  --sqlite DB           default \$LOG_RETENTION_CODEX_SQLITE
                        (/root/.codex/logs_2.sqlite)

Thresholds (env-tunable, see docs/log-retention.md):
  LOG_RETENTION_MAX_FILE_MB        trim file when larger than this (MiB)
  LOG_RETENTION_KEEP_ROTATIONS     keep N rotated files per base
  LOG_RETENTION_MAX_AGE_DAYS       delete files older than this
  LOG_RETENTION_SQLITE_MAX_MB      checkpoint WAL above this (MiB)
  LOG_RETENTION_SQLITE_VACUUM_MB   vacuum SQLite above this (MiB)
  LOG_RETENTION_DIR_WARN_MB        per-directory warn threshold (MiB)
  LOG_RETENTION_DIR_MAX_MB         per-directory max threshold (MiB)
  LOG_RETENTION_TIMEOUT_SEC        per-external-call timeout (seconds)
EOF
}

MODE=dry-run
ORCH_DIR=""
CODEX_LOG_DIR=""
CODEX_SQLITE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply)
      MODE=apply
      shift
      ;;
    --dry-run)
      MODE=dry-run
      shift
      ;;
    --report)
      MODE=report
      shift
      ;;
    --orch-dir)
      ORCH_DIR=${2:?--orch-dir requires a directory}
      shift 2
      ;;
    --codex-log-dir)
      CODEX_LOG_DIR=${2:?--codex-log-dir requires a directory}
      shift 2
      ;;
    --sqlite)
      CODEX_SQLITE=${2:?--sqlite requires a path}
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'unknown arg: %s\n' "$1" >&2
      usage
      exit 2
      ;;
  esac
done

# shellcheck source=lib/log_retention.sh
source "$TK/lib/log_retention.sh"

ORCH_DIR=${ORCH_DIR:-$LOG_RETENTION_ORCH_DIR}
CODEX_LOG_DIR=${CODEX_LOG_DIR:-$LOG_RETENTION_CODEX_LOG_DIR}
CODEX_SQLITE=${CODEX_SQLITE:-$LOG_RETENTION_CODEX_SQLITE}

emit_summary_for_dir() {
  local label=${1:?} dir=${2:?}
  local mb status
  mb=$(log_retention_dir_mb "$dir")
  status=$(log_retention_classify "$mb" \
    "$LOG_RETENTION_DIR_WARN_MB" "$LOG_RETENTION_DIR_MAX_MB")
  printf 'LOG_RETENTION status=%s target=%s path=%s size_mb=%s warn_mb=%s max_mb=%s\n' \
    "$status" "$label" "$dir" "$mb" \
    "$LOG_RETENTION_DIR_WARN_MB" "$LOG_RETENTION_DIR_MAX_MB"
}

emit_summary_for_sqlite() {
  local db=${1:?}
  if [[ ! -f "$db" ]]; then
    printf 'LOG_RETENTION status=ok target=codex_sqlite path=%s size_mb=0 warn_mb=%s max_mb=%s note=missing\n' \
      "$db" "$LOG_RETENTION_SQLITE_MAX_MB" "$LOG_RETENTION_SQLITE_VACUUM_MB"
    return 0
  fi
  local bytes mb status
  bytes=$(log_retention_file_bytes "$db")
  mb=$(( bytes / 1024 / 1024 ))
  status=$(log_retention_classify "$mb" \
    "$LOG_RETENTION_SQLITE_MAX_MB" "$LOG_RETENTION_SQLITE_VACUUM_MB")
  printf 'LOG_RETENTION status=%s target=codex_sqlite path=%s size_mb=%s warn_mb=%s max_mb=%s\n' \
    "$status" "$db" "$mb" \
    "$LOG_RETENTION_SQLITE_MAX_MB" "$LOG_RETENTION_SQLITE_VACUUM_MB"
}

plan_lines_dir() {
  local dir=${1:?}
  [[ -d "$dir" ]] || return 0
  log_retention_plan_dir "$dir"
}

plan_lines_sqlite() {
  local db=${1:?}
  [[ -f "$db" ]] || return 0
  log_retention_plan_sqlite "$db"
}

run_plan_only() {
  local dir db
  for dir in "$ORCH_DIR" "$CODEX_LOG_DIR"; do
    plan_lines_dir "$dir" | while IFS=$'\t' read -r action target reason size age; do
      [[ -n "$action" ]] || continue
      printf 'LOG_RETENTION_PLAN action=%s target=%s reason=%s size_bytes=%s age_days=%s\n' \
        "$action" "$target" "$reason" "$size" "$age"
    done
  done
  plan_lines_sqlite "$CODEX_SQLITE" | while IFS=$'\t' read -r action target reason size age; do
    [[ -n "$action" ]] || continue
    printf 'LOG_RETENTION_PLAN action=%s target=%s reason=%s size_bytes=%s age_days=%s\n' \
      "$action" "$target" "$reason" "$size" "$age"
  done
}

run_apply() {
  local dir
  for dir in "$ORCH_DIR" "$CODEX_LOG_DIR"; do
    [[ -d "$dir" ]] || continue
    log_retention_apply_dir "$dir" | while IFS=$'\t' read -r tag target reason size age; do
      [[ -n "$tag" ]] || continue
      printf 'LOG_RETENTION_APPLY %s target=%s reason=%s size_bytes=%s age_days=%s\n' \
        "$tag" "$target" "$reason" "$size" "$age"
    done
  done
  if [[ -f "$CODEX_SQLITE" ]]; then
    log_retention_apply_sqlite "$CODEX_SQLITE" | while IFS=$'\t' read -r tag target reason size age; do
      [[ -n "$tag" ]] || continue
      printf 'LOG_RETENTION_APPLY %s target=%s reason=%s size_bytes=%s age_days=%s\n' \
        "$tag" "$target" "$reason" "$size" "$age"
    done
  fi
}

emit_summary_for_dir orch_log_dir "$ORCH_DIR"
emit_summary_for_dir codex_log_dir "$CODEX_LOG_DIR"
emit_summary_for_sqlite "$CODEX_SQLITE"

case "$MODE" in
  dry-run|report)
    run_plan_only
    ;;
  apply)
    run_apply
    ;;
esac

exit 0
