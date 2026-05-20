#!/usr/bin/env bats

# test_log_retention.bats - behavioral coverage for lib/log_retention.sh
# and scripts/log_retention.sh (ORDO #747, parent #636).
#
# Tests pin every directory under $BATS_TEST_TMPDIR so the real
# /var/log/orch and /root/.codex paths are never touched.

load './helpers.bash'

setup() {
  setup_orch_test
  LIB=$(toolkit_file lib/log_retention.sh)
  SCRIPT=$(toolkit_file scripts/log_retention.sh)
  toolkit_file lib/process_safety.sh >/dev/null
  export LIB SCRIPT

  export FAKE_ORCH_DIR="$BATS_TEST_TMPDIR/orch-logs"
  export FAKE_CODEX_LOG_DIR="$BATS_TEST_TMPDIR/codex-logs"
  export FAKE_CODEX_SQLITE="$BATS_TEST_TMPDIR/logs_2.sqlite"
  mkdir -p "$FAKE_ORCH_DIR" "$FAKE_CODEX_LOG_DIR"
}

@test "classify reports ok/warning/critical from numeric thresholds" {
  run bash -lc "source '$LIB'
    log_retention_classify 10 100 200
    log_retention_classify 150 100 200
    log_retention_classify 300 100 200
    log_retention_classify notanumber 100 200
  "
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == "ok" ]]
  [[ "${lines[1]}" == "warning" ]]
  [[ "${lines[2]}" == "critical" ]]
  [[ "${lines[3]}" == "unknown" ]]
}

@test "file_bytes returns 0 for missing files and reports real size for existing files" {
  printf 'hello world\n' > "$BATS_TEST_TMPDIR/file.log"
  run bash -lc "source '$LIB'
    log_retention_file_bytes '$BATS_TEST_TMPDIR/nope'
    log_retention_file_bytes '$BATS_TEST_TMPDIR/file.log'
  "
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == "0" ]]
  [[ "${lines[1]}" == "12" ]]
}

@test "plan_dir flags oversize files for truncate but spares small ones" {
  # 2 MiB file with max_file_mb=1 -> truncate; 1-byte file -> no action.
  dd if=/dev/zero of="$FAKE_ORCH_DIR/big.log" bs=1M count=2 status=none
  printf 'x' > "$FAKE_ORCH_DIR/tiny.log"

  run bash -lc "source '$LIB'
    LOG_RETENTION_MAX_FILE_MB=1 LOG_RETENTION_MAX_AGE_DAYS=999 \
      log_retention_plan_dir '$FAKE_ORCH_DIR'
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"truncate"*"big.log"*"oversize"* ]]
  [[ "$output" != *"tiny.log"* ]]
}

@test "plan_dir deletes rotated files beyond the keep count" {
  : > "$FAKE_ORCH_DIR/rbok.log"
  : > "$FAKE_ORCH_DIR/rbok.log.1"
  : > "$FAKE_ORCH_DIR/rbok.log.2"
  : > "$FAKE_ORCH_DIR/rbok.log.3"
  : > "$FAKE_ORCH_DIR/rbok.log.4"
  : > "$FAKE_ORCH_DIR/rbok.log.5.gz"

  run bash -lc "source '$LIB'
    LOG_RETENTION_KEEP_ROTATIONS=3 LOG_RETENTION_MAX_AGE_DAYS=999 \
    LOG_RETENTION_MAX_FILE_MB=999 \
      log_retention_plan_dir '$FAKE_ORCH_DIR'
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"delete"*"rbok.log.4"*"over-keep"* ]]
  [[ "$output" == *"delete"*"rbok.log.5.gz"*"over-keep"* ]]
  [[ "$output" != *"rbok.log.1"* ]]
  [[ "$output" != *"rbok.log.2"* ]]
  [[ "$output" != *"rbok.log.3"* ]]
}

@test "plan_dir deletes files older than max-age-days" {
  : > "$FAKE_ORCH_DIR/recent.log"
  : > "$FAKE_ORCH_DIR/ancient.log"
  # Backdate the ancient file 30 days.
  touch -d '30 days ago' "$FAKE_ORCH_DIR/ancient.log"

  run bash -lc "source '$LIB'
    LOG_RETENTION_KEEP_ROTATIONS=999 LOG_RETENTION_MAX_FILE_MB=999 \
    LOG_RETENTION_MAX_AGE_DAYS=14 \
      log_retention_plan_dir '$FAKE_ORCH_DIR'
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"delete"*"ancient.log"*"aged-out"* ]]
  [[ "$output" != *"recent.log"* ]]
}

@test "apply_dir truncates oversize files in place and deletes over-keep rotations" {
  dd if=/dev/zero of="$FAKE_ORCH_DIR/big.log" bs=1M count=2 status=none
  : > "$FAKE_ORCH_DIR/rbok.log.4"

  run bash -lc "source '$LIB'
    LOG_RETENTION_MAX_FILE_MB=1 LOG_RETENTION_MAX_AGE_DAYS=999 \
    LOG_RETENTION_KEEP_ROTATIONS=3 \
      log_retention_apply_dir '$FAKE_ORCH_DIR'
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"applied=truncate"*"big.log"* ]]
  [[ "$output" == *"applied=delete"*"rbok.log.4"* ]]
  [ -f "$FAKE_ORCH_DIR/big.log" ]
  [ ! -s "$FAKE_ORCH_DIR/big.log" ]
  [ ! -f "$FAKE_ORCH_DIR/rbok.log.4" ]
}

@test "plan_sqlite is silent below warn, emits checkpoint above warn, vacuum above max" {
  # Below warn -> no plan line.
  : > "$FAKE_CODEX_SQLITE"
  run bash -lc "source '$LIB'
    LOG_RETENTION_SQLITE_MAX_MB=10 LOG_RETENTION_SQLITE_VACUUM_MB=50 \
      log_retention_plan_sqlite '$FAKE_CODEX_SQLITE'
  "
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  # Above warn, below vacuum -> checkpoint.
  dd if=/dev/zero of="$FAKE_CODEX_SQLITE" bs=1M count=20 status=none
  run bash -lc "source '$LIB'
    LOG_RETENTION_SQLITE_MAX_MB=10 LOG_RETENTION_SQLITE_VACUUM_MB=50 \
      log_retention_plan_sqlite '$FAKE_CODEX_SQLITE'
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"checkpoint"*"over-warn"* ]]

  # Above vacuum -> vacuum.
  dd if=/dev/zero of="$FAKE_CODEX_SQLITE" bs=1M count=60 status=none
  run bash -lc "source '$LIB'
    LOG_RETENTION_SQLITE_MAX_MB=10 LOG_RETENTION_SQLITE_VACUUM_MB=50 \
      log_retention_plan_sqlite '$FAKE_CODEX_SQLITE'
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"vacuum"*"over-max"* ]]
}

@test "apply_sqlite emits a skip line when sqlite3 is unavailable" {
  dd if=/dev/zero of="$FAKE_CODEX_SQLITE" bs=1M count=20 status=none
  run bash -lc "$(orch_env_exports)
    # Hide any system sqlite3 to exercise the skip path.
    mkdir -p "$BATS_TEST_TMPDIR/empty-bin"; export PATH="$BATS_TEST_TMPDIR/empty-bin"; source "$LIB"
    LOG_RETENTION_SQLITE_MAX_MB=10 LOG_RETENTION_SQLITE_VACUUM_MB=50 \
      log_retention_apply_sqlite '$FAKE_CODEX_SQLITE'
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"applied=skip"*"sqlite3-missing"* ]]
}

@test "scripts/log_retention.sh default mode is dry-run and never deletes" {
  dd if=/dev/zero of="$FAKE_ORCH_DIR/big.log" bs=1M count=2 status=none
  : > "$FAKE_ORCH_DIR/rbok.log.4"
  run bash -lc "
    export LOG_RETENTION_MAX_FILE_MB=1 LOG_RETENTION_MAX_AGE_DAYS=999
    export LOG_RETENTION_KEEP_ROTATIONS=3
    bash '$SCRIPT' --orch-dir '$FAKE_ORCH_DIR' \
                   --codex-log-dir '$FAKE_CODEX_LOG_DIR' \
                   --sqlite '$FAKE_CODEX_SQLITE'
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"LOG_RETENTION_PLAN action=truncate"* ]]
  [[ "$output" == *"LOG_RETENTION_PLAN action=delete"*"rbok.log.4"* ]]
  [[ "$output" != *"LOG_RETENTION_APPLY"* ]]
  # Files must still exist after a dry-run.
  [ -s "$FAKE_ORCH_DIR/big.log" ]
  [ -f "$FAKE_ORCH_DIR/rbok.log.4" ]
}

@test "scripts/log_retention.sh --apply enforces the plan and emits summary lines" {
  dd if=/dev/zero of="$FAKE_ORCH_DIR/big.log" bs=1M count=2 status=none
  : > "$FAKE_ORCH_DIR/rbok.log.4"
  run bash -lc "
    export LOG_RETENTION_MAX_FILE_MB=1 LOG_RETENTION_MAX_AGE_DAYS=999
    export LOG_RETENTION_KEEP_ROTATIONS=3
    bash '$SCRIPT' --apply --orch-dir '$FAKE_ORCH_DIR' \
                           --codex-log-dir '$FAKE_CODEX_LOG_DIR' \
                           --sqlite '$FAKE_CODEX_SQLITE'
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"LOG_RETENTION status="*"target=orch_log_dir"* ]]
  [[ "$output" == *"LOG_RETENTION_APPLY applied=truncate"*"big.log"* ]]
  [[ "$output" == *"LOG_RETENTION_APPLY applied=delete"*"rbok.log.4"* ]]
  [ ! -s "$FAKE_ORCH_DIR/big.log" ]
  [ ! -f "$FAKE_ORCH_DIR/rbok.log.4" ]
}

@test "scripts/log_retention.sh rejects unknown args" {
  run bash -lc "bash '$SCRIPT' --not-a-flag"
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown arg"* ]]
}
