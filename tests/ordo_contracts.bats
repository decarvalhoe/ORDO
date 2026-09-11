#!/usr/bin/env bats
# tests/ordo_contracts.bats — canonical execution contracts v1 (#807, epic #806).
#
# Covers lib/ordo_contracts.sh and contracts/v1/emit.sh:
#   - the ten kinds, id format, RFC3339 UTC timestamps;
#   - fixture validation for every kind (valid / invalid / forward-compat);
#   - the error object printed on stderr and its exit-code mapping;
#   - the three transition tables and terminal-state checks;
#   - redaction of secret-looking keys and token-looking values;
#   - emit.sh staying in sync with the library.

bats_require_minimum_version 1.5.0

load './helpers.bash'

KINDS="run task attempt agent lease event approval artifact policy_decision blocker"

setup() {
  setup_orch_test
  # shellcheck disable=SC1090
  source "$TK/lib/ordo_contracts.sh"
  FIXTURES="$TK/tests/fixtures/contracts/v1"
  EMIT="$TK/contracts/v1/emit.sh"
  export FIXTURES EMIT
}

# Assert that $stderr holds exactly one JSON error line with the given code.
assert_error_line() {
  local code="$1"
  [ "$(printf '%s\n' "$stderr" | grep -c .)" -eq 1 ]
  [ "$(printf '%s' "$stderr" | jq -r '.error.code')" = "$code" ]
  [ "$(printf '%s' "$stderr" | jq -r '.error.module')" = "contracts" ]
  [ -n "$(printf '%s' "$stderr" | jq -r '.error.message')" ]
  printf '%s' "$stderr" | jq -e '.error.details | type == "object"' >/dev/null
}

# Assert that the valid/invalid/compat fixtures of one kind behave as expected.
check_kind_fixtures() {
  local kind="$1"
  [ -f "$FIXTURES/$kind.valid.json" ]
  [ -f "$FIXTURES/$kind.invalid.json" ]
  [ -f "$FIXTURES/compat/$kind.extra-fields.json" ]

  run --separate-stderr ordo_contracts_validate "$kind" "@$FIXTURES/$kind.valid.json"
  [ "$status" -eq 0 ] || { echo "valid fixture rejected for $kind: $stderr"; return 1; }
  [ -z "$output" ]
  [ -z "$stderr" ]

  run --separate-stderr ordo_contracts_validate "$kind" "@$FIXTURES/$kind.invalid.json"
  [ "$status" -eq 5 ] || { echo "invalid fixture accepted for $kind (status $status)"; return 1; }
  [ -z "$output" ]
  assert_error_line invalid_contract
  [ "$(printf '%s' "$stderr" | jq -r '.error.details.kind')" = "$kind" ]
  [ "$(printf '%s' "$stderr" | jq -r '.error.details.schema_version')" = "1" ]
  [ "$(printf '%s' "$stderr" | jq -r '.error.details.errors | length')" -ge 1 ]

  run --separate-stderr ordo_contracts_validate "$kind" "@$FIXTURES/compat/$kind.extra-fields.json"
  [ "$status" -eq 0 ] || { echo "compat fixture rejected for $kind: $stderr"; return 1; }
}

# --- kinds, ids, time -------------------------------------------------------

@test "kinds lists the ten canonical kinds in order (#807)" {
  run ordo_contracts_kinds
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | tr '\n' ' ' | sed 's/ $//')" = "$KINDS" ]
  [ "$(printf '%s\n' "$output" | wc -l)" -eq 10 ]
}

@test "new_id prints <kind>_<24 hex> for every kind and ids are unique (#807)" {
  local kind id other
  for kind in $KINDS; do
    id=$(ordo_contracts_new_id "$kind")
    [[ "$id" =~ ^${kind}_[0-9a-f]{24}$ ]] || { echo "bad id for $kind: $id"; return 1; }
    other=$(ordo_contracts_new_id "$kind")
    [ "$id" != "$other" ]
  done
}

@test "new_id refuses an unknown kind with exit 2 and an error object (#807)" {
  run --separate-stderr ordo_contracts_new_id bogus
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  assert_error_line unknown_kind
  printf '%s' "$stderr" | jq -e '.error.details.known | index(["run"]) != null' >/dev/null
}

@test "now prints an RFC3339 UTC timestamp with Z suffix that validates (#807)" {
  local now
  now=$(ordo_contracts_now)
  [[ "$now" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
  local obj
  obj=$(jq -c --arg now "$now" '.created_at = $now' "$FIXTURES/run.valid.json")
  run ordo_contracts_validate run "$obj"
  [ "$status" -eq 0 ]
}

# --- fixture validation, one test per kind ---------------------------------

@test "run: valid, invalid and compat fixtures (#807)" { check_kind_fixtures run; }
@test "task: valid, invalid and compat fixtures (#807)" { check_kind_fixtures task; }
@test "attempt: valid, invalid and compat fixtures (#807)" { check_kind_fixtures attempt; }
@test "agent: valid, invalid and compat fixtures (#807)" { check_kind_fixtures agent; }
@test "lease: valid, invalid and compat fixtures (#807)" { check_kind_fixtures lease; }
@test "event: valid, invalid and compat fixtures (#807)" { check_kind_fixtures event; }
@test "approval: valid, invalid and compat fixtures (#807)" { check_kind_fixtures approval; }
@test "artifact: valid, invalid and compat fixtures (#807)" { check_kind_fixtures artifact; }
@test "policy_decision: valid, invalid and compat fixtures (#807)" { check_kind_fixtures policy_decision; }
@test "blocker: valid, invalid and compat fixtures (#807)" { check_kind_fixtures blocker; }

@test "every fixture file on disk belongs to a known kind (no orphan fixtures) (#807)" {
  local f base kind
  for f in "$FIXTURES"/*.json "$FIXTURES"/compat/*.json; do
    base=$(basename "$f")
    kind=${base%%.*}
    [[ " $KINDS " == *" $kind "* ]] || { echo "orphan fixture: $f"; return 1; }
    jq -e . "$f" >/dev/null
  done
}

# --- validation semantics ---------------------------------------------------

@test "validate reports every violation with a JSON path (#807)" {
  local obj
  obj=$(jq -c '.state = "done" | del(.project) | .id = "run_zz" | .actor.type = "robot" | .tasks = [3]' \
    "$FIXTURES/run.valid.json")
  run --separate-stderr ordo_contracts_validate run "$obj"
  [ "$status" -eq 5 ]
  assert_error_line invalid_contract
  local errors
  errors=$(printf '%s' "$stderr" | jq -r '.error.details.errors[]')
  [[ "$errors" == *'$.project: required field missing'* ]]
  [[ "$errors" == *'$.state: value "done" not in'* ]]
  [[ "$errors" == *'$.id: value "run_zz" does not match'* ]]
  [[ "$errors" == *'$.actor.type: value "robot" not in'* ]]
  [[ "$errors" == *'$.tasks[0]: expected string, got number'* ]]
}

@test "validate rejects an object whose kind does not match the schema (#807)" {
  run --separate-stderr ordo_contracts_validate task "@$FIXTURES/run.valid.json"
  [ "$status" -eq 5 ]
  assert_error_line invalid_contract
  [[ "$(printf '%s' "$stderr" | jq -r '.error.details.errors[]')" == *'$.kind: expected constant "task"'* ]]
}

@test "validate rejects every common-envelope omission (#807)" {
  local field
  for field in schema_version kind id created_at correlation_id actor; do
    run --separate-stderr ordo_contracts_validate run "$(jq -c "del(.$field)" "$FIXTURES/run.valid.json")"
    [ "$status" -eq 5 ] || { echo "missing $field accepted"; return 1; }
    [[ "$stderr" == *"\$.$field: required field missing"* ]]
  done
}

@test "validate enforces schema_version \"1\" and the actor type enum (#807)" {
  run --separate-stderr ordo_contracts_validate run "$(jq -c '.schema_version = "2"' "$FIXTURES/run.valid.json")"
  [ "$status" -eq 5 ]
  [[ "$(printf '%s' "$stderr" | jq -r '.error.details.errors[]')" == *'$.schema_version: expected constant "1"'* ]]
  run --separate-stderr ordo_contracts_validate run "$(jq -c '.actor = {"type": "model"}' "$FIXTURES/run.valid.json")"
  [ "$status" -eq 5 ]
  [[ "$stderr" == *'$.actor.id: required field missing'* ]]
}

@test "validate enforces RFC3339 UTC timestamps: offsets and impossible dates fail, fractions pass (#807)" {
  local base
  base=$(cat "$FIXTURES/run.valid.json")
  run --separate-stderr ordo_contracts_validate run "$(printf '%s' "$base" | jq -c '.created_at = "2026-09-11T10:00:00+02:00"')"
  [ "$status" -eq 5 ]
  [[ "$stderr" == *'$.created_at: not an RFC3339 UTC timestamp'* ]]
  run --separate-stderr ordo_contracts_validate run "$(printf '%s' "$base" | jq -c '.created_at = "2026-13-01T00:00:00Z"')"
  [ "$status" -eq 5 ]
  run --separate-stderr ordo_contracts_validate run "$(printf '%s' "$base" | jq -c '.created_at = "2026-09-11 10:00:00"')"
  [ "$status" -eq 5 ]
  run --separate-stderr ordo_contracts_validate run "$(printf '%s' "$base" | jq -c '.created_at = "2026-09-11T10:00:00.250Z"')"
  [ "$status" -eq 0 ]
}

@test "validate enforces the id format for references (run_id, task_id, ...) (#807)" {
  run --separate-stderr ordo_contracts_validate attempt "$(jq -c '.task_id = "task_0123"' "$FIXTURES/attempt.valid.json")"
  [ "$status" -eq 5 ]
  [[ "$(printf '%s' "$stderr" | jq -r '.error.details.errors[]')" == *'$.task_id: value "task_0123" does not match ^task_[0-9a-f]{24}$'* ]]
  run --separate-stderr ordo_contracts_validate lease "$(jq -c '.run_id = "RUN_0123456789ABCDEF01234567"' "$FIXTURES/lease.valid.json")"
  [ "$status" -eq 5 ]
  [[ "$stderr" == *'$.run_id'* ]]
}

@test "event requires idempotency_key only when mutation is true (#807)" {
  local base
  base=$(jq -c 'del(.idempotency_key)' "$FIXTURES/event.valid.json")
  run --separate-stderr ordo_contracts_validate event "$(printf '%s' "$base" | jq -c '.mutation = true')"
  [ "$status" -eq 5 ]
  [[ "$stderr" == *'$.idempotency_key: required field missing'* ]]
  run --separate-stderr ordo_contracts_validate event "$(printf '%s' "$base" | jq -c '.mutation = false')"
  [ "$status" -eq 0 ]
  run --separate-stderr ordo_contracts_validate event "$(printf '%s' "$base" | jq -c '.mutation = true | .idempotency_key = ""')"
  [ "$status" -eq 5 ]
  [[ "$stderr" == *'$.idempotency_key: shorter than minLength 1'* ]]
  run --separate-stderr ordo_contracts_validate event "$(printf '%s' "$base" | jq -c '.mutation = "yes"')"
  [ "$status" -eq 5 ]
  [[ "$stderr" == *'$.mutation: expected boolean, got string'* ]]
}

@test "approval always requires idempotency_key (#807)" {
  run --separate-stderr ordo_contracts_validate approval "$(jq -c 'del(.idempotency_key)' "$FIXTURES/approval.valid.json")"
  [ "$status" -eq 5 ]
  [[ "$stderr" == *'$.idempotency_key: required field missing'* ]]
}

@test "validate accepts literal JSON, stdin (-) and @file inputs (#807)" {
  local obj
  obj=$(jq -c . "$FIXTURES/task.valid.json")
  run ordo_contracts_validate task "$obj"
  [ "$status" -eq 0 ]
  run bash -c "source '$TK/lib/ordo_contracts.sh'; printf '%s' '$obj' | ordo_contracts_validate task -"
  [ "$status" -eq 0 ]
  run ordo_contracts_validate task "@$FIXTURES/task.valid.json"
  [ "$status" -eq 0 ]
}

@test "validate maps bad input to typed errors: invalid JSON 5, unknown kind 2, missing file 4, usage 2 (#807)" {
  run --separate-stderr ordo_contracts_validate run '{"broken":'
  [ "$status" -eq 5 ]
  assert_error_line invalid_json
  run --separate-stderr ordo_contracts_validate widget '{}'
  [ "$status" -eq 2 ]
  assert_error_line unknown_kind
  run --separate-stderr ordo_contracts_validate run "@$BATS_TEST_TMPDIR/does-not-exist.json"
  [ "$status" -eq 4 ]
  assert_error_line not_found
  run --separate-stderr ordo_contracts_validate run
  [ "$status" -eq 2 ]
  assert_error_line usage
}

@test "forward compatibility: unknown top-level and nested fields never fail v1 validation (#807)" {
  local kind obj
  for kind in $KINDS; do
    obj=$(jq -c '. + {"x_added_in_v1_7": {"deep": [1, {"deeper": true}]}, "another_new_field": 42}
                 | .actor += {"display_name": "future", "session": {"id": "s1"}}' \
          "$FIXTURES/$kind.valid.json")
    run --separate-stderr ordo_contracts_validate "$kind" "$obj"
    [ "$status" -eq 0 ] || { echo "forward-compat failure for $kind: $stderr"; return 1; }
  done
}

# --- transitions -------------------------------------------------------------

@test "run table accepts every transition listed in the brief (#807)" {
  local edge from to
  for edge in \
    queued:leased queued:cancelled queued:expired \
    leased:running leased:queued leased:expired leased:cancelled \
    running:waiting running:blocked running:approval_required running:succeeded running:failed running:cancelled \
    waiting:running waiting:expired waiting:cancelled waiting:failed \
    blocked:running blocked:queued blocked:failed blocked:cancelled \
    approval_required:running approval_required:queued approval_required:expired approval_required:cancelled approval_required:failed
  do
    from=${edge%%:*}; to=${edge##*:}
    run --separate-stderr ordo_contracts_transition run "$from" "$to"
    [ "$status" -eq 0 ] || { echo "$from -> $to refused: $stderr"; return 1; }
    [ -z "$output" ] && [ -z "$stderr" ]
  done
}

@test "approval and lease tables accept their listed transitions (#807)" {
  local edge from to
  for edge in pending:granted pending:denied pending:expired granted:consumed granted:expired; do
    from=${edge%%:*}; to=${edge##*:}
    run ordo_contracts_transition approval "$from" "$to"
    [ "$status" -eq 0 ] || { echo "approval $from -> $to refused"; return 1; }
  done
  for edge in active:renewed active:released active:expired renewed:renewed renewed:released renewed:expired; do
    from=${edge%%:*}; to=${edge##*:}
    run ordo_contracts_transition lease "$from" "$to"
    [ "$status" -eq 0 ] || { echo "lease $from -> $to refused"; return 1; }
  done
}

@test "invalid transitions exit 5 with an invalid_transition error listing the allowed targets (#807)" {
  run --separate-stderr ordo_contracts_transition run queued running
  [ "$status" -eq 5 ]
  [ -z "$output" ]
  assert_error_line invalid_transition
  [ "$(printf '%s' "$stderr" | jq -r '.error.details.table')" = "run" ]
  [ "$(printf '%s' "$stderr" | jq -r '.error.details.from')" = "queued" ]
  [ "$(printf '%s' "$stderr" | jq -r '.error.details.to')" = "running" ]
  [ "$(printf '%s' "$stderr" | jq -c '.error.details.allowed')" = '["leased","cancelled","expired"]' ]
  [ "$(printf '%s' "$stderr" | jq -r '.error.details.terminal')" = "false" ]

  run --separate-stderr ordo_contracts_transition approval pending consumed
  [ "$status" -eq 5 ]
  assert_error_line invalid_transition
  run --separate-stderr ordo_contracts_transition lease released active
  [ "$status" -eq 5 ]
  assert_error_line invalid_transition
  [ "$(printf '%s' "$stderr" | jq -r '.error.details.terminal')" = "true" ]
}

@test "terminal states have no outgoing transition, including to themselves (#807)" {
  local state to
  for state in succeeded failed cancelled expired; do
    for to in queued leased running waiting blocked approval_required succeeded failed cancelled expired; do
      run --separate-stderr ordo_contracts_transition run "$state" "$to"
      [ "$status" -eq 5 ] || { echo "$state -> $to accepted"; return 1; }
      [ "$(printf '%s' "$stderr" | jq -r '.error.details.terminal')" = "true" ]
    done
  done
  for state in denied consumed expired; do
    run ordo_contracts_transition approval "$state" pending
    [ "$status" -eq 5 ]
  done
  for state in released expired; do
    run ordo_contracts_transition lease "$state" renewed
    [ "$status" -eq 5 ]
  done
}

@test "non-terminal run states never self-transition (#807)" {
  local state
  for state in queued leased running waiting blocked approval_required; do
    run ordo_contracts_transition run "$state" "$state"
    [ "$status" -eq 5 ] || { echo "$state -> $state accepted"; return 1; }
  done
}

@test "transition refuses unknown tables (2) and unknown states (5) with typed errors (#807)" {
  run --separate-stderr ordo_contracts_transition widgets a b
  [ "$status" -eq 2 ]
  assert_error_line unknown_table
  [ "$(printf '%s' "$stderr" | jq -c '.error.details.known')" = '["run","approval","lease"]' ]
  run --separate-stderr ordo_contracts_transition run queued paused
  [ "$status" -eq 5 ]
  assert_error_line unknown_state
  [ "$(printf '%s' "$stderr" | jq -r '.error.details.state')" = "paused" ]
  run --separate-stderr ordo_contracts_transition run queued
  [ "$status" -eq 2 ]
  assert_error_line usage
}

@test "is_terminal answers 0/1 for every table and rejects unknown states (#807)" {
  local state
  for state in succeeded failed cancelled expired; do
    run ordo_contracts_is_terminal run "$state"; [ "$status" -eq 0 ]
  done
  for state in queued leased running waiting blocked approval_required; do
    run ordo_contracts_is_terminal run "$state"; [ "$status" -eq 1 ]
  done
  for state in denied consumed expired; do
    run ordo_contracts_is_terminal approval "$state"; [ "$status" -eq 0 ]
  done
  for state in pending granted; do
    run ordo_contracts_is_terminal approval "$state"; [ "$status" -eq 1 ]
  done
  run ordo_contracts_is_terminal lease released; [ "$status" -eq 0 ]
  run ordo_contracts_is_terminal lease expired;  [ "$status" -eq 0 ]
  run ordo_contracts_is_terminal lease active;   [ "$status" -eq 1 ]
  run ordo_contracts_is_terminal lease renewed;  [ "$status" -eq 1 ]
  run --separate-stderr ordo_contracts_is_terminal run nope
  [ "$status" -eq 5 ]
  assert_error_line unknown_state
  run --separate-stderr ordo_contracts_is_terminal nope queued
  [ "$status" -eq 2 ]
  assert_error_line unknown_table
}

@test "transition tables print as JSON with exactly the documented state sets (#807)" {
  run ordo_contracts_transitions run
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -c 'keys')" = '["approval_required","blocked","cancelled","expired","failed","leased","queued","running","succeeded","waiting"]' ]
  run ordo_contracts_transitions approval
  [ "$(printf '%s' "$output" | jq -c 'keys')" = '["consumed","denied","expired","granted","pending"]' ]
  run ordo_contracts_transitions lease
  [ "$(printf '%s' "$output" | jq -c 'keys')" = '["active","expired","released","renewed"]' ]
  # Every transition target is itself a known state of the same table.
  local table
  for table in run approval lease; do
    ordo_contracts_transitions "$table" | jq -e '. as $t | [.[][]] | all(. as $s | $t | has($s))' >/dev/null
  done
}

# --- redaction ---------------------------------------------------------------

@test "redact masks secret-looking keys at any depth, case-insensitively (#807)" {
  local out
  out=$(ordo_contracts_redact '{"GITHUB_TOKEN":"a","nested":{"Api-Key":"b","api_key":"c","apikey":"d","Authorization":"e","passwd":"f","Password":"g","cookie":"h","client_secret":"i","keep":"plain"},"list":[{"token":"j"}]}')
  [ "$(printf '%s' "$out" | jq -r '.GITHUB_TOKEN')" = "[REDACTED]" ]
  local key
  for key in Api-Key api_key apikey Authorization passwd Password cookie client_secret; do
    [ "$(printf '%s' "$out" | jq -r --arg k "$key" '.nested[$k]')" = "[REDACTED]" ] || { echo "$key not redacted"; return 1; }
  done
  [ "$(printf '%s' "$out" | jq -r '.nested.keep')" = "plain" ]
  [ "$(printf '%s' "$out" | jq -r '.list[0].token')" = "[REDACTED]" ]
  # Keys are kept (shape preserved) so a redacted object still validates.
  [ "$(printf '%s' "$out" | jq -r '.nested | keys | length')" -eq 9 ]
}

@test "redact masks token-looking values wherever they appear (#807)" {
  local out
  out=$(ordo_contracts_redact '{"note":"use ghp_abcdefghijklmnopqrstuvwxyz1234 then sk-ABCDEFGHIJKLMNOPQRSTUVWXYZ","hdr":"Bearer abc.def-ghi_jkl123456789012345","arr":["ghs_ABCDEFGHIJKLMNOPQRSTUV",{"deep":"gho_abcdefghijklmnopqrstuvwxyz"}],"short":"ghp_short sk-short Bearer short","n":42,"b":true,"z":null}')
  [ "$(printf '%s' "$out" | jq -r '.note')" = "use [REDACTED] then [REDACTED]" ]
  [ "$(printf '%s' "$out" | jq -r '.hdr')" = "[REDACTED]" ]
  [ "$(printf '%s' "$out" | jq -r '.arr[0]')" = "[REDACTED]" ]
  [ "$(printf '%s' "$out" | jq -r '.arr[1].deep')" = "[REDACTED]" ]
  [ "$(printf '%s' "$out" | jq -r '.short')" = "ghp_short sk-short Bearer short" ]
  [ "$(printf '%s' "$out" | jq -c '{n,b,z}')" = '{"n":42,"b":true,"z":null}' ]
}

@test "redact output is valid JSON, idempotent, keeps a valid contract valid, and rejects bad input (#807)" {
  local obj once twice
  obj=$(jq -c '.metadata = {"github_token": "ghp_abcdefghijklmnopqrstuvwxyz1234", "note": "Bearer abcdefghijklmnopqrstuvwxyz"}' "$FIXTURES/run.valid.json")
  once=$(ordo_contracts_redact "$obj")
  twice=$(ordo_contracts_redact "$once")
  [ "$once" = "$twice" ]
  [ "$(printf '%s' "$once" | jq -r '.metadata.github_token')" = "[REDACTED]" ]
  [ "$(printf '%s' "$once" | jq -r '.metadata.note')" = "[REDACTED]" ]
  run ordo_contracts_validate run "$once"
  [ "$status" -eq 0 ]
  run --separate-stderr ordo_contracts_redact '{oops'
  [ "$status" -eq 5 ]
  assert_error_line invalid_json
  run bash -c "source '$TK/lib/ordo_contracts.sh'; printf '%s' '$obj' | ordo_contracts_redact - | jq -r .metadata.github_token"
  [ "$output" = "[REDACTED]" ]
}

@test "valid fixtures carry nothing the redactor would mask (#807)" {
  local f
  for f in "$FIXTURES"/*.valid.json; do
    [ "$(ordo_contracts_redact "@$f")" = "$(jq -c . "$f")" ] || { echo "fixture $f contains secret-looking data"; return 1; }
  done
}

# --- error helper and exit codes --------------------------------------------

@test "error helper prints one JSON line on stderr and returns the mapped exit code (#807)" {
  local pair code expected
  for pair in ok:0 generic_failure:1 internal_error:1 usage:2 bad_argument:2 unknown_kind:2 unknown_table:2 \
              refused:3 policy_refused:3 fail_closed:3 not_found:4 \
              invalid_state:5 invalid_transition:5 invalid_contract:5 invalid_json:5 unknown_state:5 conflict:5 duplicate_event:5 \
              missing_dependency:6 not_implemented:6 provider_not_available:6 budget_exhausted:7 lease_lost:8 lease_stale:8
  do
    code=${pair%%:*}; expected=${pair##*:}
    run --separate-stderr ordo_contracts_error demo_module "$code" "human message" '{"k":"v"}'
    [ "$status" -eq "$expected" ] || { echo "$code mapped to $status, expected $expected"; return 1; }
    [ -z "$output" ]
    [ "$(printf '%s\n' "$stderr" | grep -c .)" -eq 1 ]
    [ "$(printf '%s' "$stderr" | jq -c '.error')" = "{\"code\":\"$code\",\"message\":\"human message\",\"module\":\"demo_module\",\"details\":{\"k\":\"v\"}}" ]
    [ "$(ordo_contracts_exit_code "$code")" = "$expected" ]
  done
}

@test "error helper defaults details to {}, wraps non-object details, and maps unknown codes to 1 (#807)" {
  run --separate-stderr ordo_contracts_error demo refused "no details"
  [ "$status" -eq 3 ]
  [ "$(printf '%s' "$stderr" | jq -c '.error.details')" = '{}' ]
  run --separate-stderr ordo_contracts_error demo refused "scalar details" '"just a string"'
  [ "$(printf '%s' "$stderr" | jq -c '.error.details')" = '{"value":"just a string"}' ]
  run --separate-stderr ordo_contracts_error demo refused "raw details" 'not json at all'
  [ "$(printf '%s' "$stderr" | jq -c '.error.details')" = '{"raw":"not json at all"}' ]
  run --separate-stderr ordo_contracts_error demo something_new "unmapped"
  [ "$status" -eq 1 ]
  [ "$(ordo_contracts_exit_code something_new)" = "1" ]
}

@test "exit-code map matches the brief's table (#807)" {
  local map
  map=$(ordo_contracts_exit_codes)
  printf '%s' "$map" | jq -e '
    .ok == 0 and .generic_failure == 1 and .usage == 2 and .refused == 3 and .not_found == 4
    and .invalid_state == 5 and .missing_dependency == 6 and .budget_exhausted == 7 and .lease_lost == 8
    and ([.[]] | all(. >= 0 and . <= 8))' >/dev/null
}

# --- schemas and emit.sh -----------------------------------------------------

@test "schema prints a versioned JSON-Schema-like document for every kind (#807)" {
  local kind schema
  for kind in $KINDS; do
    schema=$(ordo_contracts_schema "$kind")
    printf '%s' "$schema" | jq -e --arg kind "$kind" '
      .["$schema"] == "https://json-schema.org/draft/2020-12/schema"
      and (.["$id"] | endswith("/contracts/v1/" + $kind + ".schema.json"))
      and .["x-ordo-kind"] == $kind
      and .["x-ordo-schema-version"] == "1"
      and .type == "object"
      and .additionalProperties == true
      and (.required | index(["schema_version"]) != null and index(["kind"]) != null and index(["id"]) != null
           and index(["created_at"]) != null and index(["correlation_id"]) != null and index(["actor"]) != null)
      and .properties.kind.const == $kind
      and .properties.schema_version.const == "1"
      and (.properties.id.pattern == ("^" + $kind + "_[0-9a-f]{24}$"))
      and .properties.actor.properties.type.enum == ["operator","agent","system","model"]
      and (.description | length > 0)' >/dev/null || { echo "schema shape wrong for $kind"; return 1; }
  done
  run --separate-stderr ordo_contracts_schema widget
  [ "$status" -eq 2 ]
  assert_error_line unknown_kind
}

@test "schemas encode the state enums and the idempotency rules (#807)" {
  [ "$(ordo_contracts_schema run | jq -c '.properties.state.enum')" = '["queued","leased","running","waiting","blocked","approval_required","succeeded","failed","cancelled","expired"]' ]
  [ "$(ordo_contracts_schema task | jq -c '.properties.state.enum')" = "$(ordo_contracts_schema attempt | jq -c '.properties.state.enum')" ]
  [ "$(ordo_contracts_schema approval | jq -c '.properties.state.enum')" = '["pending","granted","denied","consumed","expired"]' ]
  [ "$(ordo_contracts_schema lease | jq -c '.properties.state.enum')" = '["active","renewed","released","expired"]' ]
  ordo_contracts_schema approval | jq -e '.required | index(["idempotency_key"]) != null' >/dev/null
  ordo_contracts_schema event | jq -e '.allOf[0].if.properties.mutation.const == true and .allOf[0].then.required == ["idempotency_key"]' >/dev/null
  ordo_contracts_schema policy_decision | jq -e '.properties.decision.enum == ["allow","deny","require_approval"]' >/dev/null
}

@test "contracts/v1/emit.sh stays in sync with the library (#807)" {
  [ -x "$EMIT" ]
  local kind
  for kind in $KINDS; do
    [ "$(bash "$EMIT" schema "$kind" | jq -cS .)" = "$(ordo_contracts_schema "$kind" | jq -cS .)" ] || { echo "emit.sh schema drift for $kind"; return 1; }
  done
  [ "$(bash "$EMIT" kinds | tr '\n' ' ' | sed 's/ $//')" = "$KINDS" ]
  [ "$(bash "$EMIT" tables | tr '\n' ' ')" = "run approval lease " ]
  [ "$(bash "$EMIT" schemas | jq -r 'keys | length')" -eq 10 ]
  [ "$(bash "$EMIT" schemas | jq -cS '.event')" = "$(ordo_contracts_schema event | jq -cS .)" ]
  [ "$(bash "$EMIT" transitions lease | jq -cS .)" = "$(ordo_contracts_transitions lease | jq -cS .)" ]
  [ "$(bash "$EMIT" exit-codes | jq -cS .)" = "$(ordo_contracts_exit_codes | jq -cS .)" ]
  [[ "$(bash "$EMIT" new-id lease)" =~ ^lease_[0-9a-f]{24}$ ]]
  [[ "$(bash "$EMIT" now)" =~ Z$ ]]
}

@test "contracts/v1/emit.sh validate, redact and write-schemas follow the exit-code contract (#807)" {
  run --separate-stderr bash "$EMIT" validate run "@$FIXTURES/run.valid.json"
  [ "$status" -eq 0 ]
  run --separate-stderr bash "$EMIT" validate run "@$FIXTURES/run.invalid.json"
  [ "$status" -eq 5 ]
  assert_error_line invalid_contract
  run --separate-stderr bash "$EMIT" redact '{"password":"x"}'
  [ "$status" -eq 0 ]
  [ "$output" = '{"password":"[REDACTED]"}' ]
  run --separate-stderr bash "$EMIT" frobnicate
  [ "$status" -eq 2 ]
  assert_error_line unknown_command
  run --separate-stderr bash "$EMIT"
  [ "$status" -eq 2 ]
  run bash "$EMIT" write-schemas "$BATS_TEST_TMPDIR/schemas"
  [ "$status" -eq 0 ]
  [ "$(find "$BATS_TEST_TMPDIR/schemas" -name '*.schema.json' | wc -l)" -eq 10 ]
  [ "$(jq -cS . "$BATS_TEST_TMPDIR/schemas/blocker.schema.json")" = "$(ordo_contracts_schema blocker | jq -cS .)" ]
}
