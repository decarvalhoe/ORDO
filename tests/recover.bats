#!/usr/bin/env bats

setup() {
  export TK="$BATS_TEST_DIRNAME/.."
  export PROJECT="recover-bats-${BATS_TEST_NUMBER}"
  export ORCH_LOG_DIR="$BATS_TEST_TMPDIR/log"
  export ORCH_STATE_BASE="$BATS_TEST_TMPDIR/state"
  export AGENT_SESSION_PREFIX="recover-bats-${BATS_TEST_NUMBER}-"
  export AGENT_WINDOW_INDEX=0
  export AGENT_WORKDIR_TEMPLATE="$BATS_TEST_TMPDIR/work/%s"

  mkdir -p "$ORCH_LOG_DIR" "$ORCH_STATE_BASE/$PROJECT" "$BATS_TEST_TMPDIR/work/foo"
  cat > "$ORCH_STATE_BASE/$PROJECT/assignments.json" <<'JSON'
{"foo":{"issue":4},"bar":{"issue":5}}
JSON

  tmux new-session -d -s "${AGENT_SESSION_PREFIX}foo" \
    -c "$BATS_TEST_TMPDIR/work/foo" "sleep 60"
}

teardown() {
  tmux kill-session -t "${AGENT_SESSION_PREFIX}foo" 2>/dev/null || true
}

@test "recover --reset-state clears the agent assignment" {
  run bash "$TK/scripts/recover.sh" foo --reset-state

  [ "$status" -eq 0 ]
  jq -e '(has("foo") | not) and (.bar.issue == 5)' \
    "$ORCH_STATE_BASE/$PROJECT/assignments.json"
}
