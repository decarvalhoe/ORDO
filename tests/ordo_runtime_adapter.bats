#!/usr/bin/env bats
# tests/ordo_runtime_adapter.bats — runtime adapter boundary (#811).
#
# Covers lib/ordo_runtime_adapter.sh with its three backends:
#   - fake: JSON state under $ORDO_FAKE_ADAPTER_DIR/runtime, full lifecycle;
#   - tmux: wraps lib/tmux_helpers.sh against a mocked `tmux` binary that logs
#     every invocation, so the test proves which helper calls are made;
#   - ssh: ships the same tmux commands through `ssh <host> "tr -d '\r' | bash -s"`;
#     the mocked `ssh` executes the snippet locally against the mocked tmux,
#     which proves the remote snippets are valid bash and CRLF-safe.
# Every op returns one JSON envelope {"op","adapter","ts",...}; every failure is
# an error object with module runtime_adapter and details.retryable.

bats_require_minimum_version 1.5.0

load './helpers.bash'

setup() {
  setup_orch_test
  export ORDO_FAKE_ADAPTER_DIR="$BATS_TEST_TMPDIR/fake"
  export TMUX_MOCK_LOG="$BATS_TEST_TMPDIR/tmux.log"
  export TMUX_MOCK_DIR="$BATS_TEST_TMPDIR/tmux-mock"
  export SSH_MOCK_LOG="$BATS_TEST_TMPDIR/ssh.log"
  export SSH_MOCK_DIR="$BATS_TEST_TMPDIR/ssh-mock"
  mkdir -p "$TMUX_MOCK_DIR" "$SSH_MOCK_DIR"
  printf '0|claude|/work/agent\n' > "$TMUX_MOCK_DIR/meta.txt"
  printf 'Read /tmp/dispatch-fleet-001-42.md\n⏺ Working on it… running tests\n' > "$TMUX_MOCK_DIR/capture.txt"
  # fast paths through terminal_dispatch_submit
  export ORCH_DISPATCH_SUBMIT_ATTEMPTS=1 ORCH_DISPATCH_CONSUME_WAIT_SEC=0 ORCH_TMUX_SEND_ENTER_DELAY_SEC=0
  export ORCH_DISPATCH_ACCEPTANCE_TIMEOUT_SEC=1 ORCH_DISPATCH_ACCEPTANCE_POLL_SEC=1
  unset ORDO_RUNTIME_ADAPTER ORDO_SSH_HOST
  write_mock_bin tmux <<'EOF'
#!/usr/bin/env bash
# mock tmux: logs args; behaviour driven by files in $TMUX_MOCK_DIR
printf '%s\n' "$*" >> "$TMUX_MOCK_LOG"
cmd=$1
case "$cmd" in
  display-message)
    [[ -f "$TMUX_MOCK_DIR/missing" ]] && exit 1
    if [[ -f "$TMUX_MOCK_DIR/dead" ]]; then printf '1|bash|/work/agent\n'; else cat "$TMUX_MOCK_DIR/meta.txt"; fi ;;
  capture-pane)
    [[ -f "$TMUX_MOCK_DIR/missing" ]] && exit 1
    cat "$TMUX_MOCK_DIR/capture.txt" ;;
  has-session)
    [[ -f "$TMUX_MOCK_DIR/missing" ]] && exit 1
    exit 0 ;;
  new-session|respawn-pane) rm -f "$TMUX_MOCK_DIR/missing" "$TMUX_MOCK_DIR/dead"; exit 0 ;;
  load-buffer|paste-buffer|delete-buffer|send-keys|kill-pane) exit 0 ;;
  *) exit 0 ;;
esac
EOF
  write_mock_bin ssh <<'EOF'
#!/usr/bin/env bash
# mock ssh: records host + remote command + the snippet, then EXECUTES the
# remote command locally (the mocked tmux is on PATH), like a real remote.
args=("$@")
host=""; remote=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o|-i|-p|-l) shift 2 ;;
    -*) shift ;;
    *) if [[ -z "$host" ]]; then host=$1; else remote=$1; fi; shift ;;
  esac
done
printf 'host=%s remote=%s args=%s\n' "$host" "$remote" "${args[*]}" >> "$SSH_MOCK_LOG"
[[ -f "$SSH_MOCK_DIR/fail_255" ]] && exit 255
tee "$SSH_MOCK_DIR/snippet.sh" | bash -c "$remote"
EOF
  set +e
  # shellcheck disable=SC1090
  source "$TK/lib/ordo_runtime_adapter.sh"
}

assert_error() {
  local code="$1" retryable="${2:-false}"
  [ "$(printf '%s\n' "$stderr" | grep -c .)" -eq 1 ]
  [ "$(printf '%s' "$stderr" | jq -r '.error.code')" = "$code" ]
  [ "$(printf '%s' "$stderr" | jq -r '.error.module')" = "runtime_adapter" ]
  [ "$(printf '%s' "$stderr" | jq -r '.error.details.retryable')" = "$retryable" ]
  [ -z "$output" ]
}

assert_envelope() {
  local op="$1" adapter="$2"
  [ "$(printf '%s' "$output" | jq -r '.op')" = "$op" ]
  [ "$(printf '%s' "$output" | jq -r '.adapter')" = "$adapter" ]
  printf '%s' "$output" | jq -e '.ts | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")' >/dev/null
  [ "$(printf '%s\n' "$output" | grep -c .)" -eq 1 ]
}

# --- registry -----------------------------------------------------------------

@test "ops and adapters are registered; tmux is the default; unknown op/adapter => exit 2 (#811)" {
  run ordo_runtime_adapter_ops
  [ "$(printf '%s' "$output" | tr '\n' ' ' | sed 's/ $//')" = "start inspect signal stop collect_evidence recover" ]
  run ordo_runtime_adapter_names
  [ "$(printf '%s' "$output" | tr '\n' ' ' | sed 's/ $//')" = "tmux ssh fake" ]
  [ "$(ordo_runtime_adapter_name)" = "tmux" ]
  run --separate-stderr ordo_runtime bogus x
  [ "$status" -eq 2 ]
  assert_error unknown_command
  ORDO_RUNTIME_ADAPTER=docker run --separate-stderr ordo_runtime inspect x
  [ "$status" -eq 2 ]
  assert_error bad_argument
  run --separate-stderr ordo_runtime inspect
  [ "$status" -eq 2 ]
  assert_error usage
  ORDO_RUNTIME_ADAPTER=fake run --separate-stderr ordo_runtime inspect x --lines abc
  [ "$status" -eq 2 ]
  assert_error bad_argument
  ORDO_RUNTIME_ADAPTER=fake run --separate-stderr ordo_runtime start x
  [ "$status" -eq 2 ]
  assert_error usage
}

# --- fake ---------------------------------------------------------------------

@test "fake: full lifecycle recover -> start -> inspect -> signal -> collect_evidence -> stop (#811)" {
  export ORDO_RUNTIME_ADAPTER=fake
  run --separate-stderr ordo_runtime inspect fleet-001:0.0
  [ "$status" -eq 4 ]
  assert_error not_found
  run ordo_runtime recover fleet-001:0.0 --workdir /work/agent
  [ "$status" -eq 0 ]
  assert_envelope recover fake
  [ "$(printf '%s' "$output" | jq -r '.action')" = "session_created" ]
  [ "$(printf '%s' "$output" | jq -r '.session')" = "fleet-001" ]
  [ -f "$ORDO_FAKE_ADAPTER_DIR/runtime/fleet-001_0.0.json" ]
  run ordo_runtime start fleet-001:0.0 --text $'Read /tmp/dispatch-fleet-001-42.md\nsecond line'
  [ "$status" -eq 0 ]
  assert_envelope start fake
  [ "$(printf '%s' "$output" | jq -r '.submitted')" = "true" ]
  [ "$(printf '%s' "$output" | jq -r '.bytes')" = "46" ]
  run ordo_runtime inspect fleet-001:0.0 --lines 5
  [ "$status" -eq 0 ]
  assert_envelope inspect fake
  [ "$(printf '%s' "$output" | jq -r '.alive')" = "true" ]
  [ "$(printf '%s' "$output" | jq -r '.idle')" = "false" ]
  [ "$(printf '%s' "$output" | jq -r '.cwd')" = "/work/agent" ]
  [[ "$(printf '%s' "$output" | jq -r '.capture')" == *"dispatch-fleet-001-42.md"* ]]
  run ordo_runtime signal fleet-001:0.0 interrupt
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.delivered')" = "true" ]
  run ordo_runtime inspect fleet-001:0.0
  [ "$(printf '%s' "$output" | jq -r '.idle')" = "true" ]
  run ordo_runtime collect_evidence fleet-001:0.0 --label acceptance --out "$BATS_TEST_TMPDIR/copy.txt"
  [ "$status" -eq 0 ]
  assert_envelope collect_evidence fake
  local path
  path=$(printf '%s' "$output" | jq -r '.path')
  [ -f "$path" ]
  [[ "$path" == "$ORCH_STATE_BASE/$PROJECT/runtime-evidence/fleet-001_0.0-"*"-acceptance-"*".txt" ]]
  [ "$(printf '%s' "$output" | jq -r '.redacted')" = "true" ]
  [ "$(printf '%s' "$output" | jq -r '.sha256')" = "$(sha256sum "$path" | awk '{print $1}')" ]
  cmp -s "$path" "$BATS_TEST_TMPDIR/copy.txt"
  run ordo_runtime stop fleet-001:0.0 --kill
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.action')" = "kill" ]
  run ordo_runtime inspect fleet-001:0.0
  [ "$(printf '%s' "$output" | jq -r '.alive')" = "false" ]
  run ordo_runtime recover fleet-001:0.0
  [ "$(printf '%s' "$output" | jq -r '.action')" = "pane_respawned" ]
  run ordo_runtime recover fleet-001:0.0
  [ "$(printf '%s' "$output" | jq -r '.action')" = "none" ]
  [ "$(wc -l < "$ORDO_FAKE_ADAPTER_DIR/runtime/events.jsonl" | tr -d ' ')" -eq 7 ]
  unset ORDO_FAKE_ADAPTER_DIR
  run --separate-stderr ordo_runtime inspect fleet-001:0.0
  [ "$status" -eq 2 ]
  assert_error bad_argument
}

@test "collect_evidence masks token-looking values in the stored capture (#811)" {
  export ORDO_RUNTIME_ADAPTER=fake
  ordo_runtime recover fleet-002:0.0 >/dev/null
  ordo_runtime start fleet-002:0.0 --text 'export GH_TOKEN=ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 sk-ABCDEFGHIJKLMNOPQRSTUVWXYZ' >/dev/null
  run ordo_runtime collect_evidence fleet-002:0.0
  [ "$status" -eq 0 ]
  local path
  path=$(printf '%s' "$output" | jq -r '.path')
  run ! grep -q 'ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789' "$path"
  run ! grep -q 'sk-ABCDEFGHIJKLMNOPQRSTUVWXYZ' "$path"
  [ "$(grep -o '\[REDACTED\]' "$path" | wc -l)" -eq 2 ]
}

# --- tmux ---------------------------------------------------------------------

@test "tmux: start wraps terminal_dispatch_submit (load-buffer/paste-buffer/Enter) and reports consumption (#811)" {
  export ORDO_RUNTIME_ADAPTER=tmux
  run ordo_runtime start fleet-001:0.0 --text 'Read /tmp/dispatch-fleet-001-42.md' --workdir /work/agent
  [ "$status" -eq 0 ]
  assert_envelope start tmux
  [ "$(printf '%s' "$output" | jq -r '.submitted')" = "true" ]
  [ "$(printf '%s' "$output" | jq -r '.target')" = "fleet-001:0.0" ]
  grep -qE '^load-buffer -b orch_send_[0-9_]+ /' "$TMUX_MOCK_LOG"
  grep -qE '^paste-buffer -b orch_send_[0-9_]+ -t fleet-001:0.0 -d$' "$TMUX_MOCK_LOG"
  grep -q '^send-keys -t fleet-001:0.0 Enter$' "$TMUX_MOCK_LOG"
  # not consumed: the submitted text is still visible above an idle prompt
  printf 'Read /tmp/dispatch-fleet-001-42.md\n> \n' > "$TMUX_MOCK_DIR/capture.txt"
  run --separate-stderr ordo_runtime start fleet-001:0.0 --text 'Read /tmp/dispatch-fleet-001-42.md'
  [ "$status" -eq 1 ]
  assert_error runtime_error true
  [ "$(printf '%s' "$stderr" | jq -r '.error.details.reason')" = "submission-still-visible" ]
  # missing pane -> not_found, nothing sent
  : > "$TMUX_MOCK_LOG"
  touch "$TMUX_MOCK_DIR/missing"
  run --separate-stderr ordo_runtime start fleet-009:0.0 --text 'x'
  [ "$status" -eq 4 ]
  assert_error not_found
  run ! grep -q 'paste-buffer' "$TMUX_MOCK_LOG"
}

@test "tmux: start --text-file with --agent/--ticket adds the pane acceptance proof (#811)" {
  export ORDO_RUNTIME_ADAPTER=tmux
  printf 'Read /tmp/dispatch-fleet-001-42.md\n' > "$BATS_TEST_TMPDIR/brief.md"
  run ordo_runtime start fleet-001:0.0 --text-file "$BATS_TEST_TMPDIR/brief.md" --agent fleet-001 --ticket 42
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.acceptance.accepted')" = "true" ]
  [ "$(printf '%s' "$output" | jq -r '.acceptance.reason')" = "brief-filename" ]
  run --separate-stderr ordo_runtime start fleet-001:0.0 --text-file "$BATS_TEST_TMPDIR/nope.md"
  [ "$status" -eq 4 ]
  assert_error not_found
}

@test "tmux: inspect reports alive/idle/cwd/command/capture from display-message + capture-pane (#811)" {
  export ORDO_RUNTIME_ADAPTER=tmux
  run ordo_runtime inspect fleet-001:0.0 --lines 7
  [ "$status" -eq 0 ]
  assert_envelope inspect tmux
  [ "$(printf '%s' "$output" | jq -r '.alive')" = "true" ]
  [ "$(printf '%s' "$output" | jq -r '.idle')" = "false" ]
  [ "$(printf '%s' "$output" | jq -r '.cwd')" = "/work/agent" ]
  [ "$(printf '%s' "$output" | jq -r '.command')" = "claude" ]
  [ "$(printf '%s' "$output" | jq -r '.lines')" = "7" ]
  [[ "$(printf '%s' "$output" | jq -r '.capture')" == *"Working on it"* ]]
  grep -q "^display-message -p -t fleet-001:0.0 #{pane_dead}|#{pane_current_command}|#{pane_current_path}$" "$TMUX_MOCK_LOG"
  grep -q '^capture-pane -t fleet-001:0.0 -p -S -7$' "$TMUX_MOCK_LOG"
  printf 'done\n❯ \n' > "$TMUX_MOCK_DIR/capture.txt"
  run ordo_runtime inspect fleet-001:0.0
  [ "$(printf '%s' "$output" | jq -r '.idle')" = "true" ]
  touch "$TMUX_MOCK_DIR/dead"
  run ordo_runtime inspect fleet-001:0.0
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.alive')" = "false" ]
  [ "$(printf '%s' "$output" | jq -r '.idle')" = "false" ]
  rm -f "$TMUX_MOCK_DIR/dead"
  touch "$TMUX_MOCK_DIR/missing"
  run --separate-stderr ordo_runtime inspect fleet-001:0.0
  [ "$status" -eq 4 ]
  assert_error not_found
}

@test "tmux: signal maps neutral names to keys, clear uses terminal_dispatch_clear_input, stop interrupts or kills (#811)" {
  export ORDO_RUNTIME_ADAPTER=tmux
  run ordo_runtime signal fleet-001:0.0 interrupt
  [ "$status" -eq 0 ]
  assert_envelope signal tmux
  grep -q '^send-keys -t fleet-001:0.0 C-c$' "$TMUX_MOCK_LOG"
  run ordo_runtime signal fleet-001:0.0 escape
  grep -q '^send-keys -t fleet-001:0.0 Escape$' "$TMUX_MOCK_LOG"
  run ordo_runtime signal fleet-001:0.0 enter
  grep -q '^send-keys -t fleet-001:0.0 Enter$' "$TMUX_MOCK_LOG"
  ORCH_DISPATCH_RETRY_CLEAR_DELAY_SEC=0 run ordo_runtime signal fleet-001:0.0 clear
  grep -q '^send-keys -t fleet-001:0.0 C-u$' "$TMUX_MOCK_LOG"
  run ordo_runtime signal fleet-001:0.0 Down
  grep -q '^send-keys -t fleet-001:0.0 Down$' "$TMUX_MOCK_LOG"
  : > "$TMUX_MOCK_LOG"
  run ordo_runtime stop fleet-001:0.0
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.action')" = "interrupt" ]
  grep -q '^send-keys -t fleet-001:0.0 C-c$' "$TMUX_MOCK_LOG"
  run ! grep -q 'kill-pane' "$TMUX_MOCK_LOG"
  run ordo_runtime stop fleet-001:0.0 --kill
  [ "$(printf '%s' "$output" | jq -r '.action')" = "kill" ]
  grep -q '^kill-pane -t fleet-001:0.0$' "$TMUX_MOCK_LOG"
}

@test "tmux: collect_evidence stores a redacted capture under state_dir/runtime-evidence (#811)" {
  export ORDO_RUNTIME_ADAPTER=tmux
  printf 'GH_TOKEN=ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789\nline 2\n' > "$TMUX_MOCK_DIR/capture.txt"
  run ordo_runtime collect_evidence fleet-001:0.0 --lines 500 --label stuck
  [ "$status" -eq 0 ]
  assert_envelope collect_evidence tmux
  grep -q '^capture-pane -t fleet-001:0.0 -p -S -500$' "$TMUX_MOCK_LOG"
  local path
  path=$(printf '%s' "$output" | jq -r '.path')
  [[ "$path" == "$ORCH_STATE_BASE/$PROJECT/runtime-evidence/"*"-stuck-"*".txt" ]]
  grep -q 'GH_TOKEN=\[REDACTED\]' "$path"
  [ "$(printf '%s' "$output" | jq -r '.lines')" = "2" ]
  [ "$(printf '%s' "$output" | jq -r '.requested_lines')" = "500" ]
  # explicit directory override
  ORDO_RUNTIME_EVIDENCE_DIR="$BATS_TEST_TMPDIR/ev" run ordo_runtime collect_evidence fleet-001:0.0
  [[ "$(printf '%s' "$output" | jq -r '.path')" == "$BATS_TEST_TMPDIR/ev/"* ]]
}

@test "tmux: recover creates a missing session, respawns a dead pane, and is a no-op otherwise (#811)" {
  export ORDO_RUNTIME_ADAPTER=tmux
  touch "$TMUX_MOCK_DIR/missing"
  run ordo_runtime recover fleet-001:0.0 --workdir /work/agent --command 'exec claude'
  [ "$status" -eq 0 ]
  assert_envelope recover tmux
  [ "$(printf '%s' "$output" | jq -r '.action')" = "session_created" ]
  grep -q '^has-session -t fleet-001$' "$TMUX_MOCK_LOG"
  grep -q '^new-session -d -s fleet-001 -c /work/agent exec claude$' "$TMUX_MOCK_LOG"
  touch "$TMUX_MOCK_DIR/dead"
  run ordo_runtime recover fleet-001:0.0 --workdir /work/agent
  [ "$(printf '%s' "$output" | jq -r '.action')" = "pane_respawned" ]
  grep -q '^respawn-pane -k -t fleet-001:0.0 -c /work/agent$' "$TMUX_MOCK_LOG"
  : > "$TMUX_MOCK_LOG"
  run ordo_runtime recover fleet-001:0.0
  [ "$(printf '%s' "$output" | jq -r '.action')" = "none" ]
  run ! grep -qE 'new-session|respawn-pane' "$TMUX_MOCK_LOG"
}

@test "tmux: a missing tmux binary is missing_dependency (exit 6) (#811)" {
  export ORDO_RUNTIME_ADAPTER=tmux
  rm -f "$TEST_BIN_DIR/tmux"
  local empty_bin="$BATS_TEST_TMPDIR/empty-bin"
  mkdir -p "$empty_bin"
  for tool in jq cat tr grep sed head tail awk mktemp rm date od paste wc sha256sum cp mkdir dirname sleep; do
    ln -sf "$(command -v "$tool")" "$empty_bin/$tool" 2>/dev/null || true
  done
  PATH="$empty_bin" run --separate-stderr ordo_runtime inspect fleet-001:0.0
  [ "$status" -eq 6 ]
  assert_error missing_dependency
}

# --- ssh ----------------------------------------------------------------------

@test "ssh: ops travel as CRLF-safe snippets through ssh <host> \"tr -d '\\r' | bash -s\" (#811)" {
  export ORDO_RUNTIME_ADAPTER=ssh ORDO_SSH_HOST=agent@win-host ORDO_SSH_OPTS="-o BatchMode=yes"
  run ordo_runtime inspect fleet-001:0.0 --lines 9
  [ "$status" -eq 0 ]
  assert_envelope inspect ssh
  [ "$(printf '%s' "$output" | jq -r '.host')" = "agent@win-host" ]
  [ "$(printf '%s' "$output" | jq -r '.alive')" = "true" ]
  [ "$(printf '%s' "$output" | jq -r '.cwd')" = "/work/agent" ]
  [ "$(printf '%s' "$output" | jq -r '.command')" = "claude" ]
  [[ "$(printf '%s' "$output" | jq -r '.capture')" == *"Working on it"* ]]
  [[ "$(printf '%s' "$output" | jq -r '.capture')" != *"ORDO_RT_META"* ]]
  grep -q "^host=agent@win-host remote=tr -d '\\\\r' | bash -s args=-o BatchMode=yes agent@win-host tr -d '\\\\r' | bash -s$" "$SSH_MOCK_LOG"
  grep -q '^capture-pane -t fleet-001:0.0 -p -S -9$' "$TMUX_MOCK_LOG"
  grep -q '^T=fleet-001:0.0$' "$SSH_MOCK_DIR/snippet.sh"
  # the snippet is what a Windows-originated host would receive; CRLF must be harmless
  printf 'done\n❯ \n' > "$TMUX_MOCK_DIR/capture.txt"
  run ordo_runtime inspect fleet-001:0.0
  [ "$(printf '%s' "$output" | jq -r '.idle')" = "true" ]
}

@test "ssh: start pastes the text remotely, signal/stop/recover/collect_evidence run the tmux commands remotely (#811)" {
  export ORDO_RUNTIME_ADAPTER=ssh
  run --separate-stderr ordo_runtime start fleet-001:0.0 --text x
  [ "$status" -eq 2 ]
  assert_error bad_argument
  run ordo_runtime start fleet-001:0.0 --host win-host --text $'Read /tmp/dispatch-fleet-001-42.md\nline two'
  [ "$status" -eq 0 ]
  assert_envelope start ssh
  [ "$(printf '%s' "$output" | jq -r '.submitted')" = "true" ]
  grep -qE '^load-buffer -b ordo_rt_[0-9_]+ /' "$TMUX_MOCK_LOG"
  grep -qE '^paste-buffer -b ordo_rt_[0-9_]+ -t fleet-001:0.0 -d$' "$TMUX_MOCK_LOG"
  grep -q '^send-keys -t fleet-001:0.0 Enter$' "$TMUX_MOCK_LOG"
  grep -q 'line two' "$SSH_MOCK_DIR/snippet.sh"
  export ORDO_SSH_HOST=win-host
  run ordo_runtime signal fleet-001:0.0 clear
  [ "$status" -eq 0 ]
  grep -q '^send-keys -t fleet-001:0.0 Escape$' "$TMUX_MOCK_LOG"
  grep -q '^send-keys -t fleet-001:0.0 C-u$' "$TMUX_MOCK_LOG"
  run ordo_runtime stop fleet-001:0.0 --kill
  [ "$(printf '%s' "$output" | jq -r '.action')" = "kill" ]
  grep -q '^kill-pane -t fleet-001:0.0$' "$TMUX_MOCK_LOG"
  printf 'token ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789\n' > "$TMUX_MOCK_DIR/capture.txt"
  run ordo_runtime collect_evidence fleet-001:0.0 --lines 40
  [ "$status" -eq 0 ]
  grep -q '^capture-pane -t fleet-001:0.0 -p -S -40$' "$TMUX_MOCK_LOG"
  grep -q '\[REDACTED\]' "$(printf '%s' "$output" | jq -r '.path')"
  touch "$TMUX_MOCK_DIR/missing"
  run ordo_runtime recover fleet-001:0.0 --workdir /w --command 'exec claude'
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.action')" = "session_created" ]
  grep -q '^new-session -d -s fleet-001 -c /w exec claude$' "$TMUX_MOCK_LOG"
  touch "$TMUX_MOCK_DIR/dead"
  run ordo_runtime recover fleet-001:0.0
  [ "$(printf '%s' "$output" | jq -r '.action')" = "pane_respawned" ]
  run ordo_runtime recover fleet-001:0.0
  [ "$(printf '%s' "$output" | jq -r '.action')" = "none" ]
}

@test "ssh: remote not-found is exit 4, remote tmux missing is exit 6, transport failure is retryable (#811)" {
  export ORDO_RUNTIME_ADAPTER=ssh ORDO_SSH_HOST=win-host
  touch "$TMUX_MOCK_DIR/missing"
  run --separate-stderr ordo_runtime inspect fleet-001:0.0
  [ "$status" -eq 4 ]
  assert_error not_found
  [ "$(printf '%s' "$stderr" | jq -r '.error.details.host')" = "win-host" ]
  rm -f "$TMUX_MOCK_DIR/missing"
  ORDO_SSH_REMOTE_TMUX=/nonexistent/tmux run --separate-stderr ordo_runtime inspect fleet-001:0.0
  [ "$status" -eq 6 ]
  assert_error missing_dependency
  touch "$SSH_MOCK_DIR/fail_255"
  run --separate-stderr ordo_runtime inspect fleet-001:0.0
  [ "$status" -eq 1 ]
  assert_error runtime_error true
  [ "$(printf '%s' "$stderr" | jq -r '.error.details.exit')" = "255" ]
}
