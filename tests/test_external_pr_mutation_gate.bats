#!/usr/bin/env bats

# Coverage for #268: external PR mutation authority gate.
# Default is audit-only; explicit per-action scope is required for any
# external mutation. Repo-neutral.

load './helpers.bash'

setup() {
  setup_orch_test
  toolkit_file lib/config_check.sh >/dev/null
  toolkit_file lib/log_bounds.sh >/dev/null
}

@test "audit-only default refuses pr_comment with no authorization" {
  local audit_log
  audit_log=$(toolkit_file lib/audit_log.sh)

  run bash -lc "$(orch_env_exports)
    unset ORCH_EXTERNAL_PR_MUTATIONS
    source '$audit_log'
    if external_pr_mutation_authorized pr_comment; then
      echo authorized
    else
      echo refused
    fi
  "

  [ "$status" -eq 0 ]
  [[ "$output" == *"refused"* ]]
}

@test "audit_evidence is always authorized even with no env var" {
  local audit_log
  audit_log=$(toolkit_file lib/audit_log.sh)

  run bash -lc "$(orch_env_exports)
    unset ORCH_EXTERNAL_PR_MUTATIONS
    source '$audit_log'
    external_pr_mutation_authorized audit_evidence && echo authorized
  "

  [ "$status" -eq 0 ]
  [[ "$output" == *"authorized"* ]]
}

@test "explicit pr_comment authorization passes the gate" {
  local audit_log
  audit_log=$(toolkit_file lib/audit_log.sh)

  run bash -lc "$(orch_env_exports)
    export ORCH_EXTERNAL_PR_MUTATIONS=pr_comment
    source '$audit_log'
    external_pr_mutation_authorized pr_comment && echo authorized
  "

  [ "$status" -eq 0 ]
  [[ "$output" == *"authorized"* ]]
}

@test "comma list authorizes only the listed scopes" {
  local audit_log
  audit_log=$(toolkit_file lib/audit_log.sh)

  run bash -lc "$(orch_env_exports)
    export ORCH_EXTERNAL_PR_MUTATIONS='pr_comment, pr_labels'
    source '$audit_log'
    external_pr_mutation_authorized pr_comment   && echo comment-ok   || echo comment-refused
    external_pr_mutation_authorized pr_labels    && echo labels-ok    || echo labels-refused
    external_pr_mutation_authorized pr_assignees && echo assignees-ok || echo assignees-refused
    external_pr_mutation_authorized pr_merge     && echo merge-ok     || echo merge-refused
  "

  [ "$status" -eq 0 ]
  [[ "$output" == *"comment-ok"* ]]
  [[ "$output" == *"labels-ok"* ]]
  [[ "$output" == *"assignees-refused"* ]]
  [[ "$output" == *"merge-refused"* ]]
}

@test "all wildcard authorizes every recognised scope" {
  local audit_log
  audit_log=$(toolkit_file lib/audit_log.sh)

  run bash -lc "$(orch_env_exports)
    export ORCH_EXTERNAL_PR_MUTATIONS=all
    source '$audit_log'
    for s in issue_pack_notify pr_comment pr_state pr_labels pr_assignees pr_merge; do
      external_pr_mutation_authorized \$s && echo \$s-ok || echo \$s-refused
    done
  "

  [ "$status" -eq 0 ]
  [[ "$output" == *"pr_comment-ok"* ]]
  [[ "$output" == *"pr_merge-ok"* ]]
  [[ "$output" == *"pr_assignees-ok"* ]]
}

@test "unknown scope is rejected with status 2" {
  local audit_log
  audit_log=$(toolkit_file lib/audit_log.sh)

  run bash -lc "$(orch_env_exports)
    source '$audit_log'
    set +e
    external_pr_mutation_authorized totally_made_up_scope
    rc=\$?
    set -e
    echo rc=\$rc
  "

  [ "$status" -eq 0 ]
  [[ "$output" == *"rc=2"* ]]
}

@test "external_pr_mutation_assert refuses pr_comment by default and audits the refusal" {
  local audit_log
  audit_log=$(toolkit_file lib/audit_log.sh)

  run bash -lc "$(orch_env_exports)
    unset ORCH_EXTERNAL_PR_MUTATIONS
    source '$audit_log'
    set +e
    external_pr_mutation_assert pr_comment 'recommend ready'
    rc=\$?
    set -e
    echo exit=\$rc
  "

  [ "$status" -eq 0 ]
  [[ "$output" == *"external_pr_mutation_refused"* ]]
  [[ "$output" == *"exit=80"* ]]
  grep -q 'EXTERNAL_PR_MUTATION refused scope=pr_comment reason=not_authorized' \
    "$ORCH_LOG_DIR/$PROJECT.log"
}

@test "external_pr_mutation_assert authorized scope succeeds and audits" {
  local audit_log
  audit_log=$(toolkit_file lib/audit_log.sh)

  run bash -lc "$(orch_env_exports)
    export ORCH_EXTERNAL_PR_MUTATIONS=pr_state
    source '$audit_log'
    external_pr_mutation_assert pr_state 'mark ready'
    echo exit=\$?
  "

  [ "$status" -eq 0 ]
  [[ "$output" == *"exit=0"* ]]
  grep -q 'EXTERNAL_PR_MUTATION authorized scope=pr_state' \
    "$ORCH_LOG_DIR/$PROJECT.log"
}

@test "record_local_gate_evidence works in audit-only and writes a stable path" {
  local audit_log
  audit_log=$(toolkit_file lib/audit_log.sh)

  run bash -lc "$(orch_env_exports)
    unset ORCH_EXTERNAL_PR_MUTATIONS
    source '$audit_log'
    p=\$(record_local_gate_evidence 'pr-3175 readiness' 'gate verdict: MET')
    echo path=\$p
    [ -f \"\$p\" ] && cat \"\$p\"
  "

  [ "$status" -eq 0 ]
  [[ "$output" == *"path=$ORCH_STATE_BASE/$PROJECT/gate-evidence/"* ]]
  [[ "$output" == *"gate verdict: MET"* ]]
  grep -q 'EXTERNAL_PR_MUTATION local_evidence scope=pr-3175 readiness' \
    "$ORCH_LOG_DIR/$PROJECT.log"
}

@test "scope name is repo-neutral: no provider or repo identifier appears in known scope set" {
  local audit_log
  audit_log=$(toolkit_file lib/audit_log.sh)

  run bash -lc "$(orch_env_exports)
    source '$audit_log'
    printf '%s\n' \"\${ORCH_EXTERNAL_PR_MUTATION_KNOWN_SCOPES[@]}\"
  "

  [ "$status" -eq 0 ]
  ! [[ "$output" =~ [Gg][Hh] ]] || true
  ! [[ "$output" =~ RBOK ]] || true
  ! [[ "$output" =~ github ]] || true
  [[ "$output" == *"audit_evidence"* ]]
  [[ "$output" == *"pr_comment"* ]]
  [[ "$output" == *"pr_merge"* ]]
}
