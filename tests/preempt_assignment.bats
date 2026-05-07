#!/usr/bin/env bats

load './helpers.bash'

setup() {
  setup_orch_test
  export PROJECT="preempt-bats-${BATS_TEST_NUMBER}"
  export AGENT_SESSION_PREFIX="preempt-bats-${BATS_TEST_NUMBER}-"
  export AGENT_WINDOW_INDEX=0
  export AGENT_WORKDIR_TEMPLATE="$BATS_TEST_TMPDIR/work/%s"
  export USE_WORKTREES=0
  export ORCH_TMUX_TIMEOUT_SEC=3
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  export PREEMPT_SCRIPT

  mkdir -p "$ORCH_LOG_DIR" "$ORCH_STATE_BASE/$PROJECT" \
    "$BATS_TEST_TMPDIR/work/foo" "$BATS_TEST_TMPDIR/bin"

  cat > "$ORCH_STATE_BASE/$PROJECT/assignments.json" <<JSON
{"foo":{"issue":49,"ticket":"49","branch":"feat/issue-49","workdir":"$BATS_TEST_TMPDIR/work/foo"}}
JSON

  toolkit_file lib/agent_inventory.sh >/dev/null
  toolkit_file lib/audit_log.sh >/dev/null
  toolkit_file lib/config_check.sh >/dev/null
  toolkit_file lib/config_resolver.sh >/dev/null
  toolkit_file lib/dry_run.sh >/dev/null
  toolkit_file lib/log_bounds.sh >/dev/null
  toolkit_file lib/process_safety.sh >/dev/null
  toolkit_file lib/state_persist.sh >/dev/null
  toolkit_file lib/tmux_helpers.sh >/dev/null
  toolkit_file lib/worktree_helpers.sh >/dev/null
  PREEMPT_SCRIPT=$(toolkit_file scripts/preempt_assignment.sh)
}

teardown() {
  tmux kill-session -t "${AGENT_SESSION_PREFIX}foo" 2>/dev/null || true
}

start_busy_pane() {
  tmux new-session -d -s "${AGENT_SESSION_PREFIX}foo" \
    -c "$BATS_TEST_TMPDIR/work/foo" "sleep 60"
}

start_idle_pane() {
  cat > "$BATS_TEST_TMPDIR/bin/fake-shell" <<'EOF'
#!/usr/bin/env bash
printf '> '
exec sleep 60
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/fake-shell"
  tmux new-session -d -s "${AGENT_SESSION_PREFIX}foo" \
    -c "$BATS_TEST_TMPDIR/work/foo" "$BATS_TEST_TMPDIR/bin/fake-shell"
}

init_clean_repo() {
  git -C "$BATS_TEST_TMPDIR/work/foo" init -q
  git -C "$BATS_TEST_TMPDIR/work/foo" config user.email "preempt@test.local"
  git -C "$BATS_TEST_TMPDIR/work/foo" config user.name "Preempt Test"
  git -C "$BATS_TEST_TMPDIR/work/foo" checkout -q -b feat/issue-49
  printf 'seed\n' > "$BATS_TEST_TMPDIR/work/foo/README.md"
  git -C "$BATS_TEST_TMPDIR/work/foo" add README.md
  git -C "$BATS_TEST_TMPDIR/work/foo" commit -q -m "seed"
}

@test "preempt preserves assignment on idle pane and writes snapshot + audit" {
  start_idle_pane
  init_clean_repo

  run bash "$PREEMPT_SCRIPT" foo --reason "lower priority work pending"

  [ "$status" -eq 0 ]
  ls "$ORCH_STATE_BASE/$PROJECT/preempt"/foo-49-*.log >/dev/null
  jq -e '.foo.issue == 49 and (.foo.parked // false | not)' \
    "$ORCH_STATE_BASE/$PROJECT/assignments.json"
  grep -q 'PREEMPT' "$ORCH_LOG_DIR/$PROJECT.log"
  grep -q 'next_action=preserved' "$ORCH_LOG_DIR/$PROJECT.log"
  grep -q 'old_ticket=49' "$ORCH_LOG_DIR/$PROJECT.log"
}

@test "preempt tolerates a busy pane and still records the snapshot" {
  start_busy_pane
  init_clean_repo

  run bash "$PREEMPT_SCRIPT" foo --reason "switching to higher priority #105"

  [ "$status" -eq 0 ]
  ls "$ORCH_STATE_BASE/$PROJECT/preempt"/foo-49-*.log >/dev/null
  grep -q 'next_action=preserved' "$ORCH_LOG_DIR/$PROJECT.log"
}

@test "preempt exits 3 and audits missing_pane when the session is gone" {
  init_clean_repo

  run bash "$PREEMPT_SCRIPT" foo --reason "session vanished"

  [ "$status" -eq 3 ]
  grep -q 'next_action=missing_pane' "$ORCH_LOG_DIR/$PROJECT.log"
  jq -e '.foo.issue == 49' \
    "$ORCH_STATE_BASE/$PROJECT/assignments.json"
}

@test "preempt --release refuses to clear a dirty worktree without --force-dirty" {
  start_idle_pane
  init_clean_repo
  printf 'wip\n' > "$BATS_TEST_TMPDIR/work/foo/wip.txt"

  run bash "$PREEMPT_SCRIPT" foo --reason "wip not committed" --release

  [ "$status" -eq 4 ]
  grep -q 'next_action=dirty_refused' "$ORCH_LOG_DIR/$PROJECT.log"
  jq -e '.foo.issue == 49' \
    "$ORCH_STATE_BASE/$PROJECT/assignments.json"
}

@test "preempt --release on a clean worktree removes the assignment" {
  start_idle_pane
  init_clean_repo

  run bash "$PREEMPT_SCRIPT" foo --reason "drop in favor of #105" --release

  [ "$status" -eq 0 ]
  grep -q 'next_action=released' "$ORCH_LOG_DIR/$PROJECT.log"
  jq -e '(has("foo") | not)' \
    "$ORCH_STATE_BASE/$PROJECT/assignments.json"
}

@test "preempt --park on a stale assignment marks it parked with reason" {
  start_idle_pane
  init_clean_repo

  run bash "$PREEMPT_SCRIPT" foo --reason "park while waiting on review" --park

  [ "$status" -eq 0 ]
  grep -q 'next_action=parked' "$ORCH_LOG_DIR/$PROJECT.log"
  jq -e '.foo.parked == true and .foo.parked_reason == "park while waiting on review" and .foo.issue == 49' \
    "$ORCH_STATE_BASE/$PROJECT/assignments.json"
}
