#!/usr/bin/env bats
# tests/ordo_approval.bats — approval-safe actions (#812, epic #806).
#
# Covers lib/ordo_approval.sh against the journal and the fake provider adapter:
#   - request persists a typed approval tied to run, action, principal, policy
#     version and expiry (with a pinned payload); usage / not-found / terminal run;
#   - grant/deny: operator decides, a model actor is refused (exit 3) with a
#     policy_decision recorded; bare --by ids become operator actors;
#   - expiry sweep (approval.expired journaled) and expired-at-grant;
#   - the bridge re-authorizes immediately before execution: expired NOW,
#     policy-version drift, principal not allowed, model executor, terminal run,
#     not granted, action mismatch, pinned-payload mismatch => exit 3 + deny decision;
#   - happy path through ordo_provider (fake): receipt, consumed with result,
#     mutation journaled with the idempotency key, spans emitted;
#   - replay: a second authorize_and_run returns details.replayed=true and the
#     fake adapter's mutations.jsonl still holds one line;
#   - the mutation gate stays authoritative: without ORCH_EXTERNAL_PR_MUTATIONS the
#     provider refuses and the approval stays granted;
#   - exit codes 2 / 3 / 4 / 5.

bats_require_minimum_version 1.5.0

load './helpers.bash'

setup() {
  setup_orch_test
  export FAKE_FIXTURES="$TK/tests/fixtures/adapters/fake"
  export ORDO_FAKE_ADAPTER_DIR="$BATS_TEST_TMPDIR/fake"
  cp -R "$FAKE_FIXTURES" "$ORDO_FAKE_ADAPTER_DIR"
  export ORDO_PROVIDER_ADAPTER=fake
  export ORDO_FORGE_REPO="acme/widgets"
  export ORCH_EXTERNAL_PR_MUTATIONS="pr_merge"
  export ORDO_APPROVAL_PRINCIPALS="eric=pr.merge|issue.comment"
  export ORDO_POLICY_VERSION="policy-v1"
  export ORDO_JOURNAL_NOW="2026-09-11T10:00:00Z"
  export ORDO_JOURNAL_FAULT=""
  unset ORDO_ACTOR ORDO_TRACE_ID ORDO_TRACE_PARENT_SPAN ORDO_RUN_ID GH_REPO
  export ORDO_OPERATOR="eric"
  # shellcheck disable=SC1090
  source "$TK/lib/audit_log.sh"
  # shellcheck disable=SC1090
  source "$TK/lib/state_persist.sh"
  set +e
  # shellcheck disable=SC1090
  source "$TK/lib/ordo_approval.sh"
  ordo_journal_init >/dev/null
  RUN=$(ordo_contracts_new_id run)
  export RUN
  ordo_journal_append "$RUN" run.created '{"title":"Widget","ticket_ref":"acme/widgets#42","project":"demo"}' >/dev/null
  ordo_journal_append "$RUN" run.leased '{"lease_id":"lease_000000000000000000000001"}' >/dev/null
  ordo_journal_append "$RUN" run.started '{}' >/dev/null
}

assert_error_line() {
  local code="$1" module="${2:-approval}"
  [ "$(printf '%s\n' "$stderr" | grep -c .)" -eq 1 ] || { echo "stderr: $stderr"; return 1; }
  [ "$(printf '%s' "$stderr" | jq -r '.error.code')" = "$code" ] || { echo "stderr: $stderr"; return 1; }
  [ "$(printf '%s' "$stderr" | jq -r '.error.module')" = "$module" ] || { echo "stderr: $stderr"; return 1; }
  printf '%s' "$stderr" | jq -e '.error.details | type == "object"' >/dev/null
}

assert_refused() {
  # <reason>: exit 3 policy_refused whose details.reason matches, plus a deny decision journaled.
  local reason="$1"
  [ "$status" -eq 3 ] || { echo "status=$status stderr=$stderr"; return 1; }
  assert_error_line policy_refused
  [ "$(printf '%s' "$stderr" | jq -r '.error.details.reason')" = "$reason" ] || { echo "stderr: $stderr"; return 1; }
  [ -z "$output" ]
  local decision
  decision=$(ordo_journal_events "$RUN" | jq -c 'select(.type == "policy.decided") | .payload' | tail -n 1)
  [ -n "$decision" ]
  ordo_contracts_validate policy_decision "$decision"
  [ "$(jq -r '.decision' <<<"$decision")" = "deny" ]
  [ "$(jq -c '.reasons' <<<"$decision")" = "[\"$reason\"]" ]
  [ "$(jq -r '.policy' <<<"$decision")" = "approval_bridge" ]
}

mutations_count() {
  if [[ -f "$ORDO_FAKE_ADAPTER_DIR/mutations.jsonl" ]]; then wc -l < "$ORDO_FAKE_ADAPTER_DIR/mutations.jsonl" | tr -d ' '; else printf '0\n'; fi
}

request_merge() {
  ordo_approval_request "$RUN" pr.merge --principal eric --idempotency-key "merge-42-${BATS_TEST_NUMBER}" --ttl 600 "$@" | jq -r '.id'
}

granted_merge() {
  local id
  id=$(request_merge "$@")
  ordo_approval_grant "$id" --by eric --reason "reviewed" >/dev/null
  printf '%s\n' "$id"
}

# --- request --------------------------------------------------------------------

@test "request persists a typed approval tied to run, action, principal, policy version and expiry (#812)" {
  run ordo_approval_request "$RUN" pr.merge --principal eric --idempotency-key merge-42 --ttl 600 --payload '{"args":["42","--method","squash"],"note":"token=ghp_FAKE0123456789abcdefghijklmnopqrstuv"}'
  [ "$status" -eq 0 ]
  local approval="$output" id
  id=$(jq -r '.id' <<<"$approval")
  [[ "$id" =~ ^approval_[0-9a-f]{24}$ ]]
  ordo_contracts_validate approval "$(jq -c 'del(.payload)' <<<"$approval")"
  [ "$(jq -r '.run_id' <<<"$approval")" = "$RUN" ]
  [ "$(jq -r '.action' <<<"$approval")" = "pr.merge" ]
  [ "$(jq -r '.principal' <<<"$approval")" = "eric" ]
  [ "$(jq -r '.policy_version' <<<"$approval")" = "policy-v1" ]
  [ "$(jq -r '.state' <<<"$approval")" = "pending" ]
  [ "$(jq -r '.idempotency_key' <<<"$approval")" = "merge-42" ]
  [ "$(jq -r '.expires_at' <<<"$approval")" = "2026-09-11T10:10:00Z" ]
  [ "$(jq -r '.actor.type' <<<"$approval")" = "operator" ]
  [ "$(jq -c '.payload.args' <<<"$approval")" = '["42","--method","squash"]' ]
  # The payload is redacted before it is journaled.
  [ "$(jq -r '.payload.note' <<<"$approval")" = "token=[REDACTED]" ]
  ! grep -q ghp_FAKE "$(ordo_journal_db_path)"
  [ "$(ordo_approval_get "$id" | jq -c '.payload.args')" = '["42","--method","squash"]' ]
  [ "$(ordo_approval_list "$RUN" --state pending | jq -r '.id')" = "$id" ]
  [ "$(ordo_approval_list "$RUN" | jq -c '.payload.args')" = '["42","--method","squash"]' ]
  [ "$(ordo_journal_events "$RUN" | jq -r 'select(.type == "approval_bridge.requested") | .payload.approval_id')" = "$id" ]
  [ "$(ordo_journal_events "$RUN" | jq -r '.type' | tail -n 2 | paste -sd, -)" = "approval.requested,approval_bridge.requested" ]
  # Default TTL and computed policy version when nothing is pinned.
  unset ORDO_POLICY_VERSION
  run ordo_approval_request "$RUN" issue.comment --principal eric --idempotency-key comment-42
  [ "$status" -eq 0 ]
  [ "$(jq -r '.expires_at' <<<"$output")" = "2026-09-11T11:00:00Z" ]
  [[ "$(jq -r '.policy_version' <<<"$output")" =~ ^gate-[0-9a-f]{16}$ ]]
  [ "$(jq -r '.policy_version' <<<"$output")" = "$(ordo_approval_policy_version)" ]
}

@test "request refuses usage errors (2), unknown runs (4), duplicate keys and terminal runs (5) (#812)" {
  run --separate-stderr ordo_approval_request "$RUN" pr.merge --principal eric
  [ "$status" -eq 2 ]
  assert_error_line usage
  run --separate-stderr ordo_approval_request "$RUN" pr.merge --idempotency-key k
  [ "$status" -eq 2 ]
  assert_error_line usage
  run --separate-stderr ordo_approval_request "$RUN" pr.merge --principal eric --idempotency-key k --payload '[1]'
  [ "$status" -eq 5 ]
  assert_error_line invalid_json
  run --separate-stderr ordo_approval_request run_000000000000000000000000 pr.merge --principal eric --idempotency-key k
  [ "$status" -eq 4 ]
  assert_error_line not_found journal
  request_merge >/dev/null
  run --separate-stderr ordo_approval_request "$RUN" pr.merge --principal eric --idempotency-key "merge-42-${BATS_TEST_NUMBER}"
  [ "$status" -eq 5 ]
  assert_error_line conflict journal
  ordo_journal_append "$RUN" run.cancelled '{"reason":"test"}' >/dev/null
  run --separate-stderr ordo_approval_request "$RUN" pr.merge --principal eric --idempotency-key other
  [ "$status" -eq 5 ]
  assert_error_line invalid_state
  [ "$(printf '%s' "$stderr" | jq -r '.error.details.state')" = "cancelled" ]
}

# --- grant / deny ----------------------------------------------------------------

@test "operators grant and deny; decided_by is recorded; a bare --by id is an operator (#812)" {
  local id
  id=$(request_merge)
  run ordo_approval_grant "$id" --by eric --reason "reviewed the diff"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.state' <<<"$output")" = "granted" ]
  [ "$(jq -c '.decided_by' <<<"$output")" = '{"type":"operator","id":"eric"}' ]
  [ "$(jq -r '.reason' <<<"$output")" = "reviewed the diff" ]
  [ "$(jq -r '.decided_at' <<<"$output")" = "2026-09-11T10:00:00Z" ]
  ordo_contracts_validate approval "$(jq -c 'del(.payload)' <<<"$output")"
  # The allow decision is journaled next to the approval.granted event.
  [ "$(ordo_journal_events "$RUN" | jq -r 'select(.type == "policy.decided") | .payload.decision' | tail -n 1)" = "allow" ]
  [ "$(ordo_journal_events "$RUN" | jq -r 'select(.type == "approval.granted") | .actor.id')" = "eric" ]
  # Granting twice is an invalid state (5); denying a granted approval too.
  run --separate-stderr ordo_approval_grant "$id" --by eric
  [ "$status" -eq 5 ]
  assert_error_line invalid_state
  run --separate-stderr ordo_approval_deny "$id" --by eric
  [ "$status" -eq 5 ]
  assert_error_line invalid_state
  # Deny path with a JSON actor and the ORDO_ACTOR fallback.
  local second
  second=$(ordo_approval_request "$RUN" issue.comment --principal eric --idempotency-key comment-1 | jq -r '.id')
  run ordo_approval_deny "$second" --by '{"type":"system","id":"policy-bot"}' --reason "no"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.state' <<<"$output")" = "denied" ]
  [ "$(jq -c '.decided_by' <<<"$output")" = '{"type":"system","id":"policy-bot"}' ]
  local third
  third=$(ordo_approval_request "$RUN" issue.comment --principal eric --idempotency-key comment-2 | jq -r '.id')
  ORDO_ACTOR='{"type":"operator","id":"yan"}' run ordo_approval_grant "$third"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.decided_by.id' <<<"$output")" = "yan" ]
  # Unknown approval: 4; malformed id: 2; bad actor spec: 2.
  run --separate-stderr ordo_approval_grant approval_000000000000000000000000 --by eric
  [ "$status" -eq 4 ]
  assert_error_line not_found
  run --separate-stderr ordo_approval_grant nope --by eric
  [ "$status" -eq 2 ]
  assert_error_line bad_argument
  run --separate-stderr ordo_approval_grant "$id" --by 'robot:x:y'
  [ "$status" -eq 2 ]
  assert_error_line bad_argument
}

@test "a model actor can never grant: exit 3 with a policy_decision deny recorded (#812)" {
  local id
  id=$(request_merge)
  run --separate-stderr ordo_approval_grant "$id" --by model:gpt-5
  assert_refused actor_type_not_allowed
  [ "$(printf '%s' "$stderr" | jq -r '.error.details.actor_type')" = "model" ]
  run --separate-stderr ordo_approval_grant "$id" --by '{"type":"model","id":"claude"}'
  assert_refused actor_type_not_allowed
  ORDO_ACTOR='{"type":"model","id":"claude"}' run --separate-stderr ordo_approval_grant "$id"
  assert_refused actor_type_not_allowed
  # An agent actor may not grant either (only operator|system), but may deny.
  run --separate-stderr ordo_approval_grant "$id" --by agent:fleet-001
  assert_refused actor_type_not_allowed
  [ "$(ordo_approval_get "$id" | jq -r '.state')" = "pending" ]
  run --separate-stderr ordo_approval_deny "$id" --by model:gpt-5
  assert_refused actor_type_not_allowed
  run ordo_approval_deny "$id" --by agent:fleet-001 --reason withdrawn
  [ "$status" -eq 0 ]
  [ "$(jq -r '.state' <<<"$output")" = "denied" ]
}

@test "grant refuses when the policy version drifted since the request (#812)" {
  local id
  id=$(request_merge)
  export ORDO_POLICY_VERSION="policy-v2"
  run --separate-stderr ordo_approval_grant "$id" --by eric
  assert_refused policy_version_drift
  [ "$(printf '%s' "$stderr" | jq -r '.error.details.expected_policy_version')" = "policy-v1" ]
  [ "$(printf '%s' "$stderr" | jq -r '.error.details.current_policy_version')" = "policy-v2" ]
  [ "$(ordo_approval_get "$id" | jq -r '.state')" = "pending" ]
}

# --- expiry ---------------------------------------------------------------------

@test "sweep expires pending and granted approvals past expires_at and journals approval.expired (#812)" {
  local pending granted fresh
  pending=$(request_merge)
  granted=$(ordo_approval_request "$RUN" issue.comment --principal eric --idempotency-key c-1 --ttl 60 | jq -r '.id')
  ordo_approval_grant "$granted" --by eric >/dev/null
  fresh=$(ordo_approval_request "$RUN" issue.comment --principal eric --idempotency-key c-2 --ttl 7200 | jq -r '.id')
  run ordo_approval_sweep
  [ "$status" -eq 0 ]
  [ "$(jq -r '.count' <<<"$output")" = "0" ]
  export ORDO_JOURNAL_NOW="2026-09-11T10:10:00Z"
  run ordo_approval_sweep
  [ "$status" -eq 0 ]
  [ "$(jq -r '.count' <<<"$output")" = "2" ]
  [ "$(jq -r '.now' <<<"$output")" = "2026-09-11T10:10:00Z" ]
  [ "$(jq -r '.expired[] | .approval_id' <<<"$output" | sort | paste -sd, -)" = "$(printf '%s\n%s\n' "$pending" "$granted" | sort | paste -sd, -)" ]
  [ "$(jq -r '.expired[] | select(.approval_id == "'"$granted"'") | .was' <<<"$output")" = "granted" ]
  [ "$(ordo_approval_get "$pending" | jq -r '.state')" = "expired" ]
  [ "$(ordo_approval_get "$granted" | jq -r '.state')" = "expired" ]
  [ "$(ordo_approval_get "$fresh" | jq -r '.state')" = "pending" ]
  [ "$(ordo_journal_events "$RUN" | jq -r 'select(.type == "approval.expired") | .payload.approval_id' | sort | paste -sd, -)" = "$(printf '%s\n%s\n' "$pending" "$granted" | sort | paste -sd, -)" ]
  [ "$(ordo_journal_events "$RUN" | jq -r 'select(.type == "approval.expired") | .actor.id' | head -n1)" = "ordo_approval" ]
  # Idempotent: a second sweep finds nothing; --run-id scopes the sweep.
  run ordo_approval_sweep --run-id "$RUN"
  [ "$(jq -r '.count' <<<"$output")" = "0" ]
  # Granting an approval that expired meanwhile marks it expired (5).
  export ORDO_JOURNAL_NOW="2026-09-11T13:00:00Z"
  run --separate-stderr ordo_approval_grant "$fresh" --by eric
  [ "$status" -eq 5 ]
  assert_error_line invalid_state
  [ "$(ordo_approval_get "$fresh" | jq -r '.state')" = "expired" ]
}

# --- the bridge: refusals -----------------------------------------------------------

@test "bridge refuses an approval that expired between grant and execution (#812)" {
  local id
  id=$(granted_merge)
  export ORDO_JOURNAL_NOW="2026-09-11T10:10:00Z"
  run --separate-stderr ordo_approval_authorize_and_run "$id" -- pr_merge 42 --method squash
  assert_refused approval_expired
  [ "$(ordo_approval_get "$id" | jq -r '.state')" = "expired" ]
  [ "$(mutations_count)" = "0" ]
  [ "$(ordo_journal_events "$RUN" | jq -r 'select(.type == "policy.decided") | .payload.approval_id' | tail -n 1)" = "$id" ]
}

@test "bridge refuses when the policy version drifted after the grant (#812)" {
  local id
  id=$(granted_merge)
  export ORDO_POLICY_VERSION="policy-v2"
  run --separate-stderr ordo_approval_authorize_and_run "$id" -- pr_merge 42
  assert_refused policy_version_drift
  [ "$(ordo_approval_get "$id" | jq -r '.state')" = "granted" ]
  [ "$(mutations_count)" = "0" ]
  # The computed policy version changes with the gate configuration.
  unset ORDO_POLICY_VERSION
  local before after
  before=$(ordo_approval_policy_version)
  ORCH_EXTERNAL_PR_MUTATIONS="pr_merge,pr_comment" after=$(ordo_approval_policy_version)
  [ "$before" != "$after" ]
  ORDO_APPROVAL_PRINCIPALS="bob" after=$(ordo_approval_policy_version)
  [ "$before" != "$after" ]
  [ "$before" = "$(ordo_approval_policy_version)" ]
}

@test "bridge refuses a principal that is not allowed for the action (#812)" {
  local id
  id=$(granted_merge)
  export ORDO_APPROVAL_PRINCIPALS="bob=pr.merge,eric=issue.comment"
  run --separate-stderr ordo_approval_authorize_and_run "$id" -- pr_merge 42
  assert_refused principal_not_allowed
  [ "$(printf '%s' "$stderr" | jq -r '.error.details.principal')" = "eric" ]
  [ "$(mutations_count)" = "0" ]
  # Empty allow-list: the gate semantics decide (scope must be authorised).
  export ORDO_APPROVAL_PRINCIPALS=""
  export ORCH_EXTERNAL_PR_MUTATIONS="pr_comment"
  run --separate-stderr ordo_approval_authorize_and_run "$id" -- pr_merge 42
  assert_refused principal_not_allowed
  [ "$(printf '%s' "$stderr" | jq -r '.error.details.scope')" = "pr_merge" ]
  # Pure helper semantics.
  ORDO_APPROVAL_PRINCIPALS="eric=pr.merge|issue.comment" ordo_approval_principal_allowed eric pr_merge
  ORDO_APPROVAL_PRINCIPALS="eric" ordo_approval_principal_allowed eric anything
  ORDO_APPROVAL_PRINCIPALS="*=pr.comment" ordo_approval_principal_allowed anyone pr.comment
  ! ORDO_APPROVAL_PRINCIPALS="*=pr.comment" ordo_approval_principal_allowed anyone pr.merge
  ! ORDO_APPROVAL_PRINCIPALS="eric=pr.merge" ordo_approval_principal_allowed bob pr.merge
  ORDO_APPROVAL_PRINCIPALS="" ORCH_EXTERNAL_PR_MUTATIONS="pr_merge" ordo_approval_principal_allowed bob pr.merge pr_merge
  ! ORDO_APPROVAL_PRINCIPALS="" ORCH_EXTERNAL_PR_MUTATIONS="" ordo_approval_principal_allowed bob pr.merge pr_merge
}

@test "bridge refuses a model executor, a terminal run and an approval that is not granted (#812)" {
  local id
  id=$(granted_merge)
  run --separate-stderr ordo_approval_authorize_and_run "$id" --actor '{"type":"model","id":"claude"}' -- pr_merge 42
  assert_refused actor_type_not_allowed
  local pending
  pending=$(ordo_approval_request "$RUN" issue.comment --principal eric --idempotency-key c-9 | jq -r '.id')
  run --separate-stderr ordo_approval_authorize_and_run "$pending" -- issue_comment 42 --body hi
  assert_refused approval_not_granted
  ordo_approval_deny "$pending" --by eric >/dev/null
  run --separate-stderr ordo_approval_authorize_and_run "$pending" -- issue_comment 42 --body hi
  assert_refused approval_denied
  ordo_journal_append "$RUN" run.cancelled '{"reason":"operator stop"}' >/dev/null
  run --separate-stderr ordo_approval_authorize_and_run "$id" -- pr_merge 42
  assert_refused run_terminal
  [ "$(printf '%s' "$stderr" | jq -r '.error.details.run_state')" = "cancelled" ]
  [ "$(ordo_approval_get "$id" | jq -r '.state')" = "granted" ]
  [ "$(mutations_count)" = "0" ]
}

@test "bridge binds the provider op and the pinned payload to the approved action (#812)" {
  local id
  id=$(granted_merge --payload '{"args":["42","--method","squash"]}')
  run --separate-stderr ordo_approval_authorize_and_run "$id" -- issue_comment 42 --body hi
  assert_refused action_mismatch
  run --separate-stderr ordo_approval_authorize_and_run "$id" -- pr_merge 42 --method rebase
  assert_refused payload_mismatch
  [ "$(printf '%s' "$stderr" | jq -c '.error.details.given_args')" = '["42","--method","rebase"]' ]
  # Read ops are never approved mutations; caller-supplied keys are a usage error.
  local read_ok
  read_ok=$(ordo_approval_request "$RUN" pr.get --principal eric --idempotency-key get-1 | jq -r '.id')
  ordo_approval_grant "$read_ok" --by eric >/dev/null
  run --separate-stderr ordo_approval_authorize_and_run "$read_ok" -- pr_get 42
  assert_refused op_not_mutating
  run --separate-stderr ordo_approval_authorize_and_run "$id" -- pr_merge 42 --idempotency-key mine
  [ "$status" -eq 2 ]
  assert_error_line usage
  run --separate-stderr ordo_approval_authorize_and_run "$id"
  [ "$status" -eq 2 ]
  assert_error_line usage
  run --separate-stderr ordo_approval_authorize_and_run approval_000000000000000000000000 -- pr_merge 42
  [ "$status" -eq 4 ]
  assert_error_line not_found
  [ "$(mutations_count)" = "0" ]
}

# --- the bridge: execution, idempotency, gate ---------------------------------------

@test "happy path: the bridge executes through the provider with the approval's key, consumes the approval and traces it (#812)" {
  local id key="merge-42-${BATS_TEST_NUMBER}"
  id=$(granted_merge --payload '{"args":["42","--method","squash"]}')
  run --separate-stderr ordo_approval_authorize_and_run "$id" --actor agent:fleet-001 -- pr_merge 42 --method squash
  [ "$status" -eq 0 ] || { echo "stderr: $stderr"; false; }
  local receipt="$output"
  [ "$(jq -r '.op' <<<"$receipt")" = "pr_merge" ]
  [ "$(jq -r '.adapter' <<<"$receipt")" = "fake" ]
  [ "$(jq -r '.approval_id' <<<"$receipt")" = "$id" ]
  [ "$(jq -r '.details.idempotency_key' <<<"$receipt")" = "$key" ]
  [ "$(jq -r '.details.replayed' <<<"$receipt")" = "false" ]
  [ "$(jq -r '.details.scope' <<<"$receipt")" = "pr_merge" ]
  [ "$(jq -r '.result.merged' <<<"$receipt")" = "true" ]
  # The provider saw exactly one mutation carrying the approval's key.
  [ "$(mutations_count)" = "1" ]
  [ "$(jq -r '.idempotency_key' "$ORDO_FAKE_ADAPTER_DIR/mutations.jsonl")" = "$key" ]
  [ "$(jq -r '.idempotency_key' "$(ordo_provider_adapter_ledger_file)")" = "$key" ]
  # The approval is consumed with the receipt recorded.
  local approval
  approval=$(ordo_approval_get "$id")
  [ "$(jq -r '.state' <<<"$approval")" = "consumed" ]
  [ "$(jq -r '.result.details.idempotency_key' <<<"$approval")" = "$key" ]
  [ "$(jq -c '.decided_by' <<<"$approval")" = '{"type":"agent","id":"fleet-001"}' ]
  ordo_contracts_validate approval "$(jq -c 'del(.payload)' <<<"$approval")"
  # Journal: allow decision, then approval.consumed, then the mutation event with the key.
  [ "$(ordo_journal_events "$RUN" | jq -r '.type' | tail -n 3 | paste -sd, -)" = "policy.decided,approval.consumed,approval_bridge.executed" ]
  local exec_event
  exec_event=$(ordo_journal_events "$RUN" | jq -c 'select(.type == "approval_bridge.executed")')
  [ "$(jq -r '.mutation' <<<"$exec_event")" = "true" ]
  [ "$(jq -r '.idempotency_key' <<<"$exec_event")" = "$key" ]
  [ "$(jq -r '.payload.replayed' <<<"$exec_event")" = "false" ]
  local decision
  decision=$(ordo_journal_events "$RUN" | jq -c 'select(.type == "policy.decided") | .payload' | tail -n 1)
  [ "$(jq -r '.decision' <<<"$decision")" = "allow" ]
  [ "$(jq -r '.subject' <<<"$decision")" = "execute:pr.merge:pr_merge" ]
  [ "$(jq -r '.approval_id' <<<"$decision")" = "$id" ]
  [ "$(jq -r '.metadata.scope' <<<"$decision")" = "pr_merge" ]
  # Spans: approval root, policy child, provider child, all ok, in one trace per run.
  local trace
  trace=$(ordo_trace_new_id trace "$RUN")
  [ -f "$(state_dir)/traces/$trace.jsonl" ]
  local spans
  spans=$(ordo_trace_spans "$trace")
  [ "$(printf '%s\n' "$spans" | jq -r '.name' | paste -sd, -)" = "approval.authorize,policy.reauthorize,provider.pr_merge" ]
  [ "$(printf '%s\n' "$spans" | jq -r '.kind' | paste -sd, -)" = "approval,policy,provider" ]
  [ "$(printf '%s\n' "$spans" | jq -r '.status.code' | sort -u)" = "OK" ]
  local root
  root=$(printf '%s\n' "$spans" | jq -r 'select(.name == "approval.authorize") | .span_id')
  [ "$(printf '%s\n' "$spans" | jq -r 'select(.name != "approval.authorize") | .parent_span_id' | sort -u)" = "$root" ]
  [ "$(printf '%s\n' "$spans" | jq -r 'select(.name == "policy.reauthorize") | .events[] | select(.name == "policy.decided") | .attributes["policy.decision"]')" = "allow" ]
  [ "$(printf '%s\n' "$spans" | jq -r 'select(.name == "provider.pr_merge") | .attributes["approval.idempotency_key"]')" = "$key" ]
  [ "$(printf '%s\n' "$spans" | jq -r 'select(.name == "approval.authorize") | .resource["ordo.run_id"]')" = "$RUN" ]
  ordo_trace_export "$trace" | jq -e '.resourceSpans[0].scopeSpans[0].spans | length == 3' >/dev/null
}

@test "replay: a second authorize_and_run returns the recorded receipt with replayed=true and never calls the provider (#812)" {
  local id
  id=$(granted_merge)
  run ordo_approval_authorize_and_run "$id" -- pr_merge 42
  [ "$status" -eq 0 ]
  [ "$(mutations_count)" = "1" ]
  local first="$output"
  run --separate-stderr ordo_approval_authorize_and_run "$id" -- pr_merge 42
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [ "$(jq -r '.details.replayed' <<<"$output")" = "true" ]
  [ "$(jq -r '.details.approval_id' <<<"$output")" = "$id" ]
  [ "$(jq -r '.details.idempotency_key' <<<"$output")" = "$(jq -r '.details.idempotency_key' <<<"$first")" ]
  [ "$(jq -c '.result' <<<"$output")" = "$(jq -c '.result' <<<"$first")" ]
  [ "$(mutations_count)" = "1" ]
  # Still one mutation event in the journal, no new policy decision, approval still consumed.
  [ "$(ordo_journal_events "$RUN" | jq -r 'select(.type == "approval_bridge.executed") | .id' | wc -l | tr -d ' ')" = "1" ]
  [ "$(ordo_journal_events "$RUN" | jq -r 'select(.type == "policy.decided") | .id' | wc -l | tr -d ' ')" = "2" ]
  [ "$(ordo_approval_get "$id" | jq -r '.state')" = "consumed" ]
  # Even a terminal run or a drifted policy replays without side effects.
  ordo_journal_append "$RUN" run.succeeded '{}' >/dev/null
  ORDO_POLICY_VERSION=policy-v9 run ordo_approval_authorize_and_run "$id" -- pr_merge 42
  [ "$status" -eq 0 ]
  [ "$(jq -r '.details.replayed' <<<"$output")" = "true" ]
  [ "$(mutations_count)" = "1" ]
}

@test "a replayed provider receipt (ledger hit) still consumes the approval (#812)" {
  local id key="merge-42-${BATS_TEST_NUMBER}"
  id=$(granted_merge)
  # The provider already executed this key outside the bridge (e.g. a crash after the mutation).
  ordo_provider pr_merge 42 --idempotency-key "$key" >/dev/null
  [ "$(mutations_count)" = "1" ]
  run ordo_approval_authorize_and_run "$id" -- pr_merge 42
  [ "$status" -eq 0 ]
  [ "$(jq -r '.details.replayed' <<<"$output")" = "true" ]
  [ "$(mutations_count)" = "1" ]
  [ "$(ordo_approval_get "$id" | jq -r '.state')" = "consumed" ]
  [ "$(ordo_journal_events "$RUN" | jq -r 'select(.type == "approval_bridge.executed") | .payload.replayed')" = "true" ]
}

@test "the mutation gate stays authoritative: without ORCH_EXTERNAL_PR_MUTATIONS the provider refuses and the approval stays granted (#812)" {
  local id
  id=$(granted_merge)
  unset ORCH_EXTERNAL_PR_MUTATIONS
  run --separate-stderr ordo_approval_authorize_and_run "$id" -- pr_merge 42
  [ "$status" -eq 3 ]
  [ "$(printf '%s' "$stderr" | jq -r '.error.code')" = "policy_refused" ]
  [ "$(printf '%s' "$stderr" | jq -r '.error.module')" = "provider_adapter" ]
  [ "$(printf '%s' "$stderr" | jq -r '.error.details.authorize_via')" = "ORCH_EXTERNAL_PR_MUTATIONS" ]
  [ "$(mutations_count)" = "0" ]
  [ "$(ordo_approval_get "$id" | jq -r '.state')" = "granted" ]
  local failed
  failed=$(ordo_journal_events "$RUN" | jq -c 'select(.type == "approval_bridge.execution_failed") | .payload')
  [ "$(jq -r '.exit_code' <<<"$failed")" = "3" ]
  [ "$(jq -r '.error.error.code' <<<"$failed")" = "policy_refused" ]
  # The allow decision of the bridge itself is still on record (the refusal came from the gate).
  [ "$(ordo_journal_events "$RUN" | jq -r 'select(.type == "policy.decided") | .payload.decision' | tail -n 1)" = "allow" ]
  local trace
  trace=$(ordo_trace_new_id trace "$RUN")
  [ "$(ordo_trace_spans "$trace" | jq -r 'select(.name == "provider.pr_merge") | .status.code')" = "ERROR" ]
  # Once the operator scopes the gate, the same approval executes.
  export ORCH_EXTERNAL_PR_MUTATIONS="pr_merge"
  run ordo_approval_authorize_and_run "$id" -- pr_merge 42
  [ "$status" -eq 0 ]
  [ "$(mutations_count)" = "1" ]
  [ "$(ordo_approval_get "$id" | jq -r '.state')" = "consumed" ]
}

# --- operator script -----------------------------------------------------------------

@test "scripts/ordo_approve.sh: request, grant, list, get, sweep, authorize-and-run and policy-version (#812)" {
  local cfg="$BATS_TEST_TMPDIR/project.config.sh"
  cat > "$cfg" <<EOF
PROJECT="$PROJECT"
GH_REPO="acme/widgets"
DEFAULT_BRANCH="main"
GH_CONFIG_DIR="$GH_CONFIG_DIR"
AGENT_REPO_PREFIX="$BATS_TEST_TMPDIR/repos/"
export AGENT_WORKDIR_TEMPLATE="$BATS_TEST_TMPDIR/repos/%s"
AGENT_PANES=("agent|agent:0.0|$BATS_TEST_TMPDIR/repos/agent")
EOF
  local script="$TK/scripts/ordo_approve.sh"
  run bash "$script" "$cfg" request "$RUN" pr.merge --principal eric --idempotency-key cli-1 --ttl 600 --json
  [ "$status" -eq 0 ]
  local id
  id=$(jq -r '.id' <<<"$output")
  [[ "$id" =~ ^approval_[0-9a-f]{24}$ ]]
  [ "$(jq -r '.state' <<<"$output")" = "pending" ]
  # The command word may come last (the ordo CLI appends it).
  run bash "$script" "$cfg" "$id" --by eric --reason ok grant --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.state' <<<"$output")" = "granted" ]
  [ "$(jq -c '.decided_by' <<<"$output")" = '{"type":"operator","id":"eric"}' ]
  run bash "$script" "$cfg" "$RUN" list --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.id' <<<"$output")" = "$id" ]
  run bash "$script" "$cfg" list "$RUN" --state granted
  [ "$status" -eq 0 ]
  [[ "$output" == "$id granted action=pr.merge principal=eric"* ]]
  run bash "$script" "$cfg" get "$id"
  [ "$status" -eq 0 ]
  [[ "$output" == "$id granted"*"by=operator:eric"*"reason=ok"* ]]
  run bash "$script" "$cfg" policy-version --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.policy_version' <<<"$output")" = "policy-v1" ]
  run bash "$script" "$cfg" authorize-and-run "$id" --json -- pr_merge 42 --method squash
  [ "$status" -eq 0 ]
  [ "$(jq -r '.details.replayed' <<<"$output")" = "false" ]
  [ "$(jq -r '.approval_id' <<<"$output")" = "$id" ]
  [ "$(mutations_count)" = "1" ]
  run bash "$script" "$cfg" authorize-and-run "$id" -- pr_merge 42 --method squash
  [ "$status" -eq 0 ]
  [[ "$output" == "executed pr_merge via fake approval=$id replayed=true key=cli-1" ]]
  [ "$(mutations_count)" = "1" ]
  run bash "$script" "$cfg" sweep --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.count' <<<"$output")" = "0" ]
  # Model grant through the script is refused with exit 3 and the error object.
  local second
  second=$(bash "$script" "$cfg" request "$RUN" issue.comment --principal eric --idempotency-key cli-2 --json | jq -r '.id')
  run --separate-stderr bash "$script" "$cfg" "$second" --by model:gpt grant
  [ "$status" -eq 3 ]
  [ "$(printf '%s' "$stderr" | jq -r '.error.code')" = "policy_refused" ]
  run --separate-stderr bash "$script" "$cfg" "$second" --by eric deny --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.state' <<<"$output")" = "denied" ]
  # Usage and lookup errors.
  run --separate-stderr bash "$script" "$cfg"
  [ "$status" -eq 2 ]
  [ "$(printf '%s' "$stderr" | tail -n 1 | jq -r '.error.code')" = "usage" ]
  run --separate-stderr bash "$script" "$cfg" get approval_000000000000000000000000
  [ "$status" -eq 4 ]
  [ "$(printf '%s' "$stderr" | jq -r '.error.code')" = "not_found" ]
  run --separate-stderr bash "$script" "$BATS_TEST_TMPDIR/missing.config.sh" list "$RUN"
  [ "$status" -eq 4 ]
  run bash "$script" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"authorize-and-run"* ]]
}
