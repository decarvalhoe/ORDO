#!/usr/bin/env bats

load './helpers.bash'

setup() {
  setup_orch_test
  toolkit_file lib/log_bounds.sh >/dev/null
}

@test "state_persist writes content atomically and state_read returns it" {
  local audit_log state_persist
  toolkit_file lib/config_check.sh >/dev/null
  audit_log=$(toolkit_file lib/audit_log.sh)
  state_persist=$(toolkit_file lib/state_persist.sh)

  run bash -lc "$(orch_env_exports)
    source '$audit_log'
    source '$state_persist'
    state_persist notes 'hello world'
    printf 'READ:%s\n' \"\$(state_read notes)\"
  "

  [ "$status" -eq 0 ]
  [[ "$output" == *"READ:hello world"* ]]
  [ -f "$ORCH_STATE_BASE/$PROJECT/notes" ]

  run bash -lc "find '$ORCH_STATE_BASE/$PROJECT' -maxdepth 1 -name 'notes.tmp.*' -print"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "state_append_unique deduplicates identical lines" {
  local audit_log state_persist
  toolkit_file lib/config_check.sh >/dev/null
  audit_log=$(toolkit_file lib/audit_log.sh)
  state_persist=$(toolkit_file lib/state_persist.sh)

  run bash -lc "$(orch_env_exports)
    source '$audit_log'
    source '$state_persist'
    state_append_unique queue 'alpha'
    state_append_unique queue 'alpha'
    state_append_unique queue 'beta'
    cat \"\$ORCH_STATE_BASE/\$PROJECT/queue\"
  "

  [ "$status" -eq 0 ]
  [ "$output" = $'alpha\nbeta' ]
}

@test "state_append_unique treats markdown checkbox lines as literal content" {
  local audit_log state_persist
  toolkit_file lib/config_check.sh >/dev/null
  audit_log=$(toolkit_file lib/audit_log.sh)
  state_persist=$(toolkit_file lib/state_persist.sh)

  run bash -lc "$(orch_env_exports)
    source '$audit_log'
    source '$state_persist'
    state_append_unique queue '- [ ] unblock dispatch recovery'
    state_append_unique queue '- [ ] unblock dispatch recovery'
    cat \"\$ORCH_STATE_BASE/\$PROJECT/queue\"
  "

  [ "$status" -eq 0 ]
  [ "$output" = '- [ ] unblock dispatch recovery' ]
}

@test "state_trim keeps only the last N lines" {
  local audit_log state_persist
  toolkit_file lib/config_check.sh >/dev/null
  audit_log=$(toolkit_file lib/audit_log.sh)
  state_persist=$(toolkit_file lib/state_persist.sh)

  run bash -lc "$(orch_env_exports)
    source '$audit_log'
    source '$state_persist'
    state_append history 'one'
    state_append history 'two'
    state_append history 'three'
    state_trim history 2
    state_read history
  "

  [ "$status" -eq 0 ]
  [ "$output" = $'two\nthree' ]
}

@test "state_read returns empty output for a missing file" {
  local audit_log state_persist
  toolkit_file lib/config_check.sh >/dev/null
  audit_log=$(toolkit_file lib/audit_log.sh)
  state_persist=$(toolkit_file lib/state_persist.sh)

  run bash -lc "$(orch_env_exports)
    source '$audit_log'
    source '$state_persist'
    state_read missing
  "

  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
