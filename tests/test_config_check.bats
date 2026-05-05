#!/usr/bin/env bats

setup() {
  TEST_TMP=$(mktemp -d)
  SANITIZED_ROOT="$TEST_TMP/toolkit"
  mkdir -p "$SANITIZED_ROOT/lib"
  tr -d '\r' < "$BATS_TEST_DIRNAME/../lib/config_check.sh" > "$SANITIZED_ROOT/lib/config_check.sh"
  CONFIG_CHECK="$SANITIZED_ROOT/lib/config_check.sh"
}

teardown() {
  rm -rf "$TEST_TMP"
}

@test "config_check fails when AGENT_WORKDIR_TEMPLATE is missing" {
  run bash -c "unset AGENT_WORKDIR_TEMPLATE; source '$CONFIG_CHECK'"

  [ "$status" -eq 1 ]
  [[ "$output" == *"AGENT_WORKDIR_TEMPLATE must be set in the project config"* ]]
}

@test "config_check preserves the configured workdir template" {
  run env AGENT_WORKDIR_TEMPLATE="/root/repos/RBOK-%s" \
    bash -c "source '$CONFIG_CHECK'; printf \"%s\" \"\$AGENT_WORKDIR_TEMPLATE\""

  [ "$status" -eq 0 ]
  [ "$output" = "/root/repos/RBOK-%s" ]
}
