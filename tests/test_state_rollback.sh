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

mkdir -p "$SANITIZED_ROOT/scripts" "$SANITIZED_ROOT/lib"

for rel in \
  scripts/state_rollback.sh \
  lib/audit_log.sh \
  lib/config_check.sh \
  lib/config_resolver.sh \
  lib/dry_run.sh
do
  tr -d '\r' < "$ROOT/$rel" > "$SANITIZED_ROOT/$rel"
done

chmod +x "$SANITIZED_ROOT/scripts/state_rollback.sh"

snapshot_dir="$TEST_TMP/snapshots"
state_base="$TEST_TMP/state-base"
current_state="$state_base/rollback-test"
source_tree="$TEST_TMP/source-state"
source_payload="$source_tree/rollback-test"

mkdir -p "$snapshot_dir" "$current_state" "$source_payload"
printf '%s\n' 'old-state' > "$current_state/assignments.json"
printf '%s\n' 'restored-state' > "$source_payload/assignments.json"
printf '%s\n' 'new-journal' > "$source_payload/journal.txt"

snapshot_name="rollback-test-20260505T091500Z.tar.gz"
(
  cd "$source_tree"
  tar -czf "$snapshot_dir/$snapshot_name" rollback-test
)
(
  cd "$snapshot_dir"
  sha256sum "$snapshot_name" > "$snapshot_name.sha256"
)

list_output=$(
  PROJECT="rollback-test" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$state_base" \
  STATE_ROLLBACK_SNAPSHOT_DIR="$snapshot_dir" \
  AGENT_WORKDIR_TEMPLATE="$TEST_TMP/work/%s" \
  bash "$SANITIZED_ROOT/scripts/state_rollback.sh" --list
)

[[ "$list_output" == *"$snapshot_name"* ]] || fail "expected snapshot listing to include $snapshot_name"

set +e
dry_output=$(
  PROJECT="rollback-test" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$state_base" \
  STATE_ROLLBACK_SNAPSHOT_DIR="$snapshot_dir" \
  AGENT_WORKDIR_TEMPLATE="$TEST_TMP/work/%s" \
  bash "$SANITIZED_ROOT/scripts/state_rollback.sh" --dry-run 20260505T091500Z 2>&1
)
dry_status=$?
set -e

[[ "$dry_status" -eq 0 ]] || fail "expected dry-run rollback to exit 0, got $dry_status: $dry_output"
[[ "$dry_output" == *"DRY-RUN:"* ]] || fail "expected dry-run output, got: $dry_output"
[[ "$(cat "$current_state/assignments.json")" == "old-state" ]] || fail "dry-run must not mutate current state"

set +e
restore_output=$(
  PROJECT="rollback-test" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$state_base" \
  STATE_ROLLBACK_SNAPSHOT_DIR="$snapshot_dir" \
  AGENT_WORKDIR_TEMPLATE="$TEST_TMP/work/%s" \
  bash "$SANITIZED_ROOT/scripts/state_rollback.sh" --yes 20260505T091500Z 2>&1
)
restore_status=$?
set -e

[[ "$restore_status" -eq 0 ]] || fail "expected rollback restore to exit 0, got $restore_status: $restore_output"
[[ "$(cat "$current_state/assignments.json")" == "restored-state" ]] || fail "expected restored assignments.json from snapshot"
[[ "$(cat "$current_state/journal.txt")" == "new-journal" ]] || fail "expected restored journal file from snapshot"

backup_matches=("$state_base"/rollback-test.bak.*)
[[ -e "${backup_matches[0]}" ]] || fail "expected backup directory to be created"
[[ "$(cat "${backup_matches[0]}/assignments.json")" == "old-state" ]] || fail "expected backup to preserve previous state"
[[ "$restore_output" == *"STATE_ROLLBACK"* ]] || fail "expected rollback audit line, got: $restore_output"

printf 'ok - state_rollback lists, previews, and restores state snapshots\n'
