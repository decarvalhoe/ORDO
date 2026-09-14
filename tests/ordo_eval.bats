#!/usr/bin/env bats
# tests/ordo_eval.bats — trajectory evaluation and failure-injection harness (#813, epic #806).
#
# Covers lib/ordo_eval.sh, scripts/ordo_eval.sh and tests/fixtures/eval/:
#   - every demo scenario (issue triage, PR merge with approval, blocked run,
#     budget exhaustion) runs green in the fake world and passes its expectations;
#   - every failure-injection scenario: process crash (kill before commit),
#     network timeout, provider outage, stale lease (dead owner + TTL), duplicate
#     delivery, approval expiry — each asserts the end state and that no
#     non-idempotent side effect repeated;
#   - replay determinism: two runs of one scenario are byte-identical (trajectory
#     digest and score card);
#   - the score card shape and the six dimensions, including negative cases
#     (unapproved mutation, repeated idempotency key, wrong end state);
#   - the committed baseline: `check` passes, `baseline` regenerates it
#     byte-for-byte, a regression is reported with a diff and exit 1;
#   - no gh/tmux/curl/ssh: a scenario runs with a PATH that has none of them,
#     the sandbox guard stubs refuse and record any call;
#   - exit codes 2 / 4 / 5 of the library and the operator script.
# The clock is pinned by the scenarios (ORDO_JOURNAL_NOW); nothing here sleeps.

bats_require_minimum_version 1.5.0

load './helpers.bash'

EVAL_SCENARIOS="pr_merge_approval issue_triage blocked_run budget_exhausted process_crash network_timeout provider_outage stale_lease duplicate_delivery approval_expiry"

setup_file() {
  export TK="${TK:-$(cd "$BATS_TEST_DIRNAME/.." && pwd)}"
  export EVAL_DEMO="$TK/tests/fixtures/eval/demo"
  export EVAL_FAIL="$TK/tests/fixtures/eval/failures"
  export EVAL_TRAJ="$BATS_FILE_TMPDIR/traj"
  mkdir -p "$EVAL_TRAJ"
  # Run every scenario once; the tests below read the stored trajectories and cards.
  # shellcheck disable=SC1090
  source "$TK/lib/ordo_eval.sh"
  local name path rc
  for name in $EVAL_SCENARIOS; do
    path=$(eval_scenario_path "$name")
    rc=0
    ordo_eval_run "$path" --out "$EVAL_TRAJ/$name" > "$EVAL_TRAJ/$name.summary" 2> "$EVAL_TRAJ/$name.stderr" || rc=$?
    printf '%s\n' "$rc" > "$EVAL_TRAJ/$name.rc"
    rc=0
    ordo_eval_score "$EVAL_TRAJ/$name" "$(ordo_eval_expected_for "$path")" > "$EVAL_TRAJ/$name.card" 2>> "$EVAL_TRAJ/$name.stderr" || rc=$?
    printf '%s\n' "$rc" > "$EVAL_TRAJ/$name.score_rc"
  done
}

eval_scenario_path() {
  local name="$1"
  if [[ -f "$EVAL_DEMO/$name.json" ]]; then printf '%s\n' "$EVAL_DEMO/$name.json"; else printf '%s\n' "$EVAL_FAIL/$name.json"; fi
}

setup() {
  setup_orch_test
  # shellcheck disable=SC1090
  source "$TK/lib/ordo_eval.sh"
}

assert_error_line() {
  local code="$1" module="${2:-eval}"
  [ "$(printf '%s\n' "$stderr" | grep -c .)" -eq 1 ] || { echo "stderr: $stderr"; return 1; }
  [ "$(printf '%s' "$stderr" | jq -r '.error.code')" = "$code" ] || { echo "stderr: $stderr"; return 1; }
  [ "$(printf '%s' "$stderr" | jq -r '.error.module')" = "$module" ] || { echo "stderr: $stderr"; return 1; }
  printf '%s' "$stderr" | jq -e '.error.details | type == "object"' >/dev/null
}

# assert_scenario_green <name>: the stored run exited 0 and its card passes.
assert_scenario_green() {
  local name="$1"
  [ "$(cat "$EVAL_TRAJ/$name.rc")" = "0" ] || { echo "run rc: $(cat "$EVAL_TRAJ/$name.rc")"; cat "$EVAL_TRAJ/$name.stderr"; return 1; }
  [ "$(cat "$EVAL_TRAJ/$name.score_rc")" = "0" ] || { echo "score rc: $(cat "$EVAL_TRAJ/$name.score_rc")"; jq -c '.dimensions | to_entries[] | select(.value.pass | not) | {(.key): .value.failures}' "$EVAL_TRAJ/$name.card"; return 1; }
  jq -e '.ok == true and .forbidden_calls == [] and .steps_executed == .steps_total' "$EVAL_TRAJ/$name/summary.json" >/dev/null
  jq -e '.pass == true and (.dimensions | to_entries | all(.value.pass))' "$EVAL_TRAJ/$name.card" >/dev/null
  # Every step matched its expected exit code and expectations.
  [ "$(jq -r 'select(.ok | not) | .index' "$EVAL_TRAJ/$name/steps.jsonl" | wc -l)" -eq 0 ]
}

steps() { jq -c "$2" "$EVAL_TRAJ/$1/steps.jsonl"; }
events() { jq -c "$2" "$EVAL_TRAJ/$1/events.jsonl"; }
event_types() { jq -r '.type' "$EVAL_TRAJ/$1/events.jsonl" | paste -sd, -; }
step_by_label() { jq -c --arg l "$2" "select(.label == \$l) | $3" "$EVAL_TRAJ/$1/steps.jsonl"; }
mutation_count() { grep -c . "$EVAL_TRAJ/$1/mutations.jsonl" || true; }
run_state() { jq -r --arg a "$2" '.[$a].state' "$EVAL_TRAJ/$1/runs.json"; }

# --- demo workload ------------------------------------------------------------

@test "demo: issue triage reads the forge and posts one approved comment; the run succeeds (#813)" {
  assert_scenario_green issue_triage
  [ "$(run_state issue_triage triage7)" = "succeeded" ]
  [ "$(mutation_count issue_triage)" -eq 1 ]
  [ "$(jq -r '.op' "$EVAL_TRAJ/issue_triage/mutations.jsonl")" = "issue_comment" ]
  [ "$(jq -r '.idempotency_key' "$EVAL_TRAJ/issue_triage/mutations.jsonl")" = "triage-acme-widgets-7" ]
  # The mutation is tied to a consumed approval with the same key and journaled once as mutation=true.
  [ "$(jq -r 'select(.state == "consumed") | .idempotency_key' "$EVAL_TRAJ/issue_triage/approvals.jsonl")" = "triage-acme-widgets-7" ]
  [ "$(events issue_triage 'select(.mutation == true) | .idempotency_key' | wc -l)" -eq 1 ]
  [ "$(jq -r '.metrics.tokens_used' "$EVAL_TRAJ/issue_triage.card")" = "1000" ]
}

@test "demo: PR merge with approval parks the run, an operator grants, the bridge executes once, evidence is captured (#813)" {
  assert_scenario_green pr_merge_approval
  [ "$(run_state pr_merge_approval merge12)" = "succeeded" ]
  [ "$(mutation_count pr_merge_approval)" -eq 1 ]
  [ "$(jq -r '.op + ":" + (.number | tostring)' "$EVAL_TRAJ/pr_merge_approval/mutations.jsonl")" = "pr_merge:12" ]
  # Parked runs hold no lease: the lease released before approval_required, a new one on resume.
  [[ "$(event_types pr_merge_approval)" == *"lease.released,run.approval_required"* ]]
  [[ "$(event_types pr_merge_approval)" == *"lease.acquired,run.resumed"* ]]
  # The operator (not a model) granted; the bridge recorded an allow decision with the full checklist.
  [ "$(events pr_merge_approval 'select(.type == "approval.granted") | .actor.type')" = '"operator"' ]
  [ "$(events pr_merge_approval 'select(.type == "policy.decided" and .payload.subject == "execute:pr.merge:pr_merge") | .payload.reasons | length')" = "7" ]
  # Evidence artifact: a contract artifact object whose file is in the trajectory with the recorded sha256.
  [ "$(grep -c . "$EVAL_TRAJ/pr_merge_approval/artifacts.jsonl")" -eq 1 ]
  local uri sum
  uri=$(jq -r '.uri' "$EVAL_TRAJ/pr_merge_approval/artifacts.jsonl")
  sum=$(jq -r '.sha256' "$EVAL_TRAJ/pr_merge_approval/artifacts.jsonl")
  [ -f "$EVAL_TRAJ/pr_merge_approval/$uri" ]
  [ "$(sha256sum "$EVAL_TRAJ/pr_merge_approval/$uri" | awk '{print $1}')" = "$sum" ]
  ordo_contracts_validate artifact "$(cat "$EVAL_TRAJ/pr_merge_approval/artifacts.jsonl")"
  # Spans of the bridge and of the harness share the run's trace.
  [ "$(jq -r '.trace_id' "$EVAL_TRAJ/pr_merge_approval/traces.jsonl" | sort -u | wc -l)" -eq 1 ]
  [ "$(jq -r 'select(.name == "provider.pr_merge") | .status.code' "$EVAL_TRAJ/pr_merge_approval/traces.jsonl")" = "OK" ]
}

@test "demo: a blocked run — fail-closed readiness, red CI, dependent run never starts, resume refused (#813)" {
  assert_scenario_green blocked_run
  [ "$(run_state blocked_run fix12)" = "blocked" ]
  [ "$(run_state blocked_run after12)" = "queued" ]
  [ "$(mutation_count blocked_run)" -eq 0 ]
  # First tick: skipped for readiness_unknown; later ticks: the dependent run skipped for its dependency.
  [ "$(step_by_label blocked_run "nothing is ready" '.result.skipped | map(.reason)')" = '["readiness_unknown","dependency_queued"]' ]
  [ "$(step_by_label blocked_run "fix12 starts, after12 waits on it" '.result.skipped[0].reason')" = '"dependency_running"' ]
  [ "$(step_by_label blocked_run "the dependent run stays queued" '.result.skipped[0].reason')" = '"dependency_blocked"' ]
  [ "$(steps blocked_run 'select(.op == "resume") | .rc')" = "3" ]
  [ "$(steps blocked_run 'select(.op == "resume") | .error.error.details.reason')" = '"readiness_unknown"' ]
  [ "$(jq -r '.fix12.counters.blockers_open' "$EVAL_TRAJ/blocked_run/runs.json")" = "1" ]
  [ "$(jq -r '.fix12.lease.state' "$EVAL_TRAJ/blocked_run/runs.json")" = "released" ]
}

@test "demo: budget exhaustion fails the run with exit 7 and releases its lease (#813)" {
  assert_scenario_green budget_exhausted
  [ "$(run_state budget_exhausted greedy)" = "failed" ]
  [ "$(steps budget_exhausted 'select(.op == "heartbeat") | .rc' | paste -sd, -)" = "0,7" ]
  [ "$(steps budget_exhausted 'select(.op == "heartbeat" and .rc == 7) | .error.error.details.exhausted')" = '["max_tokens"]' ]
  [ "$(jq -c '.greedy.budgets.exhausted' "$EVAL_TRAJ/budget_exhausted/runs.json")" = '["max_tokens"]' ]
  [ "$(jq -r '.greedy.budgets.tokens_used' "$EVAL_TRAJ/budget_exhausted/runs.json")" = "1200" ]
  [ "$(jq -r '.greedy.metadata.failure_reason' "$EVAL_TRAJ/budget_exhausted/runs.json")" = "budget_exhausted" ]
  [ "$(jq -c '.dimensions.cost.runs[0].exhausted' "$EVAL_TRAJ/budget_exhausted.card")" = '["max_tokens"]' ]
}

# --- failure injection --------------------------------------------------------

@test "failure: process crash before commit — replay executes the mutation once and completes the run (#813)" {
  assert_scenario_green process_crash
  [ "$(run_state process_crash merge12)" = "succeeded" ]
  # Both crashes were observed (inner step failed with the journal's internal_error).
  [ "$(steps process_crash 'select(.op == "crash") | .result.crashed' | paste -sd, -)" = "true,true" ]
  [ "$(steps process_crash 'select(.op == "crash") | .result.inner_error.error.code' | paste -sd, -)" = '"internal_error","internal_error"' ]
  # The merge happened exactly once (provider + ledger) and the replay came from the ledger.
  [ "$(mutation_count process_crash)" -eq 1 ]
  [ "$(grep -c . "$EVAL_TRAJ/process_crash/ledger.jsonl")" -eq 1 ]
  [ "$(steps process_crash 'select(.op == "execute") | .result.receipt.details.replayed')" = "true" ]
  [ "$(jq -r 'select(.state == "consumed") | .id' "$EVAL_TRAJ/process_crash/approvals.jsonl" | wc -l)" -eq 1 ]
  # The interrupted writes left no gap and no partial row: run_seq is gapless and every type appears once.
  [ "$(events process_crash '.run_seq' | tail -n 1)" = "$(events process_crash '.run_seq' | wc -l)" ]
  [ "$(events process_crash 'select(.type == "run.succeeded") | .run_seq' | wc -l)" -eq 1 ]
  [ "$(events process_crash 'select(.type == "approval.consumed") | .run_seq' | wc -l)" -eq 1 ]
  [ "$(jq -r '.metrics.deliveries' "$EVAL_TRAJ/process_crash.card")" = "2" ]
  [ "$(jq -r '.metrics.repeated_keys' "$EVAL_TRAJ/process_crash.card")" = "0" ]
}

@test "failure: network timeout — retryable errors, backoff on the pinned clock, recovery on the third attempt (#813)" {
  assert_scenario_green network_timeout
  [ "$(run_state network_timeout read12)" = "succeeded" ]
  local attempts
  attempts=$(steps network_timeout 'select(.op == "provider") | .result.attempts' | head -n 1)
  [ "$(jq 'length' <<<"$attempts")" = "3" ]
  [ "$(jq -c 'map(.rc)' <<<"$attempts")" = "[1,1,0]" ]
  [ "$(jq -c 'map(.retryable)' <<<"$attempts")" = "[true,true,false]" ]
  [ "$(jq -c 'map(.at)' <<<"$attempts")" = '["2026-09-11T10:00:00Z","2026-09-11T10:00:30Z","2026-09-11T10:01:00Z"]' ]
  # A non-retryable failure is not retried.
  [ "$(steps network_timeout 'select(.op == "provider" and .rc == 1) | .result.attempts | length')" = "1" ]
  [ "$(steps network_timeout 'select(.op == "provider" and .rc == 1) | .error.error.details.retryable')" = "false" ]
  # Retry spans: 3 attempts + 1 for the non-retryable call, the failed ones in error.
  [ "$(jq -r 'select(.name == "retry.attempt") | .status.code' "$EVAL_TRAJ/network_timeout/traces.jsonl" | paste -sd, -)" = "ERROR,ERROR,OK,ERROR" ]
  [ "$(events network_timeout 'select(.type == "provider.read") | .payload.attempts | length' | paste -sd, -)" = "3,1,1" ]
}

@test "failure: provider outage — the run parks waiting (no lease, slot freed), the forge recovers, the run resumes (#813)" {
  assert_scenario_green provider_outage
  [ "$(run_state provider_outage watch12)" = "succeeded" ]
  [ "$(run_state provider_outage next)" = "succeeded" ]
  [ "$(steps provider_outage 'select(.op == "provider" and .rc == 1) | .result.attempts | map(.error_code) | unique')" = '["provider_error"]' ]
  [ "$(steps provider_outage 'select(.op == "provider" and .rc == 1) | .result.attempts | map(.at) | join(",")')" = '"2026-09-11T10:00:00Z,2026-09-11T10:00:20Z,2026-09-11T10:00:40Z"' ]
  [ "$(steps provider_outage 'select(.op == "provider" and .rc == 1) | .error.error.details.http_status')" = "502" ]
  # Parked: lease released, wait deadline recorded; the next tick uses the freed slot for the other run.
  [ "$(steps provider_outage 'select(.op == "wait") | .result.state')" = '"waiting"' ]
  [ "$(steps provider_outage 'select(.op == "wait") | .result.wait_deadline')" = '"2026-09-11T11:00:00Z"' ]
  [ "$(step_by_label provider_outage "the freed slot goes to the next run" '.result.picked | length')" = "1" ]
  [ "$(events provider_outage 'select(.alias == "watch12" and .type == "run.waiting") | .payload.reason')" = '"provider outage (HTTP 502 x3)"' ]
  [ "$(mutation_count provider_outage)" -eq 0 ]
}

@test "failure: stale lease — a dead owner is reconciled by recover, an expired TTL is swept by the tick, attempts preserved (#813)" {
  assert_scenario_green stale_lease
  [ "$(run_state stale_lease job)" = "succeeded" ]
  [ "$(jq -r '.job.budgets.attempts_used' "$EVAL_TRAJ/stale_lease/runs.json")" = "3" ]
  # recover: owner_dead (dead pid), requeued without backoff.
  [ "$(steps stale_lease 'select(.op == "recover") | .result.reconciled[0].reason')" = '"owner_dead"' ]
  [ "$(steps stale_lease 'select(.op == "recover") | .result.reconciled[0].action')" = '"requeued"' ]
  # tick after the TTL: the lease is expired and the run requeued with a 60 s backoff (retries=1), then held by not_before.
  [ "$(step_by_label stale_lease "lease TTL elapsed => swept, requeued with backoff" '.result.expired_leases | length')" = "1" ]
  [ "$(step_by_label stale_lease "lease TTL elapsed => swept, requeued with backoff" '.result.requeued[0].backoff_seconds')" = "60" ]
  [ "$(step_by_label stale_lease "not_before holds the run back" '.result.skipped[0].reason')" = '"not_before"' ]
  [ "$(step_by_label stale_lease "third attempt" '.result.picked[0].attempt_no')" = "3" ]
  # Two distinct owners appear (the dead one and the live one), both normalised.
  [ "$(jq -r '.owner' "$EVAL_TRAJ/stale_lease/leases.jsonl" | sort -u | paste -sd, -)" = "eval@evalhost:100001,eval@evalhost:100002" ]
  [ "$(jq -r '.state' "$EVAL_TRAJ/stale_lease/leases.jsonl" | paste -sd, -)" = "released,expired,released" ]
  [ "$(mutation_count stale_lease)" -eq 0 ]
}

@test "failure: duplicate delivery — three deliveries of one idempotency key, one execution (#813)" {
  assert_scenario_green duplicate_delivery
  [ "$(run_state duplicate_delivery triage7)" = "succeeded" ]
  [ "$(mutation_count duplicate_delivery)" -eq 1 ]
  [ "$(grep -c . "$EVAL_TRAJ/duplicate_delivery/ledger.jsonl")" -eq 1 ]
  # steps.jsonl carries the idempotency key on deliveries only (execute / mutate / crash).
  [ "$(steps duplicate_delivery 'select(.idempotency_key != null) | .op' | paste -sd, -)" = '"execute","execute","mutate"' ]
  [ "$(steps duplicate_delivery 'select(.idempotency_key != null) | .result.delivery' | paste -sd, -)" = '"bridge","bridge","direct"' ]
  [ "$(steps duplicate_delivery 'select(.idempotency_key != null) | .result.receipt.details.replayed' | paste -sd, -)" = "false,true,true" ]
  [ "$(events duplicate_delivery 'select(.mutation == true) | .idempotency_key' | sort -u | wc -l)" -eq 1 ]
  [ "$(events duplicate_delivery 'select(.mutation == true) | .idempotency_key' | wc -l)" -eq 1 ]
  [ "$(jq -c '.dimensions.duplicate_side_effects | {mutations_executed, deliveries, replayed_deliveries, repeated_keys}' "$EVAL_TRAJ/duplicate_delivery.card")" = '{"mutations_executed":1,"deliveries":3,"replayed_deliveries":2,"repeated_keys":[]}' ]
}

@test "failure: approval expiry — a granted approval past its TTL is refused, marked expired, nothing executes (#813)" {
  assert_scenario_green approval_expiry
  [ "$(run_state approval_expiry merge12)" = "approval_required" ]
  [ "$(steps approval_expiry 'select(.op == "execute") | .rc')" = "3" ]
  [ "$(steps approval_expiry 'select(.op == "execute") | .error.error.details.reason')" = '"approval_expired"' ]
  [ "$(jq -r '.state' "$EVAL_TRAJ/approval_expiry/approvals.jsonl")" = "expired" ]
  [ "$(events approval_expiry 'select(.type == "policy.decided") | .payload | .decision + ":" + (.reasons | join(","))' | paste -sd, -)" = '"allow:actor_type_allowed,approval_pending,policy_version_match","deny:approval_expired"' ]
  [ "$(mutation_count approval_expiry)" -eq 0 ]
  [ "$(grep -c . "$EVAL_TRAJ/approval_expiry/ledger.jsonl")" -eq 0 ]
  [ "$(jq -c '.metrics | {mutations_executed, mutations_refused, policy_denials, deliveries}' "$EVAL_TRAJ/approval_expiry.card")" = '{"mutations_executed":0,"mutations_refused":1,"policy_denials":1,"deliveries":1}' ]
}

# --- determinism ----------------------------------------------------------------

@test "replay determinism: running a scenario twice yields byte-identical trajectories and score cards (#813)" {
  local again="$BATS_TEST_TMPDIR/again"
  ordo_eval_run "$EVAL_DEMO/pr_merge_approval.json" --out "$again" >/dev/null
  ordo_eval_digest "$EVAL_TRAJ/pr_merge_approval" > "$BATS_TEST_TMPDIR/d1"
  ordo_eval_digest "$again" > "$BATS_TEST_TMPDIR/d2"
  cmp "$BATS_TEST_TMPDIR/d1" "$BATS_TEST_TMPDIR/d2"
  local f
  for f in $ORDO_EVAL_TRAJECTORY_FILES evidence/merge12-01-pre-merge.txt; do
    cmp "$EVAL_TRAJ/pr_merge_approval/$f" "$again/$f"
  done
  ordo_eval_score "$again" "$EVAL_DEMO/pr_merge_approval.expected.json" > "$BATS_TEST_TMPDIR/card2"
  cmp "$EVAL_TRAJ/pr_merge_approval.card" "$BATS_TEST_TMPDIR/card2"
  # Normalisation: ids are counters in order of appearance; no sandbox path, no raw id, no real pid survives.
  [ "$(jq -r '.merge12.run_id' "$again/runs.json")" = "run_000000000000000000000001" ]
  run ! grep -rq "$BATS_TEST_TMPDIR" "$again" --exclude=idmap.json
  run ! grep -rqE '\b(run|lease|approval|event|attempt|policy_decision)_[0-9a-f]*[a-f][0-9a-f]*\b' "$again" --exclude=idmap.json
  [ "$(jq -r '.pids | length' "$again/idmap.json")" = "1" ]
  [ "$(jq -r '.idmap // empty' "$again/summary.json")" = "" ]
}

# --- score card -------------------------------------------------------------------

@test "score card: shape, six dimensions with pass/fail and numbers, exit 0 on pass (#813)" {
  run ordo_eval_score "$EVAL_TRAJ/issue_triage" "$EVAL_DEMO/issue_triage.expected.json"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.schema_version' <<<"$output")" = "1" ]
  [ "$(jq -r '.scenario' <<<"$output")" = "issue_triage" ]
  [ "$(jq -r '.dimensions | keys | join(",")' <<<"$output")" = "completion,cost,duplicate_side_effects,evidence_completeness,latency,policy_compliance" ]
  jq -e '.dimensions | to_entries | all((.value.pass | type) == "boolean" and (.value.failures | type) == "array")' <<<"$output" >/dev/null
  jq -e '.metrics | (.mutations_executed, .mutations_unapproved, .mutations_refused, .repeated_keys, .deliveries, .events_total, .spans_total, .artifacts, .elapsed_seconds, .attempts_used, .tokens_used, .seconds_used, .cost_used) | type == "number"' <<<"$output" >/dev/null
  [ "$(jq -c '.metrics.states' <<<"$output")" = '{"triage7":"succeeded"}' ]
  [ "$(jq -r '.dimensions.latency.elapsed_seconds' <<<"$output")" = "90" ]
  [ "$(jq -r '.dimensions.policy_compliance.mutations_approved' <<<"$output")" = "1" ]
  # Sorted keys, one document: a second scoring is byte-identical.
  run ordo_eval_score "$EVAL_TRAJ/issue_triage" "$EVAL_DEMO/issue_triage.expected.json"
  cmp <(printf '%s\n' "$output") "$EVAL_TRAJ/issue_triage.card"
}

@test "score card: a wrong end state, an unapproved mutation and a repeated key each fail their dimension with exit 1 (#813)" {
  local traj="$BATS_TEST_TMPDIR/traj" expected="$BATS_TEST_TMPDIR/expected.json"
  cp -R "$EVAL_TRAJ/issue_triage" "$traj"
  # Wrong end state.
  jq '.runs.triage7.state = "failed"' "$EVAL_DEMO/issue_triage.expected.json" > "$expected"
  run --separate-stderr ordo_eval_score "$traj" "$expected"
  [ "$status" -eq 1 ]
  [ "$(jq -r '.pass' <<<"$output")" = "false" ]
  [ "$(jq -r '.dimensions.completion.pass' <<<"$output")" = "false" ]
  [ "$(jq -r '.dimensions.completion.failures[0]' <<<"$output")" = "run triage7: expected failed, got succeeded" ]
  [ "$(jq -r '.dimensions.policy_compliance.pass' <<<"$output")" = "true" ]
  # A mutation the provider executed without any consumed approval, and not journaled.
  jq -c '.idempotency_key = "rogue-key" | .op = "issue_labels"' "$EVAL_TRAJ/issue_triage/mutations.jsonl" >> "$traj/mutations.jsonl"
  run --separate-stderr ordo_eval_score "$traj" "$EVAL_DEMO/issue_triage.expected.json"
  [ "$status" -eq 1 ]
  [ "$(jq -r '.dimensions.policy_compliance.pass' <<<"$output")" = "false" ]
  [ "$(jq -c '.dimensions.policy_compliance.unapproved_keys' <<<"$output")" = '["rogue-key"]' ]
  [ "$(jq -c '.dimensions.evidence_completeness.unjournaled_mutations' <<<"$output")" = '["rogue-key"]' ]
  [ "$(jq -r '.dimensions.duplicate_side_effects.failures[0]' <<<"$output")" = "expected 1 executed mutation(s), got 2" ]
  # The same key executed twice.
  cp "$EVAL_TRAJ/issue_triage/mutations.jsonl" "$traj/mutations.jsonl"
  cat "$EVAL_TRAJ/issue_triage/mutations.jsonl" >> "$traj/mutations.jsonl"
  run --separate-stderr ordo_eval_score "$traj" "$EVAL_DEMO/issue_triage.expected.json"
  [ "$status" -eq 1 ]
  [ "$(jq -r '.dimensions.duplicate_side_effects.pass' <<<"$output")" = "false" ]
  [ "$(jq -c '.dimensions.duplicate_side_effects.repeated_keys' <<<"$output")" = '["triage-acme-widgets-7"]' ]
  [ "$(jq -r '.metrics.repeated_keys' <<<"$output")" = "1" ]
  # Missing required event / span / artifact and a cost ceiling.
  jq '.evidence.events.triage7 += ["run.expired"] | .evidence.spans += ["provider.pr_merge"] | .evidence.artifacts = 2 | .cost.triage7.max_tokens = 10 | .latency.max_elapsed_seconds = 10' \
    "$EVAL_DEMO/issue_triage.expected.json" > "$expected"
  run --separate-stderr ordo_eval_score "$EVAL_TRAJ/issue_triage" "$expected"
  [ "$status" -eq 1 ]
  [ "$(jq -c '.dimensions.evidence_completeness.required_events[0].missing' <<<"$output")" = '["run.expired"]' ]
  [ "$(jq -c '.dimensions.evidence_completeness.missing_spans' <<<"$output")" = '["provider.pr_merge"]' ]
  [ "$(jq -r '.dimensions.evidence_completeness.failures | length' <<<"$output")" = "3" ]
  [ "$(jq -r '.dimensions.cost.failures[0]' <<<"$output")" = "run triage7: tokens 1000 > 10" ]
  [ "$(jq -r '.dimensions.latency.failures[0]' <<<"$output")" = "elapsed 90s > 10s" ]
  # A model actor deciding is always a violation.
  cp -R "$EVAL_TRAJ/issue_triage" "$BATS_TEST_TMPDIR/model"
  jq -c 'if .type == "approval.granted" then .actor = {"type":"model","id":"llm"} else . end' "$EVAL_TRAJ/issue_triage/events.jsonl" > "$BATS_TEST_TMPDIR/model/events.jsonl"
  run --separate-stderr ordo_eval_score "$BATS_TEST_TMPDIR/model" "$EVAL_DEMO/issue_triage.expected.json"
  [ "$status" -eq 1 ]
  [ "$(jq -r '.dimensions.policy_compliance.model_decisions' <<<"$output")" = "1" ]
}

# --- baseline ---------------------------------------------------------------------

@test "baseline: the committed demo baseline is what the baseline command regenerates, and check passes against it (#813)" {
  [ -f "$EVAL_DEMO/baseline.json" ]
  local regenerated="$BATS_TEST_TMPDIR/baseline.json"
  run bash "$TK/scripts/ordo_eval.sh" baseline --out "$regenerated"
  [ "$status" -eq 0 ]
  cmp "$regenerated" "$EVAL_DEMO/baseline.json"
  [ "$(jq -r '.scenarios | keys | join(",")' "$regenerated")" = "blocked_run,budget_exhausted,issue_triage,pr_merge_approval" ]
  jq -e '.scenarios | to_entries | all(.value.pass == true)' "$regenerated" >/dev/null
  run bash "$TK/scripts/ordo_eval.sh" check --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.pass' <<<"$output")" = "true" ]
  [ "$(jq -r '.regressions' <<<"$output")" = "0" ]
  [ "$(jq -r '.scenarios | to_entries | map(.value.status) | unique | join(",")' <<<"$output")" = "ok" ]
}

@test "baseline: a regression fails check with exit 1 and a diff; new and missing scenarios are reported (#813)" {
  local dir="$BATS_TEST_TMPDIR/subset" base="$BATS_TEST_TMPDIR/base.json"
  mkdir -p "$dir"
  cp "$EVAL_DEMO/budget_exhausted.json" "$EVAL_DEMO/budget_exhausted.expected.json" "$dir/"
  run ordo_eval_baseline "$dir/budget_exhausted.json" --out "$base"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.scenarios.budget_exhausted.pass' "$base")" = "true" ]
  # Tamper: the baseline claims fewer tokens, fewer events and a different end state.
  jq '.scenarios.budget_exhausted.metrics.tokens_used = 100 | .scenarios.budget_exhausted.metrics.events_total = 3 | .scenarios.budget_exhausted.metrics.states.greedy = "succeeded" | .scenarios.ghost = .scenarios.budget_exhausted' "$base" > "$BATS_TEST_TMPDIR/tampered.json"
  run --separate-stderr ordo_eval_check "$BATS_TEST_TMPDIR/tampered.json" "$dir/budget_exhausted.json"
  [ "$status" -eq 1 ]
  assert_error_line generic_failure
  [ "$(jq -r '.pass' <<<"$output")" = "false" ]
  [ "$(jq -r '.regressions' <<<"$output")" = "4" ]
  [ "$(jq -r '.scenarios.budget_exhausted.status' <<<"$output")" = "regression" ]
  [ "$(jq -r '.scenarios.budget_exhausted.regressions | join("; ")' <<<"$output")" = 'states: {"greedy":"succeeded"} -> {"greedy":"failed"}; tokens_used: 100 -> 1200; events_total: 3 -> 12' ]
  [ "$(jq -r '.scenarios.ghost.status' <<<"$output")" = "missing" ]
  [ "$(printf '%s' "$stderr" | jq -r '.error.details.regressions.ghost[0]')" = "scenario present in the baseline was not run" ]
  # An improvement (lower cost) is reported but is not a regression; an unknown scenario is "new".
  jq '.scenarios.budget_exhausted.metrics.tokens_used = 5000 | del(.scenarios.ghost) | .scenarios.other = .scenarios.budget_exhausted | del(.scenarios.budget_exhausted)' "$base" > "$BATS_TEST_TMPDIR/improved.json"
  run --separate-stderr ordo_eval_check "$BATS_TEST_TMPDIR/improved.json" "$dir/budget_exhausted.json"
  [ "$status" -eq 1 ]
  [ "$(jq -r '.scenarios.budget_exhausted.status' <<<"$output")" = "new" ]
  [ "$(jq -r '.scenarios.other.status' <<<"$output")" = "missing" ]
  jq '.scenarios.budget_exhausted.metrics.tokens_used = 5000' "$base" > "$BATS_TEST_TMPDIR/improved.json"
  run bash "$TK/scripts/ordo_eval.sh" check --dir "$dir" --baseline "$BATS_TEST_TMPDIR/improved.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *"baseline check: PASS"* ]]
  [[ "$output" == *"budget_exhausted: improved"* ]]
  [[ "$output" == *"+ tokens_used: 5000 -> 1200"* ]]
}

# --- isolation: no gh / tmux / curl / ssh ------------------------------------------

@test "no network tools: a scenario runs with a PATH that has no gh/tmux/curl/ssh, and the sandbox guard refuses any call (#813)" {
  local empty_bin="$BATS_TEST_TMPDIR/empty-bin" tool
  mkdir -p "$empty_bin"
  for tool in bash jq python3 cat tr grep sed head tail awk mktemp rm date od paste wc sort uniq find sha256sum cp mkdir dirname basename mv ls xargs flock chmod cut tee; do
    ln -sf "$(command -v "$tool")" "$empty_bin/$tool" 2>/dev/null || true
  done
  PATH="$empty_bin" run bash -c 'command -v gh tmux curl ssh'
  [ "$status" -ne 0 ]
  PATH="$empty_bin" run ordo_eval_run "$EVAL_DEMO/budget_exhausted.json" --out "$BATS_TEST_TMPDIR/out"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.ok' <<<"$output")" = "true" ]
  [ "$(jq -c '.forbidden_calls' "$BATS_TEST_TMPDIR/out/summary.json")" = "[]" ]
  # The guard stubs sit first on the sandbox PATH: any call is refused with exit 6 and recorded.
  run ordo_eval_run "$EVAL_DEMO/budget_exhausted.json" --out "$BATS_TEST_TMPDIR/out2" --work "$BATS_TEST_TMPDIR/work" --keep
  [ "$status" -eq 0 ]
  for tool in gh tmux curl ssh; do
    [ -x "$BATS_TEST_TMPDIR/work/bin/$tool" ]
  done
  run --separate-stderr "$BATS_TEST_TMPDIR/work/bin/gh" pr merge 12
  [ "$status" -eq 6 ]
  assert_error_line missing_dependency
  [ "$(cat "$BATS_TEST_TMPDIR/work/forbidden.log")" = "gh pr merge 12" ]
  # Every stored trajectory of this file was produced without a forbidden call.
  local name
  for name in $EVAL_SCENARIOS; do
    [ "$(jq -c '.forbidden_calls' "$EVAL_TRAJ/$name/summary.json")" = "[]" ]
  done
}

# --- exit codes and the operator script ------------------------------------------------

@test "exit codes: usage 2, not found 4, invalid scenario / unknown op / diverging step 5 with the trajectory kept (#813)" {
  run --separate-stderr ordo_eval_run
  [ "$status" -eq 2 ]; assert_error_line usage
  run --separate-stderr ordo_eval_run "$EVAL_DEMO/issue_triage.json" --bogus
  [ "$status" -eq 2 ]; assert_error_line usage
  run --separate-stderr ordo_eval_run "$BATS_TEST_TMPDIR/missing.json"
  [ "$status" -eq 4 ]; assert_error_line not_found
  run --separate-stderr ordo_eval_score "$BATS_TEST_TMPDIR/nowhere" "$EVAL_DEMO/issue_triage.expected.json"
  [ "$status" -eq 4 ]; assert_error_line not_found
  mkdir -p "$BATS_TEST_TMPDIR/precious"; printf 'keep me\n' > "$BATS_TEST_TMPDIR/precious/notes.txt"
  run --separate-stderr ordo_eval_run "$EVAL_DEMO/issue_triage.json" --out "$BATS_TEST_TMPDIR/precious"
  [ "$status" -eq 5 ]; assert_error_line conflict
  [ -f "$BATS_TEST_TMPDIR/precious/notes.txt" ]
  printf '{"name":"Bad Name","clock":"now","runs":{},"steps":[]}\n' > "$BATS_TEST_TMPDIR/bad.json"
  run --separate-stderr ordo_eval_run "$BATS_TEST_TMPDIR/bad.json"
  [ "$status" -eq 5 ]; assert_error_line invalid_contract
  [ "$(printf '%s' "$stderr" | jq -r '.error.details.errors | length')" = "3" ]
  printf 'not json\n' > "$BATS_TEST_TMPDIR/bad.json"
  run --separate-stderr ordo_eval_run "$BATS_TEST_TMPDIR/bad.json"
  [ "$status" -eq 5 ]; assert_error_line invalid_json
  # An unknown step op and a step whose exit code differs from expect_rc both diverge (5); the trajectory is still written.
  jq '.name = "unknown_op" | .steps = [{"op": "teleport"}]' "$EVAL_DEMO/budget_exhausted.json" > "$BATS_TEST_TMPDIR/unknown_op.json"
  run --separate-stderr ordo_eval_run "$BATS_TEST_TMPDIR/unknown_op.json" --out "$BATS_TEST_TMPDIR/u"
  [ "$status" -eq 5 ]; assert_error_line invalid_state
  [ "$(jq -r '.ok' "$BATS_TEST_TMPDIR/u/summary.json")" = "false" ]
  [ "$(jq -r '.error.error.code' "$BATS_TEST_TMPDIR/u/steps.jsonl" | tail -n 1)" = "invalid_contract" ]
  jq '.name = "diverge" | .steps = [{"op": "complete", "run": "greedy"}]' "$EVAL_DEMO/budget_exhausted.json" > "$BATS_TEST_TMPDIR/diverge.json"
  run --separate-stderr ordo_eval_run "$BATS_TEST_TMPDIR/diverge.json" --out "$BATS_TEST_TMPDIR/d"
  [ "$status" -eq 5 ]; assert_error_line invalid_state
  [ "$(printf '%s' "$stderr" | jq -r '.error.details.mismatch')" = "step 1 (complete) exited 5, expected 0" ]
  [ "$(jq -r '.mismatch' "$BATS_TEST_TMPDIR/d/summary.json")" = "step 1 (complete) exited 5, expected 0" ]
  [ "$(jq -r 'select(.op == "complete") | .error.error.code' "$BATS_TEST_TMPDIR/d/steps.jsonl")" = "invalid_transition" ]
  # A scenario may only set scheduler knobs through env.
  jq '.name = "badenv" | .env = {"PATH": "/nowhere"}' "$EVAL_DEMO/budget_exhausted.json" > "$BATS_TEST_TMPDIR/badenv.json"
  run --separate-stderr ordo_eval_run "$BATS_TEST_TMPDIR/badenv.json"
  [ "$status" -eq 5 ]; assert_error_line invalid_contract
}

@test "operator script: run/score/list/--json, human output, exit codes (#813)" {
  local script="$TK/scripts/ordo_eval.sh"
  run --separate-stderr bash "$script"
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"Usage:"* ]]
  [ "$(printf '%s\n' "$stderr" | tail -n 1 | jq -r '.error.code')" = "usage" ]
  run --separate-stderr bash "$script" bogus
  [ "$status" -eq 2 ]; assert_error_line unknown_command
  run --separate-stderr bash "$script" run
  [ "$status" -eq 2 ]; assert_error_line usage
  run --separate-stderr bash "$script" run "$BATS_TEST_TMPDIR/missing.json"
  [ "$status" -eq 4 ]; assert_error_line not_found
  run bash "$script" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"baseline [--dir DIR] [--out FILE]"* ]]
  run bash "$script" list
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c .)" -eq 10 ]
  [[ "$output" == *"/demo/pr_merge_approval.json"* ]]
  [[ "$output" == *"/failures/approval_expiry.json"* ]]
  run bash "$script" run "$EVAL_DEMO/budget_exhausted.json" --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.score.pass' <<<"$output")" = "true" ]
  [ "$(jq -r '.trajectory' <<<"$output")" = "null" ]
  run bash "$script" run "$EVAL_DEMO/budget_exhausted.json" --out "$BATS_TEST_TMPDIR/s"
  [ "$status" -eq 0 ]
  [[ "$output" == *"scenario budget_exhausted: PASS"* ]]
  [[ "$output" == *"  completion: pass"* ]]
  [[ "$output" == *"clock 2026-09-11T10:00:00Z -> 2026-09-11T10:02:00Z"* ]]
  [ -f "$BATS_TEST_TMPDIR/s/summary.json" ]
  run bash "$script" score "$BATS_TEST_TMPDIR/s" "$EVAL_DEMO/budget_exhausted.expected.json" --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.pass' <<<"$output")" = "true" ]
  run bash "$script" score "$BATS_TEST_TMPDIR/s" "$EVAL_DEMO/issue_triage.expected.json"
  [ "$status" -eq 1 ]
  [[ "$output" == *"scenario budget_exhausted: FAIL"* ]]
  [[ "$output" == *"completion: FAIL — run triage7: expected succeeded, got missing"* ]]
  run --separate-stderr bash "$script" score "$BATS_TEST_TMPDIR/s"
  [ "$status" -eq 2 ]; assert_error_line usage
}
