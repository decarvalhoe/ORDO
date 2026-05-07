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
    gov_pr_check_status RBOKproject/ORDO 77
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
    gov_pr_check_status RBOKproject/ORDO 77
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
    gov_pr_check_status RBOKproject/ORDO 77
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
    gov_pr_check_status RBOKproject/ORDO 77
  "

  [ "$status" -eq 0 ]
  [ "$output" = "pass" ]
}

@test "gov_pr_rollup_is_empty true when statusCheckRollup is empty" {
  local governance_check
  governance_check=$(toolkit_file lib/governance_check.sh)

  write_mock_bin gh <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '{"statusCheckRollup":[]}'
EOF

  run bash -lc "$(orch_env_exports)
    source '$governance_check'
    if gov_pr_rollup_is_empty RBOKproject/ORDO 99; then echo empty; else echo not-empty; fi
  "

  [ "$status" -eq 0 ]
  [ "$output" = "empty" ]
}

@test "gov_pr_rollup_is_empty false when at least one check is reported" {
  local governance_check
  governance_check=$(toolkit_file lib/governance_check.sh)

  write_mock_bin gh <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '{"statusCheckRollup":[{"status":"IN_PROGRESS","conclusion":"","name":"ci"}]}'
EOF

  run bash -lc "$(orch_env_exports)
    source '$governance_check'
    if gov_pr_rollup_is_empty RBOKproject/ORDO 99; then echo empty; else echo not-empty; fi
  "

  [ "$status" -eq 0 ]
  [ "$output" = "not-empty" ]
}

@test "gov_pr_scope_kind classifies docs-only PR" {
  local governance_check
  governance_check=$(toolkit_file lib/governance_check.sh)

  write_mock_bin gh <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '{"files":[{"path":"docs/architecture.md"},{"path":"docs/runbook/oncall.md"}]}'
EOF

  run bash -lc "$(orch_env_exports)
    source '$governance_check'
    gov_pr_scope_kind RBOKproject/ORDO 33
  "

  [ "$status" -eq 0 ]
  [ "$output" = "docs-only" ]
}

@test "gov_pr_scope_kind classifies workflow-only PR" {
  local governance_check
  governance_check=$(toolkit_file lib/governance_check.sh)

  write_mock_bin gh <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '{"files":[{"path":".github/workflows/ci.yml"},{"path":".github/workflows/release.yml"}]}'
EOF

  run bash -lc "$(orch_env_exports)
    source '$governance_check'
    gov_pr_scope_kind RBOKproject/ORDO 34
  "

  [ "$status" -eq 0 ]
  [ "$output" = "workflow-only" ]
}

@test "gov_pr_scope_kind classifies docs-and-workflow mix" {
  local governance_check
  governance_check=$(toolkit_file lib/governance_check.sh)

  write_mock_bin gh <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '{"files":[{"path":"docs/onboarding.md"},{"path":".github/workflows/ci.yml"}]}'
EOF

  run bash -lc "$(orch_env_exports)
    source '$governance_check'
    gov_pr_scope_kind RBOKproject/ORDO 35
  "

  [ "$status" -eq 0 ]
  [ "$output" = "docs-and-workflow" ]
}

@test "gov_pr_scope_kind drops to code if any non-matching path is present" {
  local governance_check
  governance_check=$(toolkit_file lib/governance_check.sh)

  write_mock_bin gh <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '{"files":[{"path":"docs/onboarding.md"},{"path":"lib/pr_merge.sh"}]}'
EOF

  run bash -lc "$(orch_env_exports)
    source '$governance_check'
    gov_pr_scope_kind RBOKproject/ORDO 36
  "

  [ "$status" -eq 0 ]
  [ "$output" = "code" ]
}

@test "gov_pr_scope_kind reports empty when no files are returned" {
  local governance_check
  governance_check=$(toolkit_file lib/governance_check.sh)

  write_mock_bin gh <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '{"files":[]}'
EOF

  run bash -lc "$(orch_env_exports)
    source '$governance_check'
    gov_pr_scope_kind RBOKproject/ORDO 37
  "

  [ "$status" -eq 0 ]
  [ "$output" = "empty" ]
}

@test "gov_pr_no_check_allowed permits docs-only and workflow-only and mix" {
  local governance_check
  governance_check=$(toolkit_file lib/governance_check.sh)

  # docs-only
  write_mock_bin gh <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '{"files":[{"path":"docs/x.md"}]}'
EOF
  run bash -lc "$(orch_env_exports)
    source '$governance_check'
    if gov_pr_no_check_allowed RBOKproject/ORDO 41; then echo allowed; else echo refused; fi
  "
  [ "$status" -eq 0 ]
  [ "$output" = "allowed" ]

  # workflow-only
  write_mock_bin gh <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '{"files":[{"path":".github/workflows/y.yml"}]}'
EOF
  run bash -lc "$(orch_env_exports)
    source '$governance_check'
    if gov_pr_no_check_allowed RBOKproject/ORDO 42; then echo allowed; else echo refused; fi
  "
  [ "$status" -eq 0 ]
  [ "$output" = "allowed" ]

  # docs-and-workflow
  write_mock_bin gh <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '{"files":[{"path":"docs/z.md"},{"path":".github/workflows/z.yml"}]}'
EOF
  run bash -lc "$(orch_env_exports)
    source '$governance_check'
    if gov_pr_no_check_allowed RBOKproject/ORDO 43; then echo allowed; else echo refused; fi
  "
  [ "$status" -eq 0 ]
  [ "$output" = "allowed" ]
}

@test "gov_pr_no_check_allowed refuses code-touching and empty scopes" {
  local governance_check
  governance_check=$(toolkit_file lib/governance_check.sh)

  # mixed code + docs
  write_mock_bin gh <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '{"files":[{"path":"docs/z.md"},{"path":"src/index.ts"}]}'
EOF
  run bash -lc "$(orch_env_exports)
    source '$governance_check'
    if gov_pr_no_check_allowed RBOKproject/ORDO 44; then echo allowed; else echo refused; fi
  "
  [ "$status" -eq 0 ]
  [ "$output" = "refused" ]

  # empty file list
  write_mock_bin gh <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '{"files":[]}'
EOF
  run bash -lc "$(orch_env_exports)
    source '$governance_check'
    if gov_pr_no_check_allowed RBOKproject/ORDO 45; then echo allowed; else echo refused; fi
  "
  [ "$status" -eq 0 ]
  [ "$output" = "refused" ]
}

@test "gov_admin_bypass_allowed accepts not-applicable as it does pass" {
  local governance_check
  governance_check=$(toolkit_file lib/governance_check.sh)

  run bash -lc "
    source '$governance_check'
    gov_admin_bypass_allowed not-applicable BLOCKED; printf 'na-blocked:%s\n' \$?
    gov_admin_bypass_allowed not-applicable CLEAN; printf 'na-clean:%s\n' \$?
    gov_admin_bypass_allowed not-applicable BEHIND; printf 'na-behind:%s\n' \$?
  "

  [ "$status" -eq 0 ]
  [ "$output" = $'na-blocked:0\nna-clean:0\nna-behind:1' ]
}
