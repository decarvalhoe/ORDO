#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP=$(mktemp -d)
SANITIZED_ROOT="$TEST_TMP/toolkit"

cleanup() {
  rm -rf "$TEST_TMP"
}
trap cleanup EXIT

fail() {
  printf 'not ok - %s\n' "$*" >&2
  exit 1
}

mkdir -p "$SANITIZED_ROOT/scripts" "$SANITIZED_ROOT/lib" "$SANITIZED_ROOT/templates" "$SANITIZED_ROOT/examples"

for rel in \
  scripts/orch_loop.sh \
  lib/audit_log.sh \
  lib/config_check.sh \
  lib/preflight.sh \
  lib/state_persist.sh \
  lib/worktree_helpers.sh \
  templates/orch_briefing.md \
  examples/nomos.config.sh
do
  tr -d '\r' < "$ROOT/$rel" > "$SANITIZED_ROOT/$rel"
done

chmod +x "$SANITIZED_ROOT/scripts/orch_loop.sh"

run_home="$TEST_TMP/home"
mkdir -p "$run_home"

set +e
output=$(
  PATH="/usr/bin:/bin" \
  HOME="$run_home" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  TK="$SANITIZED_ROOT" \
  bash "$SANITIZED_ROOT/scripts/orch_loop.sh" nomos 2>&1
)
status=$?
set -e

[[ "$status" -ne 0 ]] || fail "orch_loop should fail fast when required CLIs are missing"
[[ "$output" == *"PREFLIGHT FAIL"* ]] || fail "expected PREFLIGHT FAIL audit line, got: $output"
[[ "$output" == *"claude"* ]] || fail "expected missing claude in output, got: $output"

printf 'ok - orch_loop preflight fails fast on missing CLIs\n'
