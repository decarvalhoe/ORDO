#!/usr/bin/env bats

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  exec bats "$0" "$@"
fi

# Coverage for #295: agent_pool_status.sh must split the configured
# `assigned_workdir` from the live tmux pane cwd. When the two diverge the
# script must emit a `live_cwd_mismatch` signal and expose both fields.

load './helpers.bash'

setup() {
  setup_orch_test
  TK_REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export TK_REPO_ROOT

  TEST_REPOS_ROOT="$BATS_TEST_TMPDIR/repos"
  TEST_BIN="$BATS_TEST_TMPDIR/bin"
  TEST_GH="$BATS_TEST_TMPDIR/gh"
  mkdir -p "$TEST_REPOS_ROOT" "$TEST_BIN" "$TEST_GH"

  # Make a minimal git workdir for the agent.
  AGENT_REPO="$TEST_REPOS_ROOT/agent-one"
  git init -q "$AGENT_REPO"
  git -C "$AGENT_REPO" config user.email t@example.invalid
  git -C "$AGENT_REPO" config user.name "Test Agent"
  printf 'ok\n' > "$AGENT_REPO/file.txt"
  git -C "$AGENT_REPO" add file.txt
  git -C "$AGENT_REPO" commit -q -m 'init'
  git -C "$AGENT_REPO" branch -M main

  CONFIG="$BATS_TEST_TMPDIR/config.sh"
  cat > "$CONFIG" <<EOF
PROJECT="pool-cwd-test"
DEFAULT_BRANCH="main"
GH_REPO="example/repo"
GH_CONFIG_DIR="$TEST_GH"
AGENT_PANES=(
  "agent-one|agent-one:0.0|$AGENT_REPO"
)
EOF

  # Stub gh so the live PR list is empty.
  cat > "$TEST_BIN/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '[]'
EOF
  chmod +x "$TEST_BIN/gh"

  export AGENT_REPO CONFIG TEST_BIN
}

# Build a fake tmux that returns LIVE_CWD for #{pane_current_path} and
# 'node' for #{pane_current_command}, so the test can drive cwd outcomes.
write_fake_tmux_with_live_cwd() {
  local live_cwd=$1
  cat > "$TEST_BIN/tmux" <<EOF
#!/usr/bin/env bash
case "\$1" in
  has-session) exit 0 ;;
  list-panes) exit 0 ;;
  display-message)
    fmt=""
    batched=0
    for arg in "\$@"; do
      case "\$arg" in
        *'#{pane_current_command}'*'#{pane_current_path}'*) batched=1 ;;
        '#{pane_current_path}'|'#{pane_current_command}') fmt=\$arg ;;
      esac
    done
    if [ "\$batched" = "1" ]; then
      printf 'node\037%s\n' "$live_cwd"
    elif [ "\$fmt" = '#{pane_current_path}' ]; then
      printf '%s\n' "$live_cwd"
    elif [ "\$fmt" = '#{pane_current_command}' ]; then
      printf 'node\n'
    fi
    exit 0
    ;;
esac
exit 0
EOF
  chmod +x "$TEST_BIN/tmux"
}

# Stub tmux that always fails has-session, so alive=0 and live_pane_cwd stays empty.
write_fake_tmux_no_session() {
  cat > "$TEST_BIN/tmux" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  has-session) exit 1 ;;
  list-panes) exit 0 ;;
esac
exit 0
EOF
  chmod +x "$TEST_BIN/tmux"
}

run_pool_status() {
  local format=${1:?usage: run_pool_status <--tsv|--json>}
  PATH="$TEST_BIN:$PATH" \
    BASH_ENV='' \
    ORCH_STATE_BASE="$BATS_TEST_TMPDIR/state-${format#--}" \
    bash "$TK_REPO_ROOT/scripts/agent_pool_status.sh" "$CONFIG" "$format"
}

@test "TSV header advertises assigned_workdir, live_pane_cwd, live_cwd_match" {
  write_fake_tmux_with_live_cwd "$AGENT_REPO"

  run run_pool_status --tsv
  [ "$status" -eq 0 ]
  first_line=$(printf '%s\n' "$output" | head -n 1)
  [[ "$first_line" == *$'\tassigned_workdir\tlive_pane_cwd\tlive_cwd_match\t'* ]]
}

@test "JSON match: live cwd equals assigned workdir, no mismatch signal" {
  write_fake_tmux_with_live_cwd "$AGENT_REPO"

  run run_pool_status --json
  [ "$status" -eq 0 ]
  printf '%s' "$output" \
    | jq -e --arg w "$AGENT_REPO" \
        '.[0].assigned_workdir == $w
         and .[0].live_pane_cwd == $w
         and .[0].live_cwd_match == "1"
         and ((.[0].signals | index("live_cwd_mismatch")) | not)' >/dev/null
}

@test "JSON mismatch: live cwd diverges, live_cwd_mismatch signal emitted" {
  write_fake_tmux_with_live_cwd "$BATS_TEST_TMPDIR/repos/different-product/agent-one"

  run run_pool_status --json
  [ "$status" -eq 0 ]
  printf '%s' "$output" \
    | jq -e --arg w "$AGENT_REPO" \
        --arg live "$BATS_TEST_TMPDIR/repos/different-product/agent-one" \
        '.[0].assigned_workdir == $w
         and .[0].live_pane_cwd == $live
         and .[0].live_cwd_match == "0"
         and (.[0].signals | index("live_cwd_mismatch"))' >/dev/null
}

@test "TSV mismatch: live_cwd_mismatch appears in the signals column" {
  write_fake_tmux_with_live_cwd "$BATS_TEST_TMPDIR/repos/different-product/agent-one"

  run run_pool_status --tsv
  [ "$status" -eq 0 ]
  agent_row=$(printf '%s\n' "$output" | grep '^agent-one\b')
  [[ "$agent_row" == *"live_cwd_mismatch"* ]]
  # The mismatch column itself is set to 0.
  [[ "$agent_row" == *$'\t'"$AGENT_REPO"$'\t'"$BATS_TEST_TMPDIR/repos/different-product/agent-one"$'\t0\t'* ]]
}

@test "trailing slash on live cwd does not create a spurious mismatch" {
  write_fake_tmux_with_live_cwd "$AGENT_REPO/"

  run run_pool_status --json
  [ "$status" -eq 0 ]
  printf '%s' "$output" \
    | jq -e --arg w "$AGENT_REPO" \
        '.[0].assigned_workdir == $w
         and .[0].live_cwd_match == "1"
         and ((.[0].signals | index("live_cwd_mismatch")) | not)' >/dev/null
}

@test "no tmux session: live_pane_cwd is empty, live_cwd_match is empty, no mismatch claim" {
  write_fake_tmux_no_session

  run run_pool_status --json
  [ "$status" -eq 0 ]
  printf '%s' "$output" \
    | jq -e --arg w "$AGENT_REPO" \
        '.[0].assigned_workdir == $w
         and .[0].alive == 0
         and .[0].live_pane_cwd == ""
         and .[0].live_cwd_match == ""
         and ((.[0].signals | index("live_cwd_mismatch")) | not)' >/dev/null
}

@test "JSON drops the legacy .workdir field in favor of .assigned_workdir" {
  write_fake_tmux_with_live_cwd "$AGENT_REPO"

  run run_pool_status --json
  [ "$status" -eq 0 ]
  # The pre-#295 .workdir key must not be on the object — callers that need
  # it must migrate to .assigned_workdir, which is the renamed column.
  printf '%s' "$output" \
    | jq -e '.[0] | (has("workdir") | not) and has("assigned_workdir") and has("live_pane_cwd") and has("live_cwd_match")' >/dev/null
}
