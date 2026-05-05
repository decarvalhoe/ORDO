#!/usr/bin/env bash
# state_rollback.sh — restore a project state snapshot from a verified tarball.
#
# Usage:
#   state_rollback.sh --list
#   state_rollback.sh [--yes] [--dry-run] <timestamp-or-archive>
#
# Snapshot contract:
#   - snapshots live in STATE_ROLLBACK_SNAPSHOT_DIR (default: <state-parent>/snapshots)
#   - each archive is paired with <archive>.sha256
#   - each archive contains one top-level directory named exactly $PROJECT
set -euo pipefail
TK="${TK:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

source "$TK/lib/dry_run.sh"
source "$TK/lib/audit_log.sh"

dry_run_parse_args "$@"
set -- "${DRY_RUN_ARGS[@]}"

LIST_ONLY=0
ASSUME_YES=0
SNAPSHOT_REF=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --list)
      LIST_ONLY=1
      shift
      ;;
    --yes)
      ASSUME_YES=1
      shift
      ;;
    -*)
      echo "unknown flag: $1" >&2
      exit 2
      ;;
    *)
      SNAPSHOT_REF=$1
      shift
      ;;
  esac
done

current_state=$(state_dir)
state_parent=$(dirname "$current_state")
snapshot_dir="${STATE_ROLLBACK_SNAPSHOT_DIR:-$state_parent/snapshots}"

list_snapshots() {
  [[ -d "$snapshot_dir" ]] || return 0
  find "$snapshot_dir" -maxdepth 1 -type f -name '*.tar.gz' -printf '%f\n' | sort
}

resolve_snapshot() {
  local ref=${1:?usage: resolve_snapshot <timestamp-or-archive>}
  local -a matches=()

  if [[ -f "$ref" ]]; then
    printf '%s\n' "$ref"
    return 0
  fi

  [[ -d "$snapshot_dir" ]] || {
    echo "snapshot directory not found: $snapshot_dir" >&2
    return 1
  }

  while IFS= read -r match; do
    matches+=("$match")
  done < <(find "$snapshot_dir" -maxdepth 1 -type f -name "*${ref}*.tar.gz" | sort)

  if [[ ${#matches[@]} -eq 1 ]]; then
    printf '%s\n' "${matches[0]}"
    return 0
  fi

  if [[ ${#matches[@]} -eq 0 ]]; then
    echo "no snapshot found for: $ref" >&2
  else
    echo "snapshot reference is ambiguous: $ref" >&2
  fi
  return 1
}

verify_snapshot() {
  local archive=${1:?usage: verify_snapshot <archive-path>}
  local sidecar="${archive}.sha256"

  [[ -f "$sidecar" ]] || {
    echo "missing sha256 sidecar: $sidecar" >&2
    return 1
  }

  (
    cd "$(dirname "$archive")"
    sha256sum -c "$(basename "$sidecar")" >/dev/null
  )
}

if [[ "$LIST_ONLY" -eq 1 ]]; then
  list_snapshots
  exit 0
fi

[[ -n "$SNAPSHOT_REF" ]] || {
  echo "usage: state_rollback.sh [--list] [--yes] [--dry-run] <timestamp-or-archive>" >&2
  exit 2
}

archive=$(resolve_snapshot "$SNAPSHOT_REF")
verify_snapshot "$archive"

if [[ "$ASSUME_YES" -ne 1 ]] && ! dry_run_enabled; then
  read -r -p "Rollback state for $PROJECT from $(basename "$archive")? Type 'yes' to confirm: " yn
  [[ "$yn" == "yes" ]] || {
    echo "aborted"
    exit 1
  }
fi

backup_dir="${current_state}.bak.$(date +%s)"

if dry_run_enabled; then
  dry_run_note "verify sha256 $(basename "$archive")"
  dry_run_note "mv $current_state $backup_dir"
  dry_run_note "tar -xzf $archive -C $state_parent"
  exit 0
fi

if [[ -e "$current_state" ]]; then
  mv "$current_state" "$backup_dir"
fi

restore_failed=0
if ! tar -xzf "$archive" -C "$state_parent"; then
  restore_failed=1
fi

if [[ "$restore_failed" -ne 0 ]]; then
  rm -rf "$current_state"
  if [[ -e "$backup_dir" ]]; then
    mv "$backup_dir" "$current_state"
  fi
  echo "restore failed; original state restored from backup" >&2
  exit 1
fi

audit "STATE_ROLLBACK project=$PROJECT snapshot=$(basename "$archive") backup=$(basename "$backup_dir")"
printf 'OK\n'
