#!/usr/bin/env bash
# dry_run.sh — common helpers for non-mutating previews.

dry_run_parse_args() {
  local -a forwarded=()
  local arg

  DRY_RUN=0
  case "${ORCH_DRY_RUN:-0}" in
    1|true|TRUE|yes|YES|on|ON)
      DRY_RUN=1
      ;;
  esac

  for arg in "$@"; do
    case "$arg" in
      --dry-run)
        DRY_RUN=1
        ;;
      *)
        forwarded+=("$arg")
        ;;
    esac
  done

  ORCH_DRY_RUN="$DRY_RUN"
  # shellcheck disable=SC2034
  DRY_RUN_ARGS=("${forwarded[@]}")
}

dry_run_enabled() {
  [[ "${ORCH_DRY_RUN:-0}" == "1" ]]
}

dry_run_note() {
  printf 'DRY-RUN: %s\n' "$*"
}

dry_run_exec() {
  local description="${1:?usage: dry_run_exec <description> <cmd> [args...]}"
  shift

  if dry_run_enabled; then
    dry_run_note "$description"
    return 0
  fi

  "$@"
}
