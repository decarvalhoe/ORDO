#!/usr/bin/env bats

# external_mutation_gate.bats — behavior of lib/external_mutation_gate.sh
# under audit-only default, explicit authorization, comma-list scoping,
# the `all` wildcard, and unknown scopes; plus classifier coverage for the
# merge/comment/edit/label/assignee paths called out in issue #289 and
# `record_local_gate_evidence` audit-only fallback.

load './helpers.bash'

setup() {
  setup_orch_test
  toolkit_file lib/log_bounds.sh >/dev/null
  toolkit_file lib/config_check.sh >/dev/null
  AUDIT_LOG=$(toolkit_file lib/audit_log.sh)
  GATE=$(toolkit_file lib/external_mutation_gate.sh)
  export AUDIT_LOG GATE
}

# --- authorization matrix -------------------------------------------------

@test "audit-only default refuses pr_comment with refusal exit code 80" {
  run bash -lc "$(orch_env_exports)
    unset ORCH_EXTERNAL_PR_MUTATIONS
    source '$AUDIT_LOG'
    source '$GATE'
    external_pr_mutation_assert pr_comment dispatch_test
  "
  [ "$status" -eq 80 ]
  [[ "$output" == *"external_pr_mutation_refused: scope=pr_comment"* ]]
  grep -q 'EXTERNAL_PR_MUTATION action=pr_comment mode=refused' \
    "$ORCH_LOG_DIR/$PROJECT.log"
}

@test "audit_evidence is allowed even with no env var (always-on local scope)" {
  run bash -lc "$(orch_env_exports)
    unset ORCH_EXTERNAL_PR_MUTATIONS
    source '$AUDIT_LOG'
    source '$GATE'
    external_pr_mutation_assert audit_evidence local
  "
  [ "$status" -eq 0 ]
  grep -q 'EXTERNAL_PR_MUTATION action=audit_evidence mode=allowed' \
    "$ORCH_LOG_DIR/$PROJECT.log"
}

@test "explicit pr_comment authorization passes the gate" {
  run bash -lc "$(orch_env_exports)
    export ORCH_EXTERNAL_PR_MUTATIONS=pr_comment
    source '$AUDIT_LOG'
    source '$GATE'
    external_pr_mutation_assert pr_comment ci-test
  "
  [ "$status" -eq 0 ]
  grep -q 'EXTERNAL_PR_MUTATION action=pr_comment mode=allowed context=ci-test' \
    "$ORCH_LOG_DIR/$PROJECT.log"
}

@test "comma list authorizes only the listed scopes (pr_merge ok, pr_comment refused)" {
  run bash -lc "$(orch_env_exports)
    export ORCH_EXTERNAL_PR_MUTATIONS='pr_merge, pr_review'
    source '$AUDIT_LOG'
    source '$GATE'
    external_pr_mutation_assert pr_merge merge_flow
    external_pr_mutation_assert pr_comment comment_flow
  "
  [ "$status" -eq 80 ]
  grep -q 'EXTERNAL_PR_MUTATION action=pr_merge mode=allowed' \
    "$ORCH_LOG_DIR/$PROJECT.log"
  grep -q 'EXTERNAL_PR_MUTATION action=pr_comment mode=refused' \
    "$ORCH_LOG_DIR/$PROJECT.log"
}

@test "the 'all' wildcard authorizes every recognised scope" {
  run bash -lc "$(orch_env_exports)
    export ORCH_EXTERNAL_PR_MUTATIONS=all
    source '$AUDIT_LOG'
    source '$GATE'
    for s in pr_merge pr_comment pr_edit pr_labels pr_assignees pr_review pr_ready issue_close; do
      external_pr_mutation_assert \"\$s\" wildcard || exit 99
    done
  "
  [ "$status" -eq 0 ]
}

@test "unknown scope is rejected with exit 2" {
  run bash -lc "$(orch_env_exports)
    export ORCH_EXTERNAL_PR_MUTATIONS=all
    source '$AUDIT_LOG'
    source '$GATE'
    external_pr_mutation_assert delete_repo nuclear
  "
  [ "$status" -eq 2 ]
  [[ "$output" == *"external_pr_mutation_unknown_scope: scope=delete_repo"* ]]
  grep -q 'EXTERNAL_PR_MUTATION action=delete_repo mode=unknown' \
    "$ORCH_LOG_DIR/$PROJECT.log"
}

# --- classifier coverage (the merge/comment/edit/label/assignee paths) ----

@test "classifier maps gh pr merge to pr_merge" {
  run bash -lc "$(orch_env_exports)
    source '$AUDIT_LOG'
    source '$GATE'
    external_pr_mutation_classify_gh pr merge
  "
  [ "$status" -eq 0 ]
  [ "$output" = "pr_merge" ]
}

@test "classifier maps gh pr comment to pr_comment" {
  run bash -lc "$(orch_env_exports)
    source '$AUDIT_LOG'
    source '$GATE'
    external_pr_mutation_classify_gh pr comment
  "
  [ "$status" -eq 0 ]
  [ "$output" = "pr_comment" ]
}

@test "classifier maps plain gh pr edit to pr_edit and gh pr edit --add-label to pr_labels" {
  run bash -lc "$(orch_env_exports)
    source '$AUDIT_LOG'
    source '$GATE'
    base=\$(external_pr_mutation_classify_gh_args pr edit 123 --repo o/r --title new)
    label=\$(external_pr_mutation_classify_gh_args pr edit 123 --repo o/r --add-label parallel-safe)
    assignee=\$(external_pr_mutation_classify_gh_args pr edit 123 --repo o/r --add-assignee me)
    printf '%s|%s|%s\n' \"\$base\" \"\$label\" \"\$assignee\"
  "
  [ "$status" -eq 0 ]
  [ "$output" = "pr_edit|pr_labels|pr_assignees" ]
}

@test "classifier maps gh issue edit --add-assignee to issue_assignees" {
  run bash -lc "$(orch_env_exports)
    source '$AUDIT_LOG'
    source '$GATE'
    external_pr_mutation_classify_gh_args issue edit 42 --repo o/r --add-assignee robot
  "
  [ "$status" -eq 0 ]
  [ "$output" = "issue_assignees" ]
}

@test "classifier returns nonzero on read-only gh subcommands" {
  run bash -lc "$(orch_env_exports)
    source '$AUDIT_LOG'
    source '$GATE'
    external_pr_mutation_classify_gh pr view
  "
  [ "$status" -ne 0 ]
}

# --- repo-neutrality / scope registry -------------------------------------

@test "scope registry contains no provider or repo identifier" {
  run bash -lc "$(orch_env_exports)
    source '$AUDIT_LOG'
    source '$GATE'
    external_pr_mutation_known_scopes
  "
  [ "$status" -eq 0 ]
  while IFS= read -r scope; do
    [[ "$scope" =~ ^[a-z_]+$ ]] || {
      echo "scope contains forbidden characters: $scope" >&2
      false
    }
    [[ "$scope" =~ rbok|github|gitlab|bitbucket|azure ]] && {
      echo "scope leaks provider/repo identifier: $scope" >&2
      false
    } || true
  done <<< "$output"
}

# --- audit-only local fallback --------------------------------------------

@test "record_local_gate_evidence writes under state_dir/gate-evidence and audits audit_evidence" {
  local evidence_path
  run bash -lc "$(orch_env_exports)
    source '$AUDIT_LOG'
    source '$GATE'
    record_local_gate_evidence pr-3175-readiness 'observed local evidence'
  "
  [ "$status" -eq 0 ]
  # audit() writes to stderr and `run` mixes stderr + stdout in $output, so
  # the path printed by record_local_gate_evidence is the last line.
  evidence_path="${lines[-1]}"
  [[ "$evidence_path" == "$ORCH_STATE_BASE/$PROJECT/gate-evidence/pr-3175-readiness.md" ]]
  [ -s "$evidence_path" ]
  grep -q 'observed local evidence' "$evidence_path"
  grep -q 'EXTERNAL_PR_MUTATION action=audit_evidence mode=allowed' \
    "$ORCH_LOG_DIR/$PROJECT.log"
}

@test "record_local_gate_evidence sanitizes unsafe slugs to filename-safe paths" {
  run bash -lc "$(orch_env_exports)
    source '$AUDIT_LOG'
    source '$GATE'
    record_local_gate_evidence '../traversal attempt' 'should be neutralized'
  "
  [ "$status" -eq 0 ]
  local evidence_path="${lines[-1]}"
  # Slugs are restricted to [A-Za-z0-9._-]; spaces and slashes become '_'.
  # Dots remain (filename `..foo.md` is a regular file under gate-evidence/,
  # not a directory traversal because the parent path is fixed).
  [[ "$evidence_path" == "$ORCH_STATE_BASE/$PROJECT/gate-evidence/.._traversal_attempt.md" ]]
  # Resolved path must stay inside the gate-evidence directory regardless of slug.
  local resolved
  resolved=$(readlink -f "$evidence_path")
  [[ "$resolved" == "$ORCH_STATE_BASE/$PROJECT/gate-evidence/"* ]]
  [ -s "$evidence_path" ]
}

# --- run-wrapper -----------------------------------------------------------

@test "external_pr_mutation_run refuses unauthorized mutation without invoking gh" {
  write_mock_bin gh <<'EOF'
#!/usr/bin/env bash
echo "gh-was-called args=$*" >&2
exit 0
EOF

  run bash -lc "$(orch_env_exports)
    unset ORCH_EXTERNAL_PR_MUTATIONS
    source '$AUDIT_LOG'
    source '$GATE'
    external_pr_mutation_run dispatch_test -- pr merge 123 --repo o/r --squash
  "
  [ "$status" -eq 80 ]
  [[ "$output" != *"gh-was-called"* ]]
}

@test "external_pr_mutation_run passes through read-only gh invocations" {
  write_mock_bin gh <<'EOF'
#!/usr/bin/env bash
printf 'gh-view-output args=%s\n' "$*"
EOF

  run bash -lc "$(orch_env_exports)
    unset ORCH_EXTERNAL_PR_MUTATIONS
    source '$AUDIT_LOG'
    source '$GATE'
    external_pr_mutation_run audit_test -- pr view 123 --repo o/r --json state
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"gh-view-output args=pr view 123 --repo o/r --json state"* ]]
}
