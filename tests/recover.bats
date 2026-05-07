#!/usr/bin/env bats

load './helpers.bash'

setup() {
  setup_orch_test
  export PROJECT="recover-bats-${BATS_TEST_NUMBER}"
  export AGENT_SESSION_PREFIX="recover-bats-${BATS_TEST_NUMBER}-"
  export AGENT_WINDOW_INDEX=0
  export AGENT_WORKDIR_TEMPLATE="$BATS_TEST_TMPDIR/work/%s"
  export ORCH_AGENT_CLI=claude
  export ORCH_WORKTREES_DIR="$BATS_TEST_TMPDIR/worktrees"
  export USE_WORKTREES=1
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  export RECOVER_SCRIPT

  mkdir -p "$ORCH_LOG_DIR" "$ORCH_STATE_BASE/$PROJECT" "$BATS_TEST_TMPDIR/work/foo" "$BATS_TEST_TMPDIR/bin"
  cat > "$ORCH_STATE_BASE/$PROJECT/assignments.json" <<'JSON'
{"foo":{"issue":4},"bar":{"issue":5}}
JSON

  cat > "$BATS_TEST_TMPDIR/bin/claude" <<'EOF'
#!/usr/bin/env bash
exec sleep 60
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/claude"
  toolkit_file lib/config_check.sh >/dev/null
  toolkit_file lib/audit_log.sh >/dev/null
  toolkit_file lib/dry_run.sh >/dev/null
  toolkit_file lib/tmux_helpers.sh >/dev/null
  toolkit_file lib/state_persist.sh >/dev/null
  toolkit_file lib/worktree_helpers.sh >/dev/null
  RECOVER_SCRIPT=$(toolkit_file scripts/recover.sh)

  tmux new-session -d -s "${AGENT_SESSION_PREFIX}foo" \
    -c "$BATS_TEST_TMPDIR/work/foo" "sleep 60"
}

teardown() {
  tmux kill-session -t "${AGENT_SESSION_PREFIX}foo" 2>/dev/null || true
}

@test "recover --reset-state clears the agent assignment" {
  run bash "$RECOVER_SCRIPT" foo --reset-state

  [ "$status" -eq 0 ]
  jq -e '(has("foo") | not) and (.bar.issue == 5)' \
    "$ORCH_STATE_BASE/$PROJECT/assignments.json"
}

@test "recover recreates a missing session in the assigned worktree when enabled" {
  local assigned_worktree="$ORCH_WORKTREES_DIR/foo/feat-issue-4"
  mkdir -p "$assigned_worktree"
  cat > "$ORCH_STATE_BASE/$PROJECT/assignments.json" <<JSON
{"foo":{"workdir":"$assigned_worktree"}}
JSON

  tmux kill-session -t "${AGENT_SESSION_PREFIX}foo" 2>/dev/null || true

  run bash "$RECOVER_SCRIPT" foo

  [ "$status" -eq 0 ]

  run tmux display-message -p -t "${AGENT_SESSION_PREFIX}foo:${AGENT_WINDOW_INDEX}" '#{pane_current_path}'

  [ "$status" -eq 0 ]
  [ "$output" = "$assigned_worktree" ]
}
