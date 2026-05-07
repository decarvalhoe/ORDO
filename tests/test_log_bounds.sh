#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP=$(mktemp -d)

cleanup() {
  rm -rf "$TEST_TMP"
}
trap cleanup EXIT

fail() {
  printf 'not ok - %s\n' "$*" >&2
  exit 1
}

source "$ROOT/lib/log_bounds.sh"

log_file="$TEST_TMP/monitor.log"
printf '12345678901\n' > "$log_file"

ORCH_LOG_MAX_BYTES=10 ORCH_LOG_ROTATE_KEEP=2 orch_log_rotate_if_needed "$log_file"
[[ -f "$log_file.1" ]] || fail "expected first rotation file"
[[ ! -s "$log_file" ]] || fail "expected active log to be truncated after rotation"

printf 'abcdefghijk\n' > "$log_file"
ORCH_LOG_MAX_BYTES=10 ORCH_LOG_ROTATE_KEEP=2 orch_log_rotate_if_needed "$log_file"
[[ -f "$log_file.2" ]] || fail "expected second rotation file"
grep -q '12345678901' "$log_file.2" || fail "expected older rotated content to be retained"
grep -q 'abcdefghijk' "$log_file.1" || fail "expected newer rotated content to be retained"

printf 'oversized\n' > "$log_file"
ORCH_LOG_MAX_BYTES=1 ORCH_LOG_ROTATE_KEEP=0 orch_log_rotate_if_needed "$log_file"
[[ ! -s "$log_file" ]] || fail "expected keep=0 to truncate active log"

printf 'ok - log_bounds rotates bounded local logs\n'
