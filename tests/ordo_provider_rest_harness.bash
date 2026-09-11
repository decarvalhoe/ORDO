#!/usr/bin/env bash
# tests/ordo_provider_rest_harness.bash — shared harness of the REST provider
# adapter suites (#815): tests/ordo_provider_adapter_forgejo.bats and
# tests/ordo_provider_adapter_gitlab.bats.
#
# Loaded after `load './helpers.bash'`. The bats file sets REST_FORGE
# (forgejo|gitlab) and calls rest_harness_setup from setup() and
# rest_harness_teardown from teardown(). The harness:
#   - starts tests/fixtures/adapters/stub_server.sh (python3 stdlib) on an
#     ephemeral 127.0.0.1 port with the recorded fixtures of the forge and a
#     per-test control directory ($STUB_CONTROL);
#   - writes a 0600 token file with a distinctive secret ($STUB_TOKEN) that
#     the stub demands on every request and that every test greps for
#     afterwards (assert_no_token_leak);
#   - exports ORDO_FORGE_URL / ORDO_FORGE_REPO / ORDO_FORGE_TOKEN_FILE /
#     ORDO_PROVIDER_ADAPTER and an ORDO_PROVIDER_HTTP_LOG under the test tmp;
#   - installs a `gh` decoy on PATH that records any invocation (the REST
#     adapters must never call it);
#   - defines the three conformance hooks (conformance_backend_setup,
#     conformance_inject_failure, conformance_mutation_count).

rest_harness_setup() {
  export REST_FORGE="${REST_FORGE:?REST_FORGE must be forgejo or gitlab}"
  export FIXTURES="$TK/tests/fixtures/adapters/$REST_FORGE"
  export FAKE_FIXTURES="$TK/tests/fixtures/adapters/fake"
  export STUB_CONTROL="$BATS_TEST_TMPDIR/stub"
  export STUB_TOKEN="frg_SECRETTOKENabcdefghijklmnopqrstuvwxyz0123"
  export GH_DECOY_LOG="$BATS_TEST_TMPDIR/gh-decoy.log"
  mkdir -p "$STUB_CONTROL"
  export ORDO_FORGE_TOKEN_FILE="$BATS_TEST_TMPDIR/token"
  (umask 077; printf '%s\n' "$STUB_TOKEN" > "$ORDO_FORGE_TOKEN_FILE")
  export ORDO_FORGE_REPO="acme/widgets"
  export ORDO_PROVIDER_ADAPTER="$REST_FORGE"
  export ORDO_PROVIDER_HTTP_LOG="$BATS_TEST_TMPDIR/http.log"
  unset ORCH_EXTERNAL_PR_MUTATIONS GH_REPO ORDO_FORGE_TOKEN ORDO_FORGE_URL
  write_mock_bin gh <<'EOF'
#!/usr/bin/env bash
printf 'gh %s\n' "$*" >> "${GH_DECOY_LOG:?}"
exit 99
EOF
  rest_stub_start "$FIXTURES"
  # audit_log.sh gives the gate its audit() sink (PROJECT is set by setup_orch_test).
  # It also runs `set -euo pipefail`; restore the bats defaults afterwards
  # (errexit + ERR trap inheritance ON so every `[ ... ]` assertion counts,
  # nounset and pipefail OFF).
  # shellcheck disable=SC1090
  source "$TK/lib/audit_log.sh"
  set -eET
  set +u
  set +o pipefail
  # shellcheck disable=SC1090
  source "$TK/lib/ordo_provider_adapter.sh"
  # shellcheck disable=SC1090
  source "$TK/tests/ordo_provider_conformance.bash"
}

rest_harness_teardown() {
  rest_stub_stop
}

# rest_stub_start [fixtures-dir]: starts the stub, exports ORDO_FORGE_URL.
rest_stub_start() {
  local fixtures="${1:-$FIXTURES}" port_file="$BATS_TEST_TMPDIR/stub.port"
  rm -f "$port_file"
  # Close fd 3 and detach stdio so bats does not wait on the server.
  bash "$TK/tests/fixtures/adapters/stub_server.sh" --fixtures "$fixtures" --control "$STUB_CONTROL" \
    --forge "$REST_FORGE" --port-file "$port_file" --token-file "$ORDO_FORGE_TOKEN_FILE" \
    </dev/null >"$BATS_TEST_TMPDIR/stub.out" 2>&1 3>&- &
  printf '%s\n' "$!" > "$BATS_TEST_TMPDIR/stub.pid"
  local i=0
  while [[ ! -s "$port_file" ]]; do
    sleep 0.05
    i=$((i + 1))
    if [[ "$i" -gt 200 ]]; then
      printf 'stub server did not start:\n' >&2
      cat "$BATS_TEST_TMPDIR/stub.out" >&2
      return 1
    fi
  done
  export STUB_PORT
  STUB_PORT=$(cat "$port_file")
  export ORDO_FORGE_URL="http://127.0.0.1:${STUB_PORT}"
}

rest_stub_stop() {
  if [[ -f "$BATS_TEST_TMPDIR/stub.pid" ]]; then
    kill "$(cat "$BATS_TEST_TMPDIR/stub.pid")" 2>/dev/null || true
    wait "$(cat "$BATS_TEST_TMPDIR/stub.pid")" 2>/dev/null || true
    rm -f "$BATS_TEST_TMPDIR/stub.pid"
  fi
}

# rest_inject_failure <json-rule>: writes the stub failure rule.
rest_inject_failure() {
  printf '%s\n' "$1" > "$STUB_CONTROL/fail.json"
}

rest_clear_failures() {
  rm -f "$STUB_CONTROL/fail.json"
}

# rest_requests [jq-filter]: the recorded requests (one JSON per line).
rest_requests() {
  if [[ -f "$STUB_CONTROL/requests.jsonl" ]]; then
    jq -c "${1:-.}" "$STUB_CONTROL/requests.jsonl"
  fi
}

rest_request_count() {
  # [jq-select-expr]
  rest_requests "select(${1:-true})" | grep -c . || true
}

# The API path of PR/MR 12 on this forge (for failure injection).
rest_pr_path() {
  local n="${1:-12}"
  case "$REST_FORGE" in
    forgejo) printf '/api/v1/repos/acme/widgets/pulls/%s\n' "$n" ;;
    gitlab) printf '/api/v4/projects/acme/widgets/merge_requests/%s\n' "$n" ;;
  esac
}

# Fails when the token string appears anywhere it must not: stdout/stderr
# captured by the caller (passed as arguments), every file under the test
# tmp except the token file itself, the audit log dir, the state dir.
assert_no_token_leak() {
  local text
  for text in "$@"; do
    if [[ "$text" == *"$STUB_TOKEN"* ]]; then
      printf 'token leaked into captured output\n' >&2
      return 1
    fi
  done
  local leaks
  # (the token file itself and a failure rule a test wrote on purpose are inputs, not leaks)
  leaks=$(grep -rlF "$STUB_TOKEN" "$BATS_TEST_TMPDIR" "$ORCH_LOG_DIR" "$ORCH_STATE_BASE" 2>/dev/null | grep -v -e "/token$" -e "/stub/fail.json$" || true)
  if [[ -n "$leaks" ]]; then
    printf 'token leaked into files:\n%s\n' "$leaks" >&2
    return 1
  fi
  if [[ -f "$GH_DECOY_LOG" ]]; then
    printf 'gh was invoked by a REST adapter:\n' >&2
    cat "$GH_DECOY_LOG" >&2
    return 1
  fi
  return 0
}

# --- conformance harness hooks ---------------------------------------------
conformance_backend_setup() {
  export ORDO_FORGE_REPO="acme/widgets"
  rest_clear_failures
}

conformance_inject_failure() {
  case "$1" in
    retryable)
      rest_inject_failure "$(jq -cn --arg p "$(rest_pr_path 12)" '{"method": "GET", "path": $p, "status": 502, "body": {"message": "Bad Gateway"}}')" ;;
    *)
      rest_inject_failure "$(jq -cn --arg p "$(rest_pr_path 12)" '{"method": "GET", "path": $p, "status": 401, "body": {"message": "token is required"}}')" ;;
  esac
  printf '12\n'
}

conformance_mutation_count() {
  rest_request_count '.method != "GET"'
}

run_conformance() {
  conformance_backend_setup
  run ordo_provider_conformance_run "$1"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  assert_no_token_leak "$output"
}

# shellcheck disable=SC2154 # $stderr is set by bats `run --separate-stderr`
assert_error() {
  local code="$1" module="${2:-provider_adapter}"
  [ "$(printf '%s\n' "$stderr" | grep -c .)" -eq 1 ]
  [ "$(printf '%s' "$stderr" | jq -r '.error.code')" = "$code" ]
  [ "$(printf '%s' "$stderr" | jq -r '.error.module')" = "$module" ]
  printf '%s' "$stderr" | jq -e '.error.details.retryable | type == "boolean"' >/dev/null
  [ -z "$output" ]
}

# Key set of a JSON document: every path with array indices collapsed to [].
json_key_set() {
  jq -c '[paths | map(if type == "number" then "[]" else . end) | join(".")] | unique' "$@"
}

# assert_same_keys <spec...> -- <fixture-relative-path>
#   Runs ordo_provider <spec> on the adapter under test and compares its key
#   set (envelope stripped) with the fake fixture (the github-derived shape).
#   An array that is empty in the adapter output (a capability the forge does
#   not have, e.g. closed_by_prs on Forgejo, job steps on GitLab) hides the
#   shape of its items, so the fixture's paths under it are not demanded;
#   every non-empty array must match item for item.
assert_same_keys() {
  local spec="$1" fixture="$2" got want
  # shellcheck disable=SC2086 # intentional word-splitting of the op spec
  run ordo_provider $spec
  [ "$status" -eq 0 ] || { echo "$spec: $output"; return 1; }
  local doc
  doc=$(printf '%s' "$output" | jq -c 'del(.op, .adapter, .repo)')
  got=$(printf '%s' "$doc" | json_key_set)
  want=$(json_key_set "$FAKE_FIXTURES/$fixture" | jq -c --argjson doc "$doc" '
    ([$doc | paths(type == "array" and length == 0) | map(if type == "number" then "[]" else . end) | join(".") + ".[]"]) as $hidden
    | map(. as $p | select(any($hidden[]; . as $h | $p | startswith($h)) | not))')
  [ "$got" = "$want" ] || { echo "$spec: key set differs from $fixture"; diff <(printf '%s' "$got" | jq '.[]') <(printf '%s' "$want" | jq '.[]'); return 1; }
}
