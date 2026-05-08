#!/usr/bin/env bats

load './helpers.bash'

wait_for_file() {
  local path=${1:?usage: wait_for_file <path>}
  local attempt
  for attempt in $(seq 1 50); do
    [ -s "$path" ] && return 0
    sleep 0.1
  done
  return 1
}

start_otel_capture_server() {
  export OTEL_CAPTURE_FILE="$BATS_TEST_TMPDIR/otel-capture.json"
  export OTEL_CAPTURE_HEADERS="$BATS_TEST_TMPDIR/otel-headers.txt"
  export OTEL_CAPTURE_PORT_FILE="$BATS_TEST_TMPDIR/otel-port.txt"
  export OTEL_CAPTURE_SCRIPT="$BATS_TEST_TMPDIR/otel-capture-server.py"

  cat > "$OTEL_CAPTURE_SCRIPT" <<'PY'
import http.server
import threading
import sys
from socketserver import TCPServer

outfile, headerfile, portfile = sys.argv[1:4]


class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length)
        with open(outfile, "wb") as fh:
            fh.write(body)
        with open(headerfile, "w", encoding="utf-8") as fh:
            fh.write(self.headers.get("Content-Type", ""))
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"{}")
        threading.Thread(target=self.server.shutdown, daemon=True).start()

    def log_message(self, format, *args):
        return


class ReuseTCPServer(TCPServer):
    allow_reuse_address = True


server = ReuseTCPServer(("127.0.0.1", 0), Handler)
with open(portfile, "w", encoding="utf-8") as fh:
    fh.write(str(server.server_address[1]))

server.serve_forever()
PY

  python3 "$OTEL_CAPTURE_SCRIPT" "$OTEL_CAPTURE_FILE" "$OTEL_CAPTURE_HEADERS" "$OTEL_CAPTURE_PORT_FILE" &
  export OTEL_SERVER_PID=$!

  local attempt
  for attempt in $(seq 1 50); do
    if [ -s "$OTEL_CAPTURE_PORT_FILE" ]; then
      export OTEL_CAPTURE_PORT
      OTEL_CAPTURE_PORT=$(cat "$OTEL_CAPTURE_PORT_FILE")
      return 0
    fi
    sleep 0.1
  done

  return 1
}

setup() {
  setup_orch_test
  toolkit_file lib/log_bounds.sh >/dev/null
}

teardown() {
  if [ -n "${OTEL_SERVER_PID:-}" ]; then
    kill "$OTEL_SERVER_PID" 2>/dev/null || true
    wait "$OTEL_SERVER_PID" 2>/dev/null || true
  fi
}

@test "audit writes a timestamped line and appends to the project log" {
  local audit_log
  toolkit_file lib/config_check.sh >/dev/null
  audit_log=$(toolkit_file lib/audit_log.sh)

  run bash -lc "$(orch_env_exports)
    source '$audit_log'
    audit 'TEST_EVENT hello'
  "

  [ "$status" -eq 0 ]
  [[ "$output" =~ ^AUDIT\ LOG:\ [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\ TEST_EVENT\ hello$ ]]
  grep -q 'TEST_EVENT hello' "$ORCH_LOG_DIR/$PROJECT.log"
}

@test "audit_action preserves structured key=value payloads" {
  local audit_log
  toolkit_file lib/config_check.sh >/dev/null
  audit_log=$(toolkit_file lib/audit_log.sh)

  run bash -lc "$(orch_env_exports)
    source '$audit_log'
    audit_action DISPATCH agent=claude ticket=#42
  "

  [ "$status" -eq 0 ]
  [[ "$output" == *"DISPATCH agent=claude ticket=#42"* ]]
}

@test "state_dir returns the project-scoped directory and creates it" {
  local audit_log
  toolkit_file lib/config_check.sh >/dev/null
  audit_log=$(toolkit_file lib/audit_log.sh)

  run bash -lc "$(orch_env_exports)
    source '$audit_log'
    state_dir
  "

  [ "$status" -eq 0 ]
  [ "$output" = "$ORCH_STATE_BASE/$PROJECT" ]
  [ -d "$ORCH_STATE_BASE/$PROJECT" ]
}

@test "die logs a fatal line and exits 1" {
  local audit_log
  toolkit_file lib/config_check.sh >/dev/null
  audit_log=$(toolkit_file lib/audit_log.sh)

  run bash -lc "$(orch_env_exports)
    source '$audit_log'
    die 'boom'
  "

  [ "$status" -eq 1 ]
  [[ "$output" == *"FATAL: boom"* ]]
}

@test "audit exports an OTLP JSON span when ORCH_OTEL_ENDPOINT is configured" {
  local audit_log
  toolkit_file lib/config_check.sh >/dev/null
  audit_log=$(toolkit_file lib/audit_log.sh)
  start_otel_capture_server

  run bash -lc "$(orch_env_exports)
    export ORCH_OTEL_ENDPOINT='http://127.0.0.1:$OTEL_CAPTURE_PORT/v1/traces'
    source '$audit_log'
    audit_action DISPATCH agent=claude ticket=#42 wave=wave-7
  "

  [ "$status" -eq 0 ]
  wait_for_file "$OTEL_CAPTURE_FILE"
  [ "$(cat "$OTEL_CAPTURE_HEADERS")" = "application/json" ]

  run python3 - "$OTEL_CAPTURE_FILE" "$PROJECT" <<'PY'
import json
import sys

payload_path, project = sys.argv[1:3]
with open(payload_path, "r", encoding="utf-8") as fh:
    payload = json.load(fh)

span = payload["resourceSpans"][0]["scopeSpans"][0]["spans"][0]
attrs = {
    item["key"]: next(iter(item["value"].values()))
    for item in span["attributes"]
}

assert span["name"] == "DISPATCH"
assert attrs["agent"] == "claude"
assert attrs["ticket"] == "#42"
assert attrs["wave"] == "wave-7"
assert attrs["project"] == project
assert attrs["event_type"] == "DISPATCH"
assert attrs["audit.message"] == "DISPATCH agent=claude ticket=#42 wave=wave-7"
print("ok")
PY

  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

@test "audit keeps local logging when OTEL export endpoint is down" {
  local audit_log
  toolkit_file lib/config_check.sh >/dev/null
  audit_log=$(toolkit_file lib/audit_log.sh)

  run bash -lc "$(orch_env_exports)
    export ORCH_OTEL_ENDPOINT='http://127.0.0.1:9/v1/traces'
    source '$audit_log'
    audit 'QUOTA_DETECT agent=codex wave=wave-2'
  "

  [ "$status" -eq 0 ]
  [[ "$output" == *"QUOTA_DETECT agent=codex wave=wave-2"* ]]
  grep -q 'QUOTA_DETECT agent=codex wave=wave-2' "$ORCH_LOG_DIR/$PROJECT.log"
}

# --- #313 evidence-path-outside-worktree guard ----------------------------

# Tests below mirror the audit_log fixture pattern: the lib files are
# sanitized into $SANITIZED_TK so the guard can be exercised with a
# stable PROJECT/log dir. The guard's detector (`worktree_path_is_inside`)
# lives in `lib/worktree_helpers.sh`, also sanitized in.

@test "evidence guard returns 0 for a path outside the worktree" {
  local audit_log worktree_helpers
  toolkit_file lib/config_check.sh >/dev/null
  audit_log=$(toolkit_file lib/audit_log.sh)
  worktree_helpers=$(toolkit_file lib/worktree_helpers.sh)

  # Explicit worktree root pinned to a tmp dir so the test is stable
  # regardless of the CWD bats was launched from.
  local worktree="$BATS_TEST_TMPDIR/worktree"
  local outside="$BATS_TEST_TMPDIR/elsewhere/evidence.png"
  mkdir -p "$worktree" "$BATS_TEST_TMPDIR/elsewhere"

  run bash -lc "$(orch_env_exports)
    source '$audit_log'
    source '$worktree_helpers'
    cd '$worktree'
    audit_assert_evidence_outside_worktree '$outside' 'unit-test'
  "

  [ "$status" -eq 0 ]
  ! grep -q 'EVIDENCE PATH GUARD' "$ORCH_LOG_DIR/$PROJECT.log" 2>/dev/null
}

@test "evidence guard refuses (exit 1) when path is inside worktree under strict mode" {
  local audit_log worktree_helpers
  toolkit_file lib/config_check.sh >/dev/null
  audit_log=$(toolkit_file lib/audit_log.sh)
  worktree_helpers=$(toolkit_file lib/worktree_helpers.sh)

  local worktree="$BATS_TEST_TMPDIR/worktree"
  local inside="$worktree/screenshots/leak.png"
  mkdir -p "$worktree"

  run bash -lc "$(orch_env_exports)
    source '$audit_log'
    source '$worktree_helpers'
    cd '$worktree'
    audit_assert_evidence_outside_worktree '$inside' 'visual-lane'
  "

  [ "$status" -eq 1 ]
  [[ "$output" == *"EVIDENCE PATH GUARD status=refused"* ]]
  [[ "$output" == *"context=visual-lane"* ]]
  [[ "$output" == *"mode=strict"* ]]
  grep -q 'EVIDENCE PATH GUARD status=refused' "$ORCH_LOG_DIR/$PROJECT.log"
}

@test "evidence guard warns and returns 0 in warn mode" {
  local audit_log worktree_helpers
  toolkit_file lib/config_check.sh >/dev/null
  audit_log=$(toolkit_file lib/audit_log.sh)
  worktree_helpers=$(toolkit_file lib/worktree_helpers.sh)

  local worktree="$BATS_TEST_TMPDIR/worktree"
  local inside="$worktree/forensics/dump.json"
  mkdir -p "$worktree"

  run bash -lc "$(orch_env_exports)
    export ORCH_EVIDENCE_PATH_GUARD=warn
    source '$audit_log'
    source '$worktree_helpers'
    cd '$worktree'
    audit_assert_evidence_outside_worktree '$inside' 'host-forensics'
  "

  [ "$status" -eq 0 ]
  [[ "$output" == *"EVIDENCE PATH GUARD status=warned"* ]]
  [[ "$output" == *"context=host-forensics"* ]]
  ! [[ "$output" == *"status=refused"* ]]
}

@test "evidence guard returns 0 silently in off mode (no audit emission)" {
  local audit_log worktree_helpers
  toolkit_file lib/config_check.sh >/dev/null
  audit_log=$(toolkit_file lib/audit_log.sh)
  worktree_helpers=$(toolkit_file lib/worktree_helpers.sh)

  local worktree="$BATS_TEST_TMPDIR/worktree"
  local inside="$worktree/wherever/dump.json"
  mkdir -p "$worktree"

  run bash -lc "$(orch_env_exports)
    export ORCH_EVIDENCE_PATH_GUARD=off
    source '$audit_log'
    source '$worktree_helpers'
    cd '$worktree'
    audit_assert_evidence_outside_worktree '$inside' 'should-be-silent'
  "

  [ "$status" -eq 0 ]
  ! [[ "$output" == *"EVIDENCE PATH GUARD"* ]]
  ! grep -q 'EVIDENCE PATH GUARD' "$ORCH_LOG_DIR/$PROJECT.log" 2>/dev/null
}

@test "evidence guard sources worktree_helpers lazily when not pre-sourced" {
  local audit_log
  toolkit_file lib/config_check.sh >/dev/null
  audit_log=$(toolkit_file lib/audit_log.sh)
  # Pre-place worktree_helpers.sh next to audit_log.sh in the sanitized
  # toolkit so the lazy `source` inside the guard finds it.
  toolkit_file lib/worktree_helpers.sh >/dev/null

  local worktree="$BATS_TEST_TMPDIR/wt"
  local inside="$worktree/lazy.txt"
  mkdir -p "$worktree"

  run bash -lc "$(orch_env_exports)
    source '$audit_log'
    cd '$worktree'
    audit_assert_evidence_outside_worktree '$inside' 'lazy-source'
  "

  # Strict default + path inside → exit 1, refused line emitted.
  [ "$status" -eq 1 ]
  [[ "$output" == *"EVIDENCE PATH GUARD status=refused"* ]]
}

@test "evidence guard skips with a structured note when detector cannot be located" {
  local audit_log
  toolkit_file lib/config_check.sh >/dev/null
  audit_log=$(toolkit_file lib/audit_log.sh)
  # Intentionally do NOT sanitize worktree_helpers.sh into $SANITIZED_TK,
  # so the lazy source in the guard fails to find it.

  local target="$BATS_TEST_TMPDIR/anywhere.txt"

  run bash -lc "$(orch_env_exports)
    source '$audit_log'
    audit_assert_evidence_outside_worktree '$target' 'no-detector'
  "

  [ "$status" -eq 0 ]
  [[ "$output" == *"EVIDENCE PATH GUARD status=skipped"* ]]
  [[ "$output" == *"reason=detector-unavailable"* ]]
  [[ "$output" == *"context=no-detector"* ]]
}

@test "worktree_path_is_inside classifies explicit roots correctly" {
  local worktree_helpers
  worktree_helpers=$(toolkit_file lib/worktree_helpers.sh)

  local root="$BATS_TEST_TMPDIR/explicit-root"
  mkdir -p "$root/sub"

  run bash -lc "
    source '$worktree_helpers'
    worktree_path_is_inside '$root/sub/file.txt' '$root'
  "
  [ "$status" -eq 0 ]

  run bash -lc "
    source '$worktree_helpers'
    worktree_path_is_inside '$BATS_TEST_TMPDIR/elsewhere/file.txt' '$root'
  "
  [ "$status" -eq 1 ]
}

@test "worktree_path_is_inside falls back to PWD when no root is given" {
  local worktree_helpers
  worktree_helpers=$(toolkit_file lib/worktree_helpers.sh)

  local root="$BATS_TEST_TMPDIR/pwd-root"
  mkdir -p "$root/nested"
  local outside="$BATS_TEST_TMPDIR/outside.txt"

  run bash -lc "
    source '$worktree_helpers'
    cd '$root'
    worktree_path_is_inside '$root/nested/file.txt'
  "
  [ "$status" -eq 0 ]

  run bash -lc "
    source '$worktree_helpers'
    cd '$root'
    worktree_path_is_inside '$outside'
  "
  [ "$status" -eq 1 ]
}
