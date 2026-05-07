#!/usr/bin/env bash
# lib/test_sanitize.sh — shared toolkit-copy helper for tests/test_*.sh.
#
# Solves issue #148 (recurring whitelist drift): every new lib/*.sh added
# to the codebase no longer requires touching N hardcoded per-test
# whitelists. The helper copies the entire lib/ tree (with CRLF -> LF
# translation) into a sanitized toolkit root, plus any explicit extra
# paths the caller needs (typically scripts/*.sh, templates/*,
# examples/*). The executable bit is preserved when the source file is
# executable so callers can drop redundant `chmod +x` calls.
#
# Usage:
#   ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
#   SANITIZED_ROOT="$TEST_TMP/toolkit"
#   # shellcheck source=lib/test_sanitize.sh
#   source "$ROOT/lib/test_sanitize.sh"
#   sanitize_toolkit_copy "$SANITIZED_ROOT" \
#     scripts/dispatch_ticket.sh \
#     scripts/recover.sh \
#     templates/dispatch-canonical.md.tpl
#
# Caller MUST set $ROOT (repo root containing lib/, scripts/, ...).
# Returns non-zero if $ROOT is unset or a requested extra path is
# missing in $ROOT. lib/*.sh entries passed as extras are ignored
# silently because they are already covered by the default sweep.

if [[ -n "${TEST_SANITIZE_LIB_LOADED:-}" ]]; then
  return 0
fi
TEST_SANITIZE_LIB_LOADED=1

sanitize_toolkit_copy() {
  local dest_root=${1:-}
  shift || true
  local src_root=${ROOT:-}

  if [[ -z "$dest_root" ]]; then
    printf 'sanitize_toolkit_copy: missing destination root\n' >&2
    return 2
  fi
  if [[ -z "$src_root" || ! -d "$src_root/lib" ]]; then
    printf 'sanitize_toolkit_copy: ROOT must point at the repo root (got: %s)\n' \
      "$src_root" >&2
    return 2
  fi

  mkdir -p "$dest_root/lib"

  local lib_src rel
  for lib_src in "$src_root"/lib/*.sh; do
    [[ -f "$lib_src" ]] || continue
    rel="lib/$(basename "$lib_src")"
    tr -d '\r' < "$lib_src" > "$dest_root/$rel"
    if [[ -x "$lib_src" ]]; then
      chmod +x "$dest_root/$rel"
    fi
  done

  local src
  for rel in "$@"; do
    [[ -n "$rel" ]] || continue
    if [[ "$rel" == lib/*.sh ]]; then
      # Already covered by the default lib/ sweep above; ignore so that
      # adding a new lib helper to the test never needs an extra arg.
      continue
    fi
    src="$src_root/$rel"
    if [[ ! -f "$src" ]]; then
      printf 'sanitize_toolkit_copy: missing source file %s\n' "$src" >&2
      return 1
    fi
    mkdir -p "$dest_root/$(dirname "$rel")"
    tr -d '\r' < "$src" > "$dest_root/$rel"
    if [[ -x "$src" ]]; then
      chmod +x "$dest_root/$rel"
    fi
  done
}
