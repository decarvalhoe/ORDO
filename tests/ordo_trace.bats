#!/usr/bin/env bats
# tests/ordo_trace.bats — OpenTelemetry-compatible trace spans (#812, epic #806).
#
# Covers lib/ordo_trace.sh:
#   - span lifecycle: start/end/event lines under <state_dir>/traces/<trace>.jsonl,
#     folded span fields, pinned clock (ORDO_JOURNAL_NOW);
#   - parent linking (--parent, ORDO_TRACE_PARENT_SPAN, wrap propagation);
#   - export: OTLP/JSON ResourceSpans document shape and the jsonl format;
#   - redaction: a fake token injected through attributes, the environment and
#     a wrapped command line never reaches any trace file or export;
#   - ordo_trace_wrap status mapping and exit-code passthrough;
#   - errors (2 usage / bad kind, 4 unknown span or trace) and ORDO_TRACE_ENABLED=0.

bats_require_minimum_version 1.5.0

load './helpers.bash'

setup() {
  setup_orch_test
  # shellcheck disable=SC1090
  source "$TK/lib/audit_log.sh"
  set +e
  # shellcheck disable=SC1090
  source "$TK/lib/ordo_trace.sh"
  export ORDO_JOURNAL_NOW="2026-09-11T10:00:00Z"
  unset ORDO_TRACE_ID ORDO_TRACE_PARENT_SPAN ORDO_RUN_ID ORDO_TRACE_DIR
  export ORDO_TRACE_ENABLED=1
  TRACE="0123456789abcdef0123456789abcdef"
  export TRACE
}

assert_error_line() {
  local code="$1"
  [ "$(printf '%s\n' "$stderr" | grep -c .)" -eq 1 ] || { echo "stderr: $stderr"; return 1; }
  [ "$(printf '%s' "$stderr" | jq -r '.error.code')" = "$code" ] || { echo "stderr: $stderr"; return 1; }
  [ "$(printf '%s' "$stderr" | jq -r '.error.module')" = "trace" ]
}

# --- lifecycle ------------------------------------------------------------------

@test "start/end write append-only lines under state_dir/traces and fold into one span (#812)" {
  local span
  span=$(ordo_trace_start work.item --kind tool --trace "$TRACE" --attr ticket=42 --attr agent=fleet-001 --attr retry=false)
  [[ "$span" =~ ^[0-9a-f]{16}$ ]]
  local file="$(state_dir)/traces/$TRACE.jsonl"
  [ -f "$file" ]
  [ "$(wc -l < "$file")" -eq 1 ]
  export ORDO_JOURNAL_NOW="2026-09-11T10:00:05Z"
  ordo_trace_event "$span" checkpoint --attr step=2
  ordo_trace_end "$span" --status ok --attr result=merged
  [ "$(wc -l < "$file")" -eq 3 ]
  # Every line carries the full field set.
  jq -e 'has("trace_id") and has("span_id") and has("parent_span_id") and has("name") and has("kind") and has("start_time_unix_nano") and has("end_time_unix_nano") and has("status") and has("attributes") and has("resource")' "$file" >/dev/null
  [ "$(jq -r '.phase' "$file" | paste -sd, -)" = "start,event,end" ]
  run ordo_trace_span "$span"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.name' <<<"$output")" = "work.item" ]
  [ "$(jq -r '.kind' <<<"$output")" = "tool" ]
  [ "$(jq -r '.trace_id' <<<"$output")" = "$TRACE" ]
  [ "$(jq -r '.parent_span_id' <<<"$output")" = "null" ]
  [ "$(jq -r '.start_time_unix_nano' <<<"$output")" = "1789120800000000000" ]
  [ "$(jq -r '.end_time_unix_nano' <<<"$output")" = "1789120805000000000" ]
  [ "$(jq -c '.status' <<<"$output")" = '{"code":"OK","message":""}' ]
  [ "$(jq -c '.attributes' <<<"$output")" = '{"ticket":42,"agent":"fleet-001","retry":false,"result":"merged"}' ]
  [ "$(jq -c '.events' <<<"$output")" = '[{"name":"checkpoint","time_unix_nano":1789120805000000000,"attributes":{"step":2}}]' ]
  [ "$(jq -r '.resource["service.name"]' <<<"$output")" = "ordo" ]
  [ "$(jq -r '.resource["ordo.project"]' <<<"$output")" = "$PROJECT" ]
}

@test "trace id derives from ORDO_RUN_ID and the resource carries the run (#812)" {
  export ORDO_RUN_ID="run_0123456789abcdef01234567"
  local expected span
  expected=$(ordo_trace_id)
  [ "$expected" = "$(ordo_trace_new_id trace "$ORDO_RUN_ID")" ]
  [[ "$expected" =~ ^[0-9a-f]{32}$ ]]
  span=$(ordo_trace_start agent.turn --kind agent)
  [ -f "$(state_dir)/traces/$expected.jsonl" ]
  [ "$(ordo_trace_span "$span" | jq -r '.resource["ordo.run_id"]')" = "$ORDO_RUN_ID" ]
  # ORDO_TRACE_ID wins over the derived id.
  ORDO_TRACE_ID="$TRACE" ordo_trace_start model.call --kind model >/dev/null
  [ -f "$(state_dir)/traces/$TRACE.jsonl" ]
}

@test "parent linking: --parent, ORDO_TRACE_PARENT_SPAN default and wrap propagation (#812)" {
  local root child grand
  root=$(ordo_trace_start approval.authorize --kind approval --trace "$TRACE")
  child=$(ordo_trace_start policy.check --kind policy --trace "$TRACE" --parent "$root")
  [ "$(ordo_trace_span "$child" | jq -r '.parent_span_id')" = "$root" ]
  ORDO_TRACE_PARENT_SPAN="$child" grand=$(ordo_trace_start provider.pr_merge --kind provider --trace "$TRACE")
  [ "$(ordo_trace_span "$grand" | jq -r '.parent_span_id')" = "$child" ]
  # A command wrapped inside a span sees the trace and the parent via the environment.
  local probe="$BATS_TEST_TMPDIR/probe.sh"
  cat > "$probe" <<'EOF'
#!/usr/bin/env bash
printf '%s %s\n' "${ORDO_TRACE_ID:-none}" "${ORDO_TRACE_PARENT_SPAN:-none}"
EOF
  chmod +x "$probe"
  run ordo_trace_wrap retry.attempt --kind retry --trace "$TRACE" --parent "$root" -- "$probe"
  [ "$status" -eq 0 ]
  [[ "$output" == "$TRACE "* ]]
  local wrapped=${output#* }
  [[ "$wrapped" =~ ^[0-9a-f]{16}$ ]]
  [ "$(ordo_trace_span "$wrapped" | jq -r '.parent_span_id')" = "$root" ]
  [ "$(ordo_trace_span "$wrapped" | jq -r '.kind')" = "retry" ]
  [ "$(ordo_trace_spans "$TRACE" | wc -l)" -eq 4 ]
}

# --- export --------------------------------------------------------------------

@test "export produces an OTLP/JSON ResourceSpans document and jsonl folded spans (#812)" {
  local root child
  root=$(ordo_trace_start approval.authorize --kind approval --trace "$TRACE" --attr approval.id=approval_x)
  child=$(ordo_trace_start provider.pr_merge --kind provider --trace "$TRACE" --parent "$root" --attr number=42 --attr ratio=0.5)
  ordo_trace_event "$child" receipt --attr replayed=false
  ordo_trace_end "$child" --status error --message "provider exit 3"
  ordo_trace_end "$root" --status ok
  run ordo_trace_export "$TRACE"
  [ "$status" -eq 0 ]
  local doc="$output"
  jq -e '.resourceSpans | type == "array" and length == 1' <<<"$doc" >/dev/null
  [ "$(jq -r '.resourceSpans[0].resource.attributes[] | select(.key == "service.name") | .value.stringValue' <<<"$doc")" = "ordo" ]
  [ "$(jq -r '.resourceSpans[0].scopeSpans[0].scope.name' <<<"$doc")" = "ordo.trace" ]
  [ "$(jq -r '.resourceSpans[0].scopeSpans[0].spans | length' <<<"$doc")" = "2" ]
  local pspan
  pspan=$(jq -c '.resourceSpans[0].scopeSpans[0].spans[] | select(.name == "provider.pr_merge")' <<<"$doc")
  [ "$(jq -r '.traceId | length' <<<"$pspan")" = "32" ]
  [ "$(jq -r '.spanId | length' <<<"$pspan")" = "16" ]
  [ "$(jq -r '.parentSpanId' <<<"$pspan")" = "$root" ]
  [ "$(jq -r '.kind' <<<"$pspan")" = "3" ]
  [ "$(jq -r '.startTimeUnixNano' <<<"$pspan")" = "1789120800000000000" ]
  [ "$(jq -r '.endTimeUnixNano' <<<"$pspan")" = "1789120800000000000" ]
  [ "$(jq -c '.status' <<<"$pspan")" = '{"code":2,"message":"provider exit 3"}' ]
  [ "$(jq -r '.attributes[] | select(.key == "number") | .value.intValue' <<<"$pspan")" = "42" ]
  [ "$(jq -r '.attributes[] | select(.key == "ratio") | .value.doubleValue' <<<"$pspan")" = "0.5" ]
  [ "$(jq -r '.attributes[] | select(.key == "ordo.span.kind") | .value.stringValue' <<<"$pspan")" = "provider" ]
  [ "$(jq -c '.events[0] | {name, attributes}' <<<"$pspan")" = '{"name":"receipt","attributes":[{"key":"replayed","value":{"boolValue":false}}]}' ]
  local rspan
  rspan=$(jq -c '.resourceSpans[0].scopeSpans[0].spans[] | select(.name == "approval.authorize")' <<<"$doc")
  [ "$(jq -r '.kind' <<<"$rspan")" = "1" ]
  [ "$(jq -r '.parentSpanId' <<<"$rspan")" = "" ]
  [ "$(jq -c '.status' <<<"$rspan")" = '{"code":1,"message":""}' ]
  # jsonl: one folded span per line, root first.
  run ordo_trace_export "$TRACE" --format jsonl
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c .)" -eq 2 ]
  [ "$(printf '%s\n' "$output" | head -n1 | jq -r '.name')" = "approval.authorize" ]
  run --separate-stderr ordo_trace_export "$TRACE" --format xml
  [ "$status" -eq 2 ]
  assert_error_line bad_argument
}

# --- redaction ------------------------------------------------------------------

@test "a fake token in attributes, the environment and a command line never appears in traces or exports (#812)" {
  local token="ghp_FAKE0123456789abcdefghijklmnopqrstuv"
  local env_secret="plain-env-secret-value-XYZ"
  export FAKE_FORGE_TOKEN="$env_secret"
  export ORDO_TRACE_REDACT_RE='hunter[0-9]+'
  local span
  span=$(ordo_trace_start provider.call --kind provider --trace "$TRACE" \
    --attr "authorization=Bearer abcdefghijklmnopqrstuvwxyz0123" --attr "note=token is $token here" \
    --attr "env=value $env_secret leaked" --attr "pw=hunter22")
  ordo_trace_event "$span" "login $token" --attr "api_key=whatever"
  ordo_trace_end "$span" --status error --message "failed with $token and $env_secret"
  run ordo_trace_wrap tool.curl --kind tool --trace "$TRACE" -- true --header "Authorization: Bearer $token" --data "$env_secret"
  [ "$status" -eq 0 ]
  local dir="$(state_dir)/traces"
  ! grep -rF "$token" "$dir"
  ! grep -rF "$env_secret" "$dir"
  ! grep -rF "hunter22" "$dir"
  ! grep -rF "abcdefghijklmnopqrstuvwxyz0123" "$dir"
  run ordo_trace_export "$TRACE"
  [ "$status" -eq 0 ]
  [[ "$output" != *"$token"* ]]
  [[ "$output" != *"$env_secret"* ]]
  [[ "$output" != *"hunter22"* ]]
  run ordo_trace_export "$TRACE" --format jsonl
  [[ "$output" != *"$token"* ]]
  local folded
  folded=$(ordo_trace_span "$span")
  [ "$(jq -r '.attributes.authorization' <<<"$folded")" = "[REDACTED]" ]
  [ "$(jq -r '.attributes.note' <<<"$folded")" = "token is [REDACTED] here" ]
  [ "$(jq -r '.attributes.env' <<<"$folded")" = "value [REDACTED] leaked" ]
  [ "$(jq -r '.attributes.pw' <<<"$folded")" = "[REDACTED]" ]
  [ "$(jq -r '.events[0].name' <<<"$folded")" = "login [REDACTED]" ]
  [ "$(jq -r '.events[0].attributes.api_key' <<<"$folded")" = "[REDACTED]" ]
  [ "$(jq -r '.status.message' <<<"$folded")" = "failed with [REDACTED] and [REDACTED]" ]
  local wrapped
  wrapped=$(ordo_trace_spans "$TRACE" | jq -c 'select(.name == "tool.curl")')
  [[ "$(jq -r '.attributes["ordo.command"]' <<<"$wrapped")" == *"[REDACTED]"* ]]
  [[ "$(jq -r '.attributes["ordo.command"]' <<<"$wrapped")" != *"$token"* ]]
}

# --- wrap ----------------------------------------------------------------------

@test "wrap maps exit 0 to status ok and a failure to status error, passing the exit code through (#812)" {
  run ordo_trace_wrap tool.ok --kind tool --trace "$TRACE" --attr step=1 -- bash -c 'echo hello'
  [ "$status" -eq 0 ]
  [ "$output" = "hello" ]
  run ordo_trace_wrap tool.fail --kind tool --trace "$TRACE" -- bash -c 'echo boom >&2; exit 7'
  [ "$status" -eq 7 ]
  local ok fail
  ok=$(ordo_trace_spans "$TRACE" | jq -c 'select(.name == "tool.ok")')
  fail=$(ordo_trace_spans "$TRACE" | jq -c 'select(.name == "tool.fail")')
  [ "$(jq -r '.status.code' <<<"$ok")" = "OK" ]
  [ "$(jq -r '.attributes["ordo.exit_code"]' <<<"$ok")" = "0" ]
  [ "$(jq -r '.attributes.step' <<<"$ok")" = "1" ]
  [ "$(jq -r '.attributes["ordo.command.argv0"]' <<<"$ok")" = "bash" ]
  [ "$(jq -r '.status.code' <<<"$fail")" = "ERROR" ]
  [ "$(jq -r '.status.message' <<<"$fail")" = "exit 7" ]
  [ "$(jq -r '.attributes["ordo.exit_code"]' <<<"$fail")" = "7" ]
  # Default kind for a wrapped command is tool.
  run ordo_trace_wrap tool.default --trace "$TRACE" -- true
  [ "$status" -eq 0 ]
  [ "$(ordo_trace_spans "$TRACE" | jq -r 'select(.name == "tool.default") | .kind')" = "tool" ]
  run --separate-stderr ordo_trace_wrap tool.none --trace "$TRACE"
  [ "$status" -eq 2 ]
  assert_error_line usage
}

# --- errors and switches ------------------------------------------------------------

@test "errors: unknown kind exits 2, unknown span or trace exits 4, disabled tracing writes nothing (#812)" {
  run --separate-stderr ordo_trace_start x --kind bogus
  [ "$status" -eq 2 ]
  assert_error_line bad_argument
  run --separate-stderr ordo_trace_start
  [ "$status" -eq 2 ]
  assert_error_line usage
  run --separate-stderr ordo_trace_end 0000000000000000
  [ "$status" -eq 4 ]
  assert_error_line not_found
  run --separate-stderr ordo_trace_span 0000000000000000
  [ "$status" -eq 4 ]
  assert_error_line not_found
  run --separate-stderr ordo_trace_export "$TRACE"
  [ "$status" -eq 4 ]
  assert_error_line not_found
  export ORDO_TRACE_ENABLED=0
  local span
  span=$(ordo_trace_start quiet --kind internal --trace "$TRACE")
  [[ "$span" =~ ^[0-9a-f]{16}$ ]]
  ordo_trace_end "$span" --status ok
  run ordo_trace_wrap quiet.wrap --trace "$TRACE" -- true
  [ "$status" -eq 0 ]
  [ ! -f "$(state_dir)/traces/$TRACE.jsonl" ]
}
