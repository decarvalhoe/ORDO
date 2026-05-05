#!/usr/bin/env bats

load './helpers.bash'

setup() {
  setup_orch_test
}

@test "audit writes a timestamped line and appends to the project log" {
  local audit_log
  toolkit_file lib/config_check.sh >/dev/null
  audit_log=$(toolkit_file lib/audit_log.sh)

  run bash -lc "$(orch_env_exports)
    source '$audit_log'
    audit 'TEST_EVENT hello'
  "

  [ "$status" -eq 0 ]
  [[ "$output" =~ ^AUDIT\ LOG:\ [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\ TEST_EVENT\ hello$ ]]
  grep -q 'TEST_EVENT hello' "$ORCH_LOG_DIR/$PROJECT.log"
}

@test "audit_action preserves structured key=value payloads" {
  local audit_log
  toolkit_file lib/config_check.sh >/dev/null
  audit_log=$(toolkit_file lib/audit_log.sh)

  run bash -lc "$(orch_env_exports)
    source '$audit_log'
    audit_action DISPATCH agent=claude ticket=#42
  "

  [ "$status" -eq 0 ]
  [[ "$output" == *"DISPATCH agent=claude ticket=#42"* ]]
}

@test "state_dir returns the project-scoped directory and creates it" {
  local audit_log
  toolkit_file lib/config_check.sh >/dev/null
  audit_log=$(toolkit_file lib/audit_log.sh)

  run bash -lc "$(orch_env_exports)
    source '$audit_log'
    state_dir
  "

  [ "$status" -eq 0 ]
  [ "$output" = "$ORCH_STATE_BASE/$PROJECT" ]
  [ -d "$ORCH_STATE_BASE/$PROJECT" ]
}

@test "die logs a fatal line and exits 1" {
  local audit_log
  toolkit_file lib/config_check.sh >/dev/null
  audit_log=$(toolkit_file lib/audit_log.sh)

  run bash -lc "$(orch_env_exports)
    source '$audit_log'
    die 'boom'
  "

  [ "$status" -eq 1 ]
  [[ "$output" == *"FATAL: boom"* ]]
}
