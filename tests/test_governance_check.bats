#!/usr/bin/env bats

load './helpers.bash'

setup() {
  setup_orch_test
}

@test "gov_admin_bypass_allowed truth table matches policy" {
  local governance_check
  governance_check=$(toolkit_file lib/governance_check.sh)

  run bash -lc "
    source '$governance_check'
    gov_admin_bypass_allowed pass BLOCKED; printf 'blocked:%s\n' \$?
    gov_admin_bypass_allowed pass CLEAN; printf 'clean:%s\n' \$?
    gov_admin_bypass_allowed pass BEHIND; printf 'behind:%s\n' \$?
    gov_admin_bypass_allowed fail BLOCKED; printf 'fail:%s\n' \$?
    gov_admin_bypass_allowed pending UNSTABLE; printf 'pending:%s\n' \$?
  "

  [ "$status" -eq 0 ]
  [ "$output" = $'blocked:0\nclean:0\nbehind:1\nfail:1\npending:1' ]
}

@test "gov_pr_check_status returns pending when no checks are reported" {
  local governance_check
  governance_check=$(toolkit_file lib/governance_check.sh)

  write_mock_bin gh <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '{"statusCheckRollup":[]}'
EOF

  run bash -lc "$(orch_env_exports)
    source '$governance_check'
    gov_pr_check_status RBOKproject/orchestrator-toolkit 77
  "

  [ "$status" -eq 0 ]
  [ "$output" = "pending" ]
}

@test "gov_pr_check_status returns fail when any required check fails" {
  local governance_check
  governance_check=$(toolkit_file lib/governance_check.sh)

  write_mock_bin gh <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '{"statusCheckRollup":[{"status":"COMPLETED","conclusion":"SUCCESS","name":"lint"},{"status":"COMPLETED","conclusion":"FAILURE","name":"test"}]}'
EOF

  run bash -lc "$(orch_env_exports)
    source '$governance_check'
    gov_pr_check_status RBOKproject/orchestrator-toolkit 77
  "

  [ "$status" -eq 0 ]
  [ "$output" = "fail" ]
}

@test "gov_pr_check_status returns pending while a check is in progress" {
  local governance_check
  governance_check=$(toolkit_file lib/governance_check.sh)

  write_mock_bin gh <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '{"statusCheckRollup":[{"status":"IN_PROGRESS","conclusion":"","name":"test"}]}'
EOF

  run bash -lc "$(orch_env_exports)
    source '$governance_check'
    gov_pr_check_status RBOKproject/orchestrator-toolkit 77
  "

  [ "$status" -eq 0 ]
  [ "$output" = "pending" ]
}

@test "gov_pr_check_status returns pass when all checks succeeded" {
  local governance_check
  governance_check=$(toolkit_file lib/governance_check.sh)

  write_mock_bin gh <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '{"statusCheckRollup":[{"status":"COMPLETED","conclusion":"SUCCESS","name":"lint"},{"status":"COMPLETED","conclusion":"SUCCESS","name":"test"}]}'
EOF

  run bash -lc "$(orch_env_exports)
    source '$governance_check'
    gov_pr_check_status RBOKproject/orchestrator-toolkit 77
  "

  [ "$status" -eq 0 ]
  [ "$output" = "pass" ]
}
