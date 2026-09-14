#!/usr/bin/env bats
# tests/docs_demo_path.bats — guard for docs/architecture/demo.md (#814, epic #806).
#
# Runs the commands the demo page documents, non-interactively, and asserts
# the key outputs the page pastes, so the walkthrough cannot rot:
#   1. the evaluation demo: `ordo_eval.sh list|demo|run|score` on the shipped
#      scenarios — zero regressions, a kept trajectory that ends `succeeded`
#      with exactly one mutation and a provider.pr_merge span, and the
#      approval_expiry scenario refusing with policy_refused/approval_expired;
#   2. the live journal against examples/demo/demo.config.sh (fake provider
#      and runtime): enqueue, tick, approval request, a model grant refused
#      (3), an operator grant, execution refused by the unscoped gate (3),
#      executed once under a scoped gate, replayed (replayed=true), one
#      mutation=true journal event, compat export, trace export, cancel (0)
#      then cancel again (5).
# A decoy `gh` sits first on PATH and fails loudly if anything calls it: the
# whole page must run with no forge CLI, no tmux, no curl and no credentials.

# shellcheck disable=SC2154  # $stderr / $output / $status are set by bats' run --separate-stderr
bats_require_minimum_version 1.5.0

load './helpers.bash'

setup() {
  setup_orch_test
  export TMPDIR="$BATS_TEST_TMPDIR"
  export ORDO_DEMO_DIR="$BATS_TEST_TMPDIR/live"
  export GH_DECOY_MARKER="$BATS_TEST_TMPDIR/gh-was-called"
  export CFG="$TK/examples/demo/demo.config.sh"
  # Every forge/runtime tool the page promises not to need fails loudly.
  local tool
  for tool in gh curl ssh tmux glab; do
    write_mock_bin "$tool" <<EOF
#!/usr/bin/env bash
printf '%s\n' "$tool \$*" >> "$GH_DECOY_MARKER"
exit 99
EOF
  done
  # The live half of the page: fake forge fixtures + pinned clock.
  mkdir -p "$ORDO_DEMO_DIR"
  cp -r "$TK/tests/fixtures/adapters/fake" "$ORDO_DEMO_DIR/fake"
  export ORDO_JOURNAL_NOW=2026-09-11T10:00:00Z
  unset ORCH_EXTERNAL_PR_MUTATIONS ORDO_POLICY_VERSION ORDO_APPROVAL_PRINCIPALS ORDO_OPERATOR
}

assert_no_forge_tool_called() {
  if [ -f "$GH_DECOY_MARKER" ]; then
    echo "a forbidden tool was invoked:"; cat "$GH_DECOY_MARKER"; return 1
  fi
}

journal_snippet() {
  # journal_snippet <bash snippet> — sourced in a subshell exactly as the page shows
  bash -c "source '$CFG'; source '$TK/lib/audit_log.sh'; source '$TK/lib/state_persist.sh'; source '$TK/lib/ordo_journal.sh'; $1" 2>/dev/null
}

@test "demo page 1.1: ordo_eval.sh list prints the four demo and six failure scenarios" {
  run --separate-stderr bash "$TK/scripts/ordo_eval.sh" list
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c '/tests/fixtures/eval/demo/')" -eq 4 ]
  [ "$(printf '%s\n' "$output" | grep -c '/tests/fixtures/eval/failures/')" -eq 6 ]
  printf '%s\n' "$output" | grep -q 'demo/pr_merge_approval.json'
  printf '%s\n' "$output" | grep -q 'failures/approval_expiry.json'
}

@test "demo page 1.2: ordo_eval.sh demo passes the baseline with zero regressions and no forge tool" {
  run --separate-stderr bash "$TK/scripts/ordo_eval.sh" demo
  [ "$status" -eq 0 ] || { echo "stderr: $stderr"; return 1; }
  printf '%s\n' "$output" | grep -qx 'baseline check: PASS (0 regression(s))'
  local name
  for name in blocked_run budget_exhausted issue_triage pr_merge_approval; do
    printf '%s\n' "$output" | grep -qx "  $name: ok"
  done
  assert_no_forge_tool_called
}

@test "demo page 1.3-1.5: the kept pr_merge_approval trajectory reads as documented" {
  local traj="$BATS_TEST_TMPDIR/traj"
  run --separate-stderr bash "$TK/scripts/ordo_eval.sh" run "$TK/tests/fixtures/eval/demo/pr_merge_approval.json" --out "$traj"
  [ "$status" -eq 0 ] || { echo "stderr: $stderr"; return 1; }
  printf '%s\n' "$output" | grep -q '^trajectory: .* (20 steps, clock 2026-09-11T10:00:00Z -> 2026-09-11T10:04:00Z)$'
  printf '%s\n' "$output" | grep -qx 'scenario pr_merge_approval: PASS'
  printf '%s\n' "$output" | grep -q 'metrics: mutations=1 unapproved=0 refused=0 repeated_keys=0 deliveries=1 events=27 spans=8 elapsed=240s tokens=1500 attempts=1'
  # The journal: 27 events, first run.created by an operator, last run.succeeded by the agent.
  [ "$(wc -l < "$traj/events.jsonl")" -eq 27 ]
  [ "$(jq -r 'select(.run_seq == 1) | "\(.type) \(.actor.type)"' "$traj/events.jsonl")" = "run.created operator" ]
  [ "$(jq -r 'select(.run_seq == 27) | "\(.type) \(.actor.type)"' "$traj/events.jsonl")" = "run.succeeded agent" ]
  jq -e 'select(.type == "approval_bridge.executed") | .mutation == true' "$traj/events.jsonl" >/dev/null
  # The projection: succeeded through approval_required, 1500 tokens.
  [ "$(jq -r '.[] | .state' "$traj/runs.json")" = "succeeded" ]
  [ "$(jq -c '.[] | [.transitions[] | "\(.from)->\(.to)"]' "$traj/runs.json")" = '["queued->leased","leased->running","running->approval_required","approval_required->running","running->succeeded"]' ]
  [ "$(jq -r '.[] | .budgets.tokens_used' "$traj/runs.json")" = "1500" ]
  # One mutation, one ledger receipt, not replayed.
  [ "$(wc -l < "$traj/mutations.jsonl")" -eq 1 ]
  [ "$(jq -r '.idempotency_key' "$traj/mutations.jsonl")" = "merge-acme-widgets-12" ]
  [ "$(jq -r '.receipt.details.replayed' "$traj/ledger.jsonl")" = "false" ]
  # The trace: 8 spans including the bridge chain.
  [ "$(wc -l < "$traj/traces.jsonl")" -eq 8 ]
  local span
  for span in approval.authorize policy.reauthorize provider.pr_merge runtime.start; do
    jq -e "select(.name == \"$span\") | .status.code == \"OK\"" "$traj/traces.jsonl" >/dev/null
  done
  # Score the kept trajectory on its own.
  run --separate-stderr bash "$TK/scripts/ordo_eval.sh" score "$traj" "$TK/tests/fixtures/eval/demo/pr_merge_approval.expected.json"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qx 'scenario pr_merge_approval: PASS'
  assert_no_forge_tool_called
}

@test "demo page 1.4: approval_expiry refuses (policy_refused/approval_expired) and duplicate_delivery executes once" {
  local expiry="$BATS_TEST_TMPDIR/expiry"
  run --separate-stderr bash "$TK/scripts/ordo_eval.sh" run "$TK/tests/fixtures/eval/failures/approval_expiry.json" --out "$expiry"
  [ "$status" -eq 0 ] || { echo "stderr: $stderr"; return 1; }
  printf '%s\n' "$output" | grep -qx 'scenario approval_expiry: PASS'
  printf '%s\n' "$output" | grep -q 'metrics: mutations=0 unapproved=0 refused=1 '
  [ "$(jq -c 'select(.op == "execute") | {rc, error: .error.error.code, reason: .error.error.details.reason}' "$expiry/steps.jsonl")" = '{"rc":3,"error":"policy_refused","reason":"approval_expired"}' ]
  [ "$(wc -l < "$expiry/mutations.jsonl")" -eq 0 ]
  [ "$(jq -c 'select(.type == "policy.decided") | .payload.decision' "$expiry/events.jsonl" | paste -sd, -)" = '"allow","deny"' ]
  jq -e 'select(.type == "policy.decided" and .payload.decision == "deny") | .payload.reasons == ["approval_expired"]' "$expiry/events.jsonl" >/dev/null

  local dup="$BATS_TEST_TMPDIR/dup"
  run --separate-stderr bash "$TK/scripts/ordo_eval.sh" run "$TK/tests/fixtures/eval/failures/duplicate_delivery.json" --out "$dup" --json
  [ "$status" -eq 0 ] || { echo "stderr: $stderr"; return 1; }
  [ "$(printf '%s' "$output" | jq -c '{pass: .score.pass, m: (.score.metrics | {mutations_executed, deliveries, replayed_deliveries, repeated_keys})}')" = '{"pass":true,"m":{"mutations_executed":1,"deliveries":3,"replayed_deliveries":2,"repeated_keys":0}}' ]
  assert_no_forge_tool_called
}

@test "demo page 2: the live journal walkthrough on examples/demo/demo.config.sh" {
  local sched="$TK/scripts/ordo_scheduler.sh" approve="$TK/scripts/ordo_approve.sh" ordo="$TK/scripts/ordo.sh"

  # 2.2 enqueue + tick + status
  run --separate-stderr bash "$sched" "$CFG" enqueue --title "Merge PR 12 once CI is green" --ticket 'acme/widgets#12' --json
  [ "$status" -eq 0 ] || { echo "stderr: $stderr"; return 1; }
  local run_id
  run_id=$(printf '%s' "$output" | jq -r .run_id)
  [[ "$run_id" =~ ^run_[0-9a-f]{24}$ ]]
  [ "$(printf '%s' "$output" | jq -r .state)" = "queued" ]
  [ "$(printf '%s' "$output" | jq -r .budgets.max_attempts)" = "4" ]
  printf '%s\n' "$stderr" | grep -q "SCHEDULER ENQUEUED run=$run_id priority=100 ticket=acme/widgets#12"

  run --separate-stderr bash "$sched" "$CFG" tick --json
  [ "$status" -eq 0 ] || { echo "stderr: $stderr"; return 1; }
  [ "$(printf '%s' "$output" | jq -r '.picked[0] | "\(.run_id) \(.state) \(.attempt_no)"')" = "$run_id running 1" ]
  [ "$(printf '%s' "$output" | jq -r '.picked[0].owner')" != "" ]
  printf '%s' "$output" | jq -e '.picked[0].owner | startswith("demo@")' >/dev/null

  run --separate-stderr bash "$sched" "$CFG" status "$run_id"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q "^$run_id running prio=100 attempts=1 ready=true (ready) lease=demo@"

  # 2.3 request; a model may not grant; an operator may
  run --separate-stderr bash "$approve" "$CFG" request "$run_id" pr.merge --principal demo-operator \
    --idempotency-key "demo:pr.merge:12" --payload '{"args":["12","--method","squash"]}' --json
  [ "$status" -eq 0 ] || { echo "stderr: $stderr"; return 1; }
  local approval_id
  approval_id=$(printf '%s' "$output" | jq -r .id)
  [[ "$approval_id" =~ ^approval_[0-9a-f]{24}$ ]]
  [ "$(printf '%s' "$output" | jq -r '"\(.state) \(.policy_version) \(.expires_at)"')" = "pending demo-policy-v1 2026-09-11T11:00:00Z" ]

  run --separate-stderr bash "$ordo" approve "$CFG" "$approval_id" --by model:planner --json
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  [ "$(printf '%s' "$stderr" | jq -r '.error | "\(.code) \(.module) \(.details.reason) \(.details.decision)"')" = "policy_refused approval actor_type_not_allowed deny" ]

  run --separate-stderr bash "$ordo" approve "$CFG" "$approval_id" --by demo-operator --reason "CI green, reviewed" --json
  [ "$status" -eq 0 ] || { echo "stderr: $stderr"; return 1; }
  [ "$(printf '%s' "$output" | jq -c '{state, decided_by, reason}')" = '{"state":"granted","decided_by":{"id":"demo-operator","type":"operator"},"reason":"CI green, reviewed"}' ]

  # 2.4 refused by the unscoped gate, executed under a scoped gate, replayed
  run --separate-stderr bash "$approve" "$CFG" authorize-and-run "$approval_id" --json -- pr_merge 12 --method squash
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  [ "$(printf '%s' "$stderr" | jq -r '.error | "\(.code) \(.module) \(.details.scope) \(.details.authorize_via) \(.details.gate_exit)"')" = "policy_refused provider_adapter pr_merge ORCH_EXTERNAL_PR_MUTATIONS 80" ]
  [ ! -e "$ORDO_DEMO_DIR/fake/mutations.jsonl" ] || [ "$(wc -l < "$ORDO_DEMO_DIR/fake/mutations.jsonl")" -eq 0 ]

  ORCH_EXTERNAL_PR_MUTATIONS=pr_merge run --separate-stderr bash "$approve" "$CFG" authorize-and-run "$approval_id" --json -- pr_merge 12 --method squash
  [ "$status" -eq 0 ] || { echo "stderr: $stderr"; return 1; }
  [ "$(printf '%s' "$output" | jq -c '{op, replayed: .details.replayed, key: .details.idempotency_key, result: .result}')" = '{"op":"pr_merge","replayed":false,"key":"demo:pr.merge:12","result":{"number":12,"merged":true,"action":"merged","method":"squash","admin":false}}' ]
  [ "$(printf '%s' "$output" | jq -r .approval_id)" = "$approval_id" ]

  ORCH_EXTERNAL_PR_MUTATIONS=pr_merge run --separate-stderr bash "$approve" "$CFG" authorize-and-run "$approval_id" --json -- pr_merge 12 --method squash
  [ "$status" -eq 0 ] || { echo "stderr: $stderr"; return 1; }
  [ "$(printf '%s' "$output" | jq -c '.details | {replayed, idempotency_key}')" = '{"replayed":true,"idempotency_key":"demo:pr.merge:12"}' ]
  [ "$(wc -l < "$ORDO_DEMO_DIR/fake/mutations.jsonl")" -eq 1 ]
  [ "$(jq -r '.idempotency_key' "$ORDO_DEMO_DIR/fake/mutations.jsonl")" = "demo:pr.merge:12" ]

  run --separate-stderr bash "$ordo" approve --list "$CFG" "$run_id"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qx "$approval_id consumed action=pr.merge principal=demo-operator policy=demo-policy-v1 expires=2026-09-11T11:00:00Z"

  [ "$(grep -c 'EXTERNAL_PR_MUTATION action=pr_merge mode=refused' "$ORCH_LOG_DIR/ordo-demo.log")" -eq 1 ]
  [ "$(grep -c 'EXTERNAL_PR_MUTATION action=pr_merge mode=allowed' "$ORCH_LOG_DIR/ordo-demo.log")" -eq 1 ]

  # 2.5 the journal: 15 events, one mutation=true, the model's deny journaled
  local events
  events=$(journal_snippet "ordo_journal_events '$run_id'")
  [ "$(printf '%s\n' "$events" | grep -c .)" -eq 15 ]
  [ "$(printf '%s\n' "$events" | jq -r 'select(.mutation == true) | .type')" = "approval_bridge.executed" ]
  [ "$(printf '%s\n' "$events" | jq -r 'select(.run_seq == 8) | "\(.type) \(.actor.type)"')" = "policy.decided model" ]
  [ "$(printf '%s\n' "$events" | jq -r 'select(.run_seq == 12) | .type')" = "approval_bridge.execution_failed" ]
  [ "$(printf '%s\n' "$events" | jq -r 'select(.run_seq == 15) | "\(.type) \(.actor.type)"')" = "approval_bridge.executed operator" ]
  [ "$(journal_snippet "ordo_journal_project '$run_id'" | jq -c '{state, terminal, transitions: [.transitions[] | "\(.from)->\(.to)"], approval: .approval.state, mutations: .counters.mutations}')" = "{\"state\":\"running\",\"terminal\":false,\"transitions\":[\"queued->leased\",\"leased->running\"],\"approval\":\"consumed\",\"mutations\":1}" ]

  local compat
  compat=$(journal_snippet "ordo_journal_compat_export '$run_id'")
  [ "$(printf '%s' "$compat" | jq -r '"\(.state) \(.assignment.action)"')" = "running none" ]
  [ -f "$ORCH_STATE_BASE/ordo-demo/ordo-runs/$run_id.json" ]
  [ -f "$ORCH_STATE_BASE/ordo-demo/ordo-journal.sqlite" ]
  [ -f "$ORCH_STATE_BASE/ordo-demo/ordo-provider-idempotency.jsonl" ]

  # 2.6 the trace export
  local otlp
  otlp=$(bash -c "source '$CFG'; source '$TK/lib/audit_log.sh'; source '$TK/lib/ordo_trace.sh'; ordo_trace_export \"\$(ordo_trace_new_id trace '$run_id')\"" 2>/dev/null)
  [ "$(printf '%s' "$otlp" | jq -r '.resourceSpans[0].scopeSpans[0].spans | map(.name) | sort | unique | join(",")')" = "approval.authorize,policy.reauthorize,provider.pr_merge" ]
  [ "$(printf '%s' "$otlp" | jq -r '[.resourceSpans[0].scopeSpans[0].spans[] | select(.name == "approval.authorize")] | length')" -eq 3 ]
  [ "$(printf '%s' "$otlp" | jq -r '[.resourceSpans[0].scopeSpans[0].spans[] | select(.name == "provider.pr_merge")] | map(.kind) | unique | .[0]')" = "3" ]
  [ "$(printf '%s' "$otlp" | jq -r '.resourceSpans[0].resource.attributes | map({(.key): .value.stringValue}) | add | "\(.["service.name"]) \(.["ordo.project"]) \(.["ordo.run_id"])"')" = "ordo ordo-demo $run_id" ]

  # 2.7 cancel once (0), cancel again (5)
  run --separate-stderr bash "$ordo" cancel "$CFG" "$run_id" --reason "demo over" --json
  [ "$status" -eq 0 ] || { echo "stderr: $stderr"; return 1; }
  [ "$(printf '%s' "$output" | jq -r '"\(.state) \(.from) \(.reason) \(.lease)"')" = "cancelled running demo over null" ]
  run --separate-stderr bash "$ordo" cancel "$CFG" "$run_id" --json
  [ "$status" -eq 5 ]
  [ "$(printf '%s' "$stderr" | jq -r '.error | "\(.code) \(.module) \(.details.terminal)"')" = "invalid_transition scheduler true" ]
  run --separate-stderr bash "$sched" "$CFG" status --json
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -c '{capacity, counts}')" = '{"capacity":{"max_fanout":2,"in_use":0,"available":2},"counts":{"cancelled":1}}' ]

  assert_no_forge_tool_called
}
