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
