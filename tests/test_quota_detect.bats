#!/usr/bin/env bats

load ./helpers.bash

setup() {
  setup_orch_test
}

@test "quota_content_matches recognizes bundled quota patterns" {
  run bash -c "$(orch_env_exports)
    source '$TK/lib/audit_log.sh'
    source '$TK/lib/quota_detect.sh'
    if quota_content_matches '429 Too Many Requests from provider'; then
      printf '%s' \"\$QUOTA_MATCH_PATTERN\"
    fi"

  [ "$status" -eq 0 ]
  [[ "$output" == *"429"* ]]
}

@test "quota_content_matches loads custom patterns from env file" {
  custom_file="$BATS_TEST_TMPDIR/custom-quota-patterns.txt"
  printf '%s\n' 'provider is done for today' > "$custom_file"

  run bash -c "$(orch_env_exports)
    source '$TK/lib/audit_log.sh'
    export QUOTA_PATTERNS_FILE='$custom_file'
    source '$TK/lib/quota_detect.sh'
    if quota_content_matches 'provider is done for today'; then
      printf '%s' \"\$QUOTA_MATCH_PATTERN\"
    fi"

  [ "$status" -eq 0 ]
  [ "$output" = "provider is done for today" ]
}

@test "quota_swap cooldown blocks repeated swaps until expiry" {
  run bash -c "$(orch_env_exports)
    source '$TK/lib/audit_log.sh'
    export QUOTA_SWAP_COOLDOWN_SEC=300
    source '$TK/lib/quota_detect.sh'
    quota_mark_swap claude
    quota_swap_cooldown_active claude"

  [ "$status" -eq 0 ]

  run bash -c "$(orch_env_exports)
    source '$TK/lib/audit_log.sh'
    export QUOTA_SWAP_COOLDOWN_SEC=0
    source '$TK/lib/quota_detect.sh'
    quota_mark_swap claude
    sleep 1
    quota_swap_cooldown_active claude"

  [ "$status" -ne 0 ]
}
