#!/usr/bin/env bats
# tests/ordo_scheduler.bats — durable scheduler (#810, epic #806).
#
# Covers lib/ordo_scheduler.sh and scripts/ordo_scheduler.sh:
#   - every run state and the contracts-validated transitions (exit 5 on refusal);
#   - tick: priority/FIFO picks bounded by ORDO_SCHED_MAX_FANOUT, lease + events;
#   - heartbeat (lease renewal, usage accounting), lease expiry, retry policy with
#     an exact exponential backoff schedule (jitter disabled), timeouts;
#   - cancellation from every non-terminal state, crash recovery (dead owner pid);
#   - budgets: tokens, seconds, turns, tool calls, cost, attempts/retries, fan-out
#     (exit 7 budget_exhausted);
#   - human waits hold no lease and no worker slot; fail-closed readiness;
#   - exit codes 5 / 7 / 8; the orch_loop opt-in hook (default off).
# The clock is pinned with ORDO_JOURNAL_NOW; nothing here sleeps.

bats_require_minimum_version 1.5.0

load './helpers.bash'

setup() {
  setup_orch_test
  # shellcheck disable=SC1090
  source "$TK/lib/audit_log.sh"
  # shellcheck disable=SC1090
  source "$TK/lib/state_persist.sh"
  # shellcheck disable=SC1090
  source "$TK/lib/ordo_scheduler.sh"
  # Keep audit rows out of stderr so error-line assertions stay exact.
  audit() { printf 'AUDIT %s\n' "$*" >> "$ORCH_LOG_DIR/audit.log"; }
  export ORDO_JOURNAL_NOW=2026-09-11T10:00:00Z
  export ORDO_JOURNAL_FAULT=""
  export ORDO_RUNTIME_ADAPTER=fake
  export ORDO_SCHED_JITTER=0 ORDO_SCHED_MAX_FANOUT=2 ORDO_SCHED_LEASE_TTL=300 ORDO_SCHED_HEARTBEAT_SEC=60
  export ORDO_SCHED_RUN_TIMEOUT_SEC=3600 ORDO_SCHED_MAX_RETRIES=3 ORDO_SCHED_BACKOFF_BASE_SEC=30 ORDO_SCHED_BACKOFF_MAX_SEC=1800
  export ORDO_SCHED_TIMEOUT_POLICY=requeue ORDO_SCHED_LEASE_EXPIRY_POLICY=requeue ORDO_SCHED_QUEUE_TTL_SEC=0 ORDO_SCHED_WAIT_TIMEOUT_SEC=0
  export ORDO_SCHED_REQUIRE_READINESS=0 ORDO_SCHED_WORKER_ID=w1 ORDO_SCHED_WORKER_PID=$$ ORDO_SCHED_HOST=h1
  export ORDO_SCHED_BUDGET_MAX_TURNS=200 ORDO_SCHED_BUDGET_MAX_TOOL_CALLS=2000 ORDO_SCHED_BUDGET_MAX_SECONDS=14400 ORDO_SCHED_BUDGET_MAX_TOKENS=5000000 ORDO_SCHED_BUDGET_MAX_COST=0
  ordo_journal_init >/dev/null
}

assert_error_line() {
  local code="$1" module="${2:-scheduler}"
  [ "$(printf '%s\n' "$stderr" | grep -c .)" -eq 1 ] || { echo "stderr: $stderr"; return 1; }
  [ "$(printf '%s' "$stderr" | jq -r '.error.code')" = "$code" ] || { echo "stderr: $stderr"; return 1; }
  [ "$(printf '%s' "$stderr" | jq -r '.error.module')" = "$module" ] || { echo "stderr: $stderr"; return 1; }
  printf '%s' "$stderr" | jq -e '.error.details | type == "object"' >/dev/null
}

state() { ordo_journal_state "$1"; }
snap() { ordo_journal_project "$1"; }
lease_states() { ordo_journal_lease_list "$1" | jq -r '.state' | paste -sd, -; }
enqueue() { ordo_scheduler_enqueue "$@" | jq -r '.run_id'; }
# start: enqueue + one tick, asserting the run is picked.
start() {
  local id
  id=$(enqueue "$@")
  ordo_scheduler_tick >/dev/null
  [ "$(state "$id")" = "running" ] || { echo "run $id not running: $(state "$id")"; return 1; }
  printf '%s' "$id"
}
clock() { export ORDO_JOURNAL_NOW="$1"; }

# --- enqueue / state machine ------------------------------------------------

@test "enqueue creates a queued run with default budgets, priority and metadata; duplicate id conflicts (#810)" {
  run ordo_scheduler_enqueue --title Widget --ticket owner/repo#42 --priority 7 --budget '{"max_tokens":500}' --metadata '{"lane":"a"}'
  [ "$status" -eq 0 ]
  local id; id=$(jq -r .run_id <<<"$output")
  [[ "$id" =~ ^run_[0-9a-f]{24}$ ]]
  [ "$(jq -r .state <<<"$output")" = "queued" ]
  [ "$(jq -r .priority <<<"$output")" = "7" ]
  [ "$(jq -r .budgets.max_attempts <<<"$output")" = "4" ]      # MAX_RETRIES 3 + 1
  [ "$(jq -r .budgets.max_tokens <<<"$output")" = "500" ]      # per-run override
  [ "$(jq -r .budgets.max_turns <<<"$output")" = "200" ]
  [ "$(jq -r .budgets.max_tool_calls <<<"$output")" = "2000" ]
  [ "$(jq -r .budgets.max_seconds <<<"$output")" = "14400" ]
  [ "$(jq -c .budgets.exhausted <<<"$output")" = "[]" ]
  local s; s=$(snap "$id")
  [ "$(jq -r .title <<<"$s")" = "Widget" ]
  [ "$(jq -r .ticket_ref <<<"$s")" = "owner/repo#42" ]
  [ "$(jq -r .metadata.lane <<<"$s")" = "a" ]
  [ "$(jq -r .metadata.enqueued_at <<<"$s")" = "2026-09-11T10:00:00Z" ]
  [ "$(ordo_journal_events "$id" | jq -r .type)" = "run.created" ]
  # Explicit id reuse and conflicts.
  local fixed=run_0123456789abcdef01234567
  [ "$(enqueue --run-id "$fixed" --title fixed)" = "$fixed" ]
  run --separate-stderr ordo_scheduler_enqueue --run-id "$fixed"
  [ "$status" -eq 5 ]; assert_error_line conflict
  run --separate-stderr ordo_scheduler_enqueue --priority nope
  [ "$status" -eq 2 ]; assert_error_line bad_argument
  run --separate-stderr ordo_scheduler_enqueue --bogus 1
  [ "$status" -eq 2 ]; assert_error_line usage
}

@test "every state is reachable and every change is a journal event validated by the contracts table (#810)" {
  local id; id=$(enqueue --title walk)
  [ "$(state "$id")" = "queued" ]
  ordo_scheduler_tick >/dev/null
  [ "$(state "$id")" = "running" ]
  [ "$(jq -c '.transitions | map(.to)' <<<"$(snap "$id")")" = '["leased","running"]' ]
  ordo_scheduler_wait "$id" --reason ci >/dev/null;                [ "$(state "$id")" = "waiting" ]
  ordo_scheduler_resume "$id" >/dev/null;                          [ "$(state "$id")" = "running" ]
  ordo_scheduler_block "$id" --reason red --type ci >/dev/null;    [ "$(state "$id")" = "blocked" ]
  ordo_scheduler_resume "$id" --requeue >/dev/null;                [ "$(state "$id")" = "queued" ]
  ordo_scheduler_tick >/dev/null;                                  [ "$(state "$id")" = "running" ]
  ordo_scheduler_require_approval "$id" --action pr.merge >/dev/null; [ "$(state "$id")" = "approval_required" ]
  ordo_scheduler_resume "$id" >/dev/null;                          [ "$(state "$id")" = "running" ]
  ordo_scheduler_complete "$id" --result '{"pr":1}' >/dev/null;    [ "$(state "$id")" = "succeeded" ]
  # The state is a pure fold of the events: rebuilding reproduces it.
  [ "$(ordo_journal_events "$id" | jq -r .type | grep -c '^run\.')" -ge 11 ]
  ordo_journal_rebuild_all >/dev/null
  [ "$(state "$id")" = "succeeded" ]
  [ "$(jq -r '.counters.invalid_transitions' <<<"$(snap "$id")")" = "0" ]
  [ "$(jq -c '.transitions | map(.to)' <<<"$(snap "$id")")" = '["leased","running","waiting","running","blocked","queued","leased","running","approval_required","running","succeeded"]' ]
  # failed, cancelled and expired are reachable too.
  local f c e
  f=$(start --title f); ordo_scheduler_fail "$f" --reason boom >/dev/null; [ "$(state "$f")" = "failed" ]
  [ "$(jq -r '.metadata.failure_reason' <<<"$(snap "$f")")" = "boom" ]
  c=$(enqueue --title c); ordo_scheduler_cancel "$c" >/dev/null; [ "$(state "$c")" = "cancelled" ]
  e=$(enqueue --title e --expires-at 2026-09-11T10:00:00Z); ordo_scheduler_tick >/dev/null; [ "$(state "$e")" = "expired" ]
}

@test "invalid transitions are refused with exit 5 before anything is written (#810)" {
  local id; id=$(enqueue --title t)
  run --separate-stderr ordo_scheduler_complete "$id"
  [ "$status" -eq 5 ]; assert_error_line invalid_transition
  [ "$(printf '%s' "$stderr" | jq -r '.error.details.from')" = "queued" ]
  run --separate-stderr ordo_scheduler_resume "$id"
  [ "$status" -eq 5 ]; assert_error_line invalid_transition
  run --separate-stderr ordo_scheduler_wait "$id"
  [ "$status" -eq 5 ]; assert_error_line invalid_transition
  run --separate-stderr ordo_scheduler_heartbeat "$id"
  [ "$status" -eq 5 ]; assert_error_line invalid_state
  run --separate-stderr ordo_scheduler_fail "$id"
  [ "$status" -eq 5 ]; assert_error_line invalid_transition
  [ "$(printf '%s' "$stderr" | jq -c '.error.details.allowed')" = '["leased","cancelled","expired"]' ]
  [ "$(ordo_journal_events "$id" | wc -l)" -eq 1 ]
  [ "$(state "$id")" = "queued" ]
  # waiting -> queued is not in the table: resume --requeue refuses it.
  ordo_scheduler_tick >/dev/null; ordo_scheduler_wait "$id" >/dev/null
  run --separate-stderr ordo_scheduler_resume "$id" --requeue
  [ "$status" -eq 5 ]; assert_error_line invalid_transition
  [ "$(state "$id")" = "waiting" ]
  run --separate-stderr ordo_scheduler_cancel run_000000000000000000000000
  [ "$status" -eq 4 ]; assert_error_line not_found
  run --separate-stderr ordo_scheduler_cancel not-a-run
  [ "$status" -eq 2 ]; assert_error_line bad_argument
}

# --- tick: picks, fan-out, leases --------------------------------------------

@test "tick picks queued runs by priority then FIFO up to ORDO_SCHED_MAX_FANOUT and leases them to this worker (#810)" {
  local a b c d
  a=$(enqueue --title a --priority 50)
  b=$(enqueue --title b --priority 10)
  c=$(enqueue --title c --priority 10)
  d=$(enqueue --title d)
  run ordo_scheduler_tick
  [ "$status" -eq 0 ]
  [ "$(jq -c '.picked | map(.run_id)' <<<"$output")" = "[\"$b\",\"$c\"]" ]
  [ "$(jq -c '.skipped | map(.reason)' <<<"$output")" = '["capacity_exhausted","capacity_exhausted"]' ]
  [ "$(jq -r '.picks' <<<"$output")" = "2" ]
  [ "$(jq -r '.picked[0].attempt_no' <<<"$output")" = "1" ]
  [ "$(jq -r '.picked[0].owner' <<<"$output")" = "w1@h1:$$" ]
  [ "$(state "$b")" = "running" ]; [ "$(state "$c")" = "running" ]
  [ "$(state "$a")" = "queued" ];  [ "$(state "$d")" = "queued" ]
  # Events, lease and attempt counters.
  [ "$(ordo_journal_events "$b" | jq -r .type | paste -sd, -)" = "run.created,lease.acquired,run.leased,run.started,attempt.started" ]
  local s; s=$(snap "$b")
  [ "$(jq -r '.lease.owner' <<<"$s")" = "w1@h1:$$" ]
  [ "$(jq -r '.lease.expires_at' <<<"$s")" = "2026-09-11T10:05:00Z" ]
  [ "$(jq -r '.budgets.attempts_used' <<<"$s")" = "1" ]
  [ "$(jq -r '.metadata.attempt_started_at' <<<"$s")" = "2026-09-11T10:00:00Z" ]
  [ "$(jq -r '.metadata.lease_owner' <<<"$s")" = "w1@h1:$$" ]
  # A second tick has no capacity; freeing one slot lets the next priority in (a before d: lower number first).
  run ordo_scheduler_tick
  [ "$(jq -r '.picks' <<<"$output")" = "0" ]
  ordo_scheduler_complete "$b" >/dev/null
  run ordo_scheduler_tick
  [ "$(jq -c '.picked | map(.run_id)' <<<"$output")" = "[\"$a\"]" ]
  # Another worker cannot lease a run this worker holds.
  ORDO_SCHED_WORKER_ID=w2 run --separate-stderr ordo_journal_lease_acquire "$a" w2
  [ "$status" -eq 5 ]
  # --max-picks bounds a tick below the fan-out.
  ordo_scheduler_complete "$a" >/dev/null; ordo_scheduler_complete "$c" >/dev/null
  enqueue --title e >/dev/null
  run ordo_scheduler_tick --max-picks 1
  [ "$(jq -r '.picks' <<<"$output")" = "1" ]
  [ "$(jq -r '.capacity' <<<"$output")" = "1" ]
}

@test "tick on an empty journal and status report capacity and counts (#810)" {
  run ordo_scheduler_tick
  [ "$status" -eq 0 ]
  [ "$(jq -c '[.picked, .skipped, .expired_leases, .requeued, .failed, .errors] | map(length)' <<<"$output")" = "[0,0,0,0,0,0]" ]
  [ "$(jq -r .worker <<<"$output")" = "w1@h1:$$" ]
  local a; a=$(start --title a); enqueue --title b >/dev/null
  run ordo_scheduler_status
  [ "$status" -eq 0 ]
  [ "$(jq -c .capacity <<<"$output")" = '{"max_fanout":2,"in_use":1,"available":1}' ]
  [ "$(jq -c .counts <<<"$output")" = '{"queued":1,"running":1}' ]
  [ "$(jq -r --arg a "$a" '.runs[] | select(.run_id == $a) | .lease.owner' <<<"$output")" = "w1@h1:$$" ]
  run ordo_scheduler_status "$a"
  [ "$status" -eq 0 ]
  [ "$(jq -r .state <<<"$output")" = "running" ]
  [ "$(jq -r .readiness.ready <<<"$output")" = "true" ]
  [ "$(jq -r .lease.id <<<"$output")" != "null" ]
  [ "$(jq -c .budgets.exhausted <<<"$output")" = "[]" ]
}

# --- heartbeat / lease expiry / retry / timeout ------------------------------

@test "heartbeat renews the lease, accounts wall-clock and usage; a foreign or lost lease exits 8 (#810)" {
  local id; id=$(start --title hb)
  clock 2026-09-11T10:01:30Z
  run ordo_scheduler_heartbeat "$id" --usage '{"tokens":40,"turns":1,"tool_calls":3,"cost":0.5}'
  [ "$status" -eq 0 ]
  [ "$(jq -r .generation <<<"$output")" = "1" ]
  [ "$(jq -r .expires_at <<<"$output")" = "2026-09-11T10:06:30Z" ]
  [ "$(jq -r .seconds_delta <<<"$output")" = "90" ]
  local s; s=$(snap "$id")
  [ "$(jq -r .budgets.seconds_used <<<"$s")" = "90" ]
  [ "$(jq -r .budgets.tokens_used <<<"$s")" = "40" ]
  [ "$(jq -r .budgets.turns_used <<<"$s")" = "1" ]
  [ "$(jq -r .budgets.tool_calls_used <<<"$s")" = "3" ]
  [ "$(jq -r .budgets.cost_used <<<"$s")" = "0.5" ]
  [ "$(jq -r .metadata.heartbeat_at <<<"$s")" = "2026-09-11T10:01:30Z" ]
  [ "$(jq -r .lease.state <<<"$s")" = "renewed" ]
  [ "$(ordo_journal_events "$id" | jq -r .type | tail -n 2 | paste -sd, -)" = "lease.renewed,run.budget" ]
  # Wall-clock is additive across heartbeats.
  clock 2026-09-11T10:02:00Z
  ordo_scheduler_heartbeat "$id" >/dev/null
  [ "$(jq -r .budgets.seconds_used <<<"$(snap "$id")")" = "120" ]
  # Another worker does not own the lease.
  ORDO_SCHED_WORKER_ID=w2 run --separate-stderr ordo_scheduler_heartbeat "$id"
  [ "$status" -eq 8 ]; assert_error_line lease_lost
  [ "$(printf '%s' "$stderr" | jq -r '.error.details.owner')" = "w1@h1:$$" ]
  # Past the TTL the lease is stale (8), and once swept it is lost (8).
  clock 2026-09-11T10:07:01Z
  run --separate-stderr ordo_scheduler_heartbeat "$id"
  [ "$status" -eq 8 ]; assert_error_line lease_lost
  ordo_journal_lease_expire_stale >/dev/null
  run --separate-stderr ordo_scheduler_heartbeat "$id"
  [ "$status" -eq 8 ]; assert_error_line lease_lost
  # The tick heartbeats only when due (ORDO_SCHED_HEARTBEAT_SEC).
  local h; h=$(start --title h2)
  run ordo_scheduler_tick
  [ "$(jq -c '.heartbeats' <<<"$output")" = "[]" ]
  clock 2026-09-11T10:08:01Z
  run ordo_scheduler_tick
  [ "$(jq -r '.heartbeats[0].run_id' <<<"$output")" = "$h" ]
  [ "$(jq -r '.heartbeats[0].seconds_delta' <<<"$output")" = "60" ]
}

@test "an expired lease requeues the run through blocked with backoff, attempts preserved, and it is not picked before not_before (#810)" {
  local id; id=$(start --title lease)
  clock 2026-09-11T10:05:00Z            # TTL 300 reached: expires_at <= now
  run ordo_scheduler_tick
  [ "$status" -eq 0 ]
  [ "$(jq -r '.expired_leases[0].run_id' <<<"$output")" = "$id" ]
  [ "$(jq -r '.requeued[0].run_id' <<<"$output")" = "$id" ]
  [ "$(jq -r '.requeued[0].reason' <<<"$output")" = "lease_expired" ]
  [ "$(jq -r '.requeued[0].not_before' <<<"$output")" = "2026-09-11T10:05:30Z" ]
  [ "$(jq -r '.requeued[0].backoff_seconds' <<<"$output")" = "30" ]
  [ "$(jq -c '.picked' <<<"$output")" = "[]" ]      # not picked in the same tick (not_before)
  [ "$(state "$id")" = "queued" ]
  local s; s=$(snap "$id")
  [ "$(jq -r .budgets.attempts_used <<<"$s")" = "1" ]
  [ "$(jq -r .metadata.not_before <<<"$s")" = "2026-09-11T10:05:30Z" ]
  [ "$(jq -r .metadata.lease_owner <<<"$s")" = "null" ]
  [ "$(jq -r .counters.blockers_open <<<"$s")" = "0" ]
  [ "$(jq -c '.transitions | map(.to)' <<<"$s")" = '["leased","running","blocked","queued"]' ]
  [ "$(ordo_journal_events "$id" | jq -r .type | tail -n 4 | paste -sd, -)" = "run.blocked,blocker.raised,blocker.resolved,run.requeued" ]
  clock 2026-09-11T10:05:29Z
  run ordo_scheduler_tick
  [ "$(jq -r '.skipped[0].reason' <<<"$output")" = "not_before" ]
  [ "$(state "$id")" = "queued" ]
  clock 2026-09-11T10:05:30Z
  run ordo_scheduler_tick
  [ "$(jq -r '.picked[0].run_id' <<<"$output")" = "$id" ]
  [ "$(jq -r '.picked[0].attempt_no' <<<"$output")" = "2" ]
  [ "$(jq -r .metadata.not_before <<<"$(snap "$id")")" = "null" ]
  # Policy fail: the run fails instead of being requeued.
  clock 2026-09-11T10:10:30Z
  ORDO_SCHED_LEASE_EXPIRY_POLICY=fail run ordo_scheduler_tick
  [ "$(jq -r '.failed[0].action' <<<"$output")" = "failed" ]
  [ "$(jq -r '.failed[0].reason' <<<"$output")" = "lease_expired" ]
  [ "$(state "$id")" = "failed" ]
}

@test "backoff schedule is exact with jitter disabled, capped, and exhausts into budget_exhausted after MAX_RETRIES (#810)" {
  [ "$(for n in 0 1 2 3 4 5 6 7; do ordo_scheduler_backoff_seconds "$n"; done | paste -sd, -)" = "30,60,120,240,480,960,1800,1800" ]
  [ "$(ORDO_SCHED_BACKOFF_MAX_SEC=100 ordo_scheduler_backoff_seconds 3)" = "100" ]
  # Jitter enabled: within [delay/2, delay].
  local j; j=$(ORDO_SCHED_JITTER=1 ordo_scheduler_backoff_seconds 2)
  [ "$j" -ge 60 ] && [ "$j" -le 120 ]
  # Drive one run through successive lease losses: not_before = expiry + 30, 60, 120; the 4th loss fails.
  export ORDO_SCHED_LEASE_TTL=60
  local id; id=$(start --title retry)
  local now=2026-09-11T10:00:00Z expect
  local -a deltas=(30 60 120)
  local i
  for i in 0 1 2; do
    now=$(date -u -d "$now + 60 seconds" +%Y-%m-%dT%H:%M:%SZ); clock "$now"
    run ordo_scheduler_tick
    expect=$(date -u -d "$now + ${deltas[$i]} seconds" +%Y-%m-%dT%H:%M:%SZ)
    [ "$(jq -r '.requeued[0].not_before' <<<"$output")" = "$expect" ] || { echo "iteration $i: $output"; false; }
    [ "$(jq -r '.requeued[0].retries' <<<"$output")" = "$i" ]
    now=$expect; clock "$now"
    run ordo_scheduler_tick
    [ "$(jq -r '.picked[0].run_id' <<<"$output")" = "$id" ]
    [ "$(jq -r '.budgets.attempts_used' <<<"$(snap "$id")")" = "$((i + 2))" ]
  done
  now=$(date -u -d "$now + 60 seconds" +%Y-%m-%dT%H:%M:%SZ); clock "$now"
  run ordo_scheduler_tick
  [ "$(jq -r '.failed[0].reason' <<<"$output")" = "budget_exhausted" ]
  [ "$(jq -r '.failed[0].cause' <<<"$output")" = "lease_expired" ]
  [ "$(state "$id")" = "failed" ]
  local s; s=$(snap "$id")
  [ "$(jq -r .budgets.attempts_used <<<"$s")" = "4" ]
  [ "$(jq -c .budgets.exhausted <<<"$s")" = '["max_attempts"]' ]
  [ "$(jq -r .metadata.failure_reason <<<"$s")" = "budget_exhausted" ]
}

@test "a run past ORDO_SCHED_RUN_TIMEOUT_SEC is timed out: requeued or failed per ORDO_SCHED_TIMEOUT_POLICY (#810)" {
  export ORDO_SCHED_LEASE_TTL=7200
  local a; a=$(start --title timeout)
  clock 2026-09-11T10:59:59Z
  run ordo_scheduler_tick
  [ "$(jq -c .timed_out <<<"$output")" = "[]" ]
  clock 2026-09-11T11:00:00Z
  run ordo_scheduler_tick
  [ "$status" -eq 0 ]
  [ "$(jq -r '.timed_out[0].run_id' <<<"$output")" = "$a" ]
  [ "$(jq -r '.timed_out[0].action' <<<"$output")" = "requeued" ]
  [ "$(jq -r '.timed_out[0].reason' <<<"$output")" = "timeout" ]
  [ "$(jq -r '.timed_out[0].not_before' <<<"$output")" = "2026-09-11T11:00:30Z" ]
  [ "$(state "$a")" = "queued" ]
  [ "$(lease_states "$a")" = "released" ]
  # Resume resets the active clock: a run that waited two hours is not timed out right after resuming.
  clock 2026-09-11T11:00:30Z; ordo_scheduler_tick >/dev/null; [ "$(state "$a")" = "running" ]
  ordo_scheduler_wait "$a" --reason human >/dev/null
  clock 2026-09-11T13:30:00Z; ordo_scheduler_resume "$a" >/dev/null
  run ordo_scheduler_tick
  [ "$(jq -c .timed_out <<<"$output")" = "[]" ]
  [ "$(state "$a")" = "running" ]
  # Policy fail.
  clock 2026-09-11T14:30:00Z
  ORDO_SCHED_TIMEOUT_POLICY=fail run ordo_scheduler_tick
  [ "$(jq -r '.timed_out[0].action' <<<"$output")" = "failed" ]
  [ "$(state "$a")" = "failed" ]
  [ "$(jq -r .metadata.failure_reason <<<"$(snap "$a")")" = "timeout" ]
}

@test "queue TTL and wait deadlines expire runs (#810)" {
  local w; w=$(start --title wait --priority 0)
  ORDO_SCHED_WAIT_TIMEOUT_SEC=60 ordo_scheduler_wait "$w" --reason human >/dev/null
  [ "$(jq -r .metadata.wait_deadline <<<"$(snap "$w")")" = "2026-09-11T10:01:00Z" ]
  local p; p=$(start --title approval --priority 0)
  ordo_scheduler_require_approval "$p" --deadline 2026-09-11T10:03:00Z >/dev/null
  local q; q=$(ORDO_SCHED_QUEUE_TTL_SEC=120 enqueue --title ttl --priority 1)
  [ "$(jq -r .metadata.expires_at <<<"$(snap "$q")")" = "2026-09-11T10:02:00Z" ]
  export ORDO_SCHED_MAX_FANOUT=0          # no picks: only expiry housekeeping from here on
  clock 2026-09-11T10:01:00Z
  run ordo_scheduler_tick
  [ "$(jq -c '.expired | map([.run_id, .reason])' <<<"$output")" = "[[\"$w\",\"wait_timeout\"]]" ]
  [ "$(state "$w")" = "expired" ]
  clock 2026-09-11T10:03:00Z
  run ordo_scheduler_tick
  [ "$(jq -c '.expired | map(.reason) | sort' <<<"$output")" = '["queue_ttl","wait_timeout"]' ]
  [ "$(state "$p")" = "expired" ]; [ "$(state "$q")" = "expired" ]
}

# --- cancellation ------------------------------------------------------------

@test "cancel works from every non-terminal state, releases the lease and is refused on terminal runs (#810)" {
  export ORDO_SCHED_MAX_FANOUT=10
  local q l r w b a
  q=$(enqueue --title queued)
  # leased (never started): lease + run.leased by hand.
  l=$(enqueue --title leased)
  ordo_journal_lease_acquire "$l" "w1@h1:$$" >/dev/null
  ordo_journal_append "$l" run.leased '{}' >/dev/null
  r=$(start --title running --priority 0)
  w=$(start --title waiting --priority 0); ordo_scheduler_wait "$w" >/dev/null
  b=$(start --title blocked --priority 0); ordo_scheduler_block "$b" >/dev/null
  a=$(start --title approval --priority 0); ordo_scheduler_require_approval "$a" >/dev/null
  local id from
  for id in "$q" "$l" "$r" "$w" "$b" "$a"; do
    from=$(state "$id")
    run ordo_scheduler_cancel "$id" --reason "operator"
    [ "$status" -eq 0 ] || { echo "cancel from $from failed: $output"; false; }
    [ "$(jq -r .state <<<"$output")" = "cancelled" ]
    [ "$(jq -r .from <<<"$output")" = "$from" ]
    [ "$(state "$id")" = "cancelled" ]
    [ "$(jq -r .metadata.cancel_reason <<<"$(snap "$id")")" = "operator" ]
    [ -z "$(ordo_journal_lease_list "$id" | jq -r 'select(.state == "active" or .state == "renewed") | .id')" ]
  done
  [ "$(jq -r .released_lease_id <<<"$(ordo_journal_events "$r" | tail -n 1 | jq -c .payload)")" != "null" ]
  [ "$(lease_states "$r")" = "released" ]
  [ "$(lease_states "$l")" = "released" ]
  # Terminal runs refuse cancellation (5), nothing is appended.
  local n; n=$(ordo_journal_events "$r" | wc -l)
  run --separate-stderr ordo_scheduler_cancel "$r"
  [ "$status" -eq 5 ]; assert_error_line invalid_transition
  [ "$(printf '%s' "$stderr" | jq -r '.error.details.terminal')" = "true" ]
  [ "$(ordo_journal_events "$r" | wc -l)" -eq "$n" ]
  # Cancelled slots are free again.
  run ordo_scheduler_status
  [ "$(jq -r .capacity.in_use <<<"$output")" = "0" ]
}

# --- crash recovery ------------------------------------------------------------

@test "recover rebuilds projections and requeues runs whose local owner pid is gone, attempts preserved, no backoff (#810)" {
  ( sleep 0.05 ) & local dead=$!; wait "$dead" || true
  local d o rem parked
  d=$(ORDO_SCHED_WORKER_PID=$dead start --title dead --priority 0)
  o=$(start --title alive --priority 1)                                 # owned by this live shell
  rem=$(enqueue --title remote --priority 2)
  ordo_journal_lease_acquire "$rem" "w9@other-host:1" >/dev/null
  ordo_journal_append "$rem" run.leased '{}' >/dev/null
  parked=$(enqueue --title parked --priority 3)
  ordo_journal_append "$parked" run.leased '{}' >/dev/null
  ordo_journal_append "$parked" run.started '{}' >/dev/null
  ordo_journal_append "$parked" run.waiting '{}' >/dev/null
  ordo_journal_lease_acquire "$parked" "w1@h1:$$" >/dev/null           # invariant violation: parked run with a lease
  [ "$(jq -r '.lease.owner' <<<"$(snap "$d")")" = "w1@h1:$dead" ]
  clock 2026-09-11T10:00:10Z
  run ordo_scheduler_recover
  [ "$status" -eq 0 ]
  [ "$(jq -r .rebuilt <<<"$output")" = "4" ]
  [ "$(jq -c '.reconciled | map([.run_id, .action, .reason, .backoff_seconds])' <<<"$output")" = "[[\"$d\",\"requeued\",\"owner_dead\",0]]" ]
  [ "$(jq -r '.reconciled[0].not_before' <<<"$output")" = "2026-09-11T10:00:10Z" ]
  [ "$(jq -c '.remote | map(.run_id)' <<<"$output")" = "[\"$rem\"]" ]
  [ "$(jq -c '.repaired | map(.run_id)' <<<"$output")" = "[\"$parked\"]" ]
  [ "$(state "$d")" = "queued" ]
  [ "$(jq -r .budgets.attempts_used <<<"$(snap "$d")")" = "1" ]
  [ "$(lease_states "$d")" = "released" ]
  [ "$(state "$o")" = "running" ]; [ "$(lease_states "$o")" = "active" ]
  [ "$(state "$rem")" = "leased" ]; [ "$(lease_states "$rem")" = "active" ]
  [ "$(lease_states "$parked")" = "released" ]
  # The requeued run is picked by the next tick with attempt 2 (o and rem still hold two slots).
  ORDO_SCHED_MAX_FANOUT=3 run ordo_scheduler_tick
  [ "$(jq -r '.picked[0].run_id' <<<"$output")" = "$d" ]
  [ "$(jq -r '.picked[0].attempt_no' <<<"$output")" = "2" ]
  # A recover with nothing to do is a no-op.
  run ordo_scheduler_recover
  [ "$(jq -c '[.reconciled, .repaired] | map(length)' <<<"$output")" = "[0,0]" ]
}

# --- budgets -----------------------------------------------------------------------

@test "every budget dimension is enforced on heartbeat/usage: exit 7, run failed with reason budget_exhausted, lease released (#810)" {
  local dim id
  for dim in max_tokens:tokens:100 max_turns:turns:3 max_tool_calls:tool_calls:5 max_cost:cost:2; do
    local key=${dim%%:*} rest=${dim#*:} usage_key limit
    usage_key=${rest%%:*}; limit=${rest#*:}
    id=$(start --title "$key" --metadata "{\"budget\":{\"$key\":$limit}}")
    run ordo_scheduler_report_usage "$id" "{\"$usage_key\":$((limit - 1))}"
    [ "$status" -eq 0 ] || { echo "$key below limit: $output"; false; }
    run --separate-stderr ordo_scheduler_heartbeat "$id" --usage "{\"$usage_key\":1}"
    [ "$status" -eq 7 ] || { echo "$key: status=$status stderr=$stderr"; false; }
    assert_error_line budget_exhausted
    [ "$(printf '%s' "$stderr" | jq -c '.error.details.exhausted')" = "[\"$key\"]" ]
    [ "$(state "$id")" = "failed" ]
    [ "$(jq -r .metadata.failure_reason <<<"$(snap "$id")")" = "budget_exhausted" ]
    [ "$(lease_states "$id")" = "released" ]
    [ "$(ordo_journal_events "$id" | tail -n 1 | jq -r .type)" = "run.failed" ]
  done
  # Wall-clock (max_seconds) accumulates from heartbeats.
  id=$(start --title seconds --budget '{"max_seconds":100}')
  clock 2026-09-11T10:01:39Z
  run ordo_scheduler_heartbeat "$id"; [ "$status" -eq 0 ]
  clock 2026-09-11T10:01:40Z
  run --separate-stderr ordo_scheduler_heartbeat "$id"
  [ "$status" -eq 7 ]; assert_error_line budget_exhausted
  [ "$(printf '%s' "$stderr" | jq -c '.error.details.exhausted')" = '["max_seconds"]' ]
  [ "$(jq -r .budgets.seconds_used <<<"$(snap "$id")")" = "100" ]
  # report_usage enforces without a lease; on a queued run exhaustion expires it before any pick.
  id=$(enqueue --title prepick --budget '{"max_tokens":10}')
  run --separate-stderr ordo_scheduler_report_usage "$id" '{"tokens":10}'
  [ "$status" -eq 7 ]; assert_error_line budget_exhausted
  [ "$(state "$id")" = "expired" ]
  run ordo_scheduler_tick
  [ "$(jq -c '.picked' <<<"$output")" = "[]" ]
  # ordo_scheduler_budgets prints the verdict and exits 7 when exhausted.
  run --separate-stderr ordo_scheduler_budgets "$id"
  [ "$status" -eq 7 ]
  [ "$(jq -c .exhausted <<<"$output")" = '["max_tokens"]' ]
  # Global defaults apply when no override is given.
  ORDO_SCHED_BUDGET_MAX_TURNS=2 id=$(ORDO_SCHED_BUDGET_MAX_TURNS=2 start --title default)
  [ "$(jq -r .budgets.max_turns <<<"$(snap "$id")")" = "2" ]
}

@test "fan-out is a budget: resume re-leases only when a slot is free (exit 7 otherwise) and the tick never exceeds the limit (#810)" {
  export ORDO_SCHED_MAX_FANOUT=1
  local a b c
  a=$(start --title a --priority 0)
  b=$(enqueue --title b); c=$(enqueue --title c)
  run ordo_scheduler_tick
  [ "$(jq -r .picks <<<"$output")" = "0" ]
  ordo_scheduler_wait "$a" >/dev/null
  run --separate-stderr ordo_scheduler_resume "$a"
  [ "$status" -eq 0 ]                                            # slot free: re-leased
  ordo_scheduler_require_approval "$a" >/dev/null
  ordo_scheduler_tick >/dev/null; [ "$(state "$b")" = "running" ]; [ "$(state "$c")" = "queued" ]
  run --separate-stderr ordo_scheduler_resume "$a"
  [ "$status" -eq 7 ]; assert_error_line budget_exhausted
  [ "$(printf '%s' "$stderr" | jq -c '.error.details.exhausted')" = '["max_fanout"]' ]
  [ "$(state "$a")" = "approval_required" ]
  [ "$(ordo_journal_lease_list "$a" | jq -r .state | tail -n 1)" = "released" ]
  # --requeue never needs a slot.
  run ordo_scheduler_resume "$a" --requeue
  [ "$status" -eq 0 ]; [ "$(state "$a")" = "queued" ]
}

# --- human waits and readiness -------------------------------------------------------

@test "a run in waiting/blocked/approval_required holds no lease and no worker slot; capacity is reusable and resume re-leases (#810)" {
  export ORDO_SCHED_MAX_FANOUT=1
  local a b
  a=$(start --title a --priority 0)
  b=$(enqueue --title b)
  run ordo_scheduler_tick
  [ "$(jq -r '.skipped[0].reason' <<<"$output")" = "capacity_exhausted" ]
  local first_lease; first_lease=$(jq -r .lease.id <<<"$(snap "$a")")
  run ordo_scheduler_require_approval "$a" --action pr.merge --reason "needs a human"
  [ "$status" -eq 0 ]
  [ "$(jq -r .lease <<<"$output")" = "null" ]
  [ "$(jq -r .released_lease_id <<<"$output")" = "$first_lease" ]
  [ "$(state "$a")" = "approval_required" ]
  [ "$(ordo_journal_lease_get "$first_lease" | jq -r .state)" = "released" ]
  [ "$(jq -r '.lease.state' <<<"$(snap "$a")")" = "released" ]
  [ "$(jq -r '.metadata.lease_owner' <<<"$(snap "$a")")" = "null" ]
  run ordo_scheduler_status
  [ "$(jq -r .capacity.in_use <<<"$output")" = "0" ]
  [ "$(jq -r .capacity.available <<<"$output")" = "1" ]
  # The freed slot is used by the next tick; the parked run is not touched.
  run ordo_scheduler_tick
  [ "$(jq -r '.picked[0].run_id' <<<"$output")" = "$b" ]
  [ "$(state "$a")" = "approval_required" ]
  # No worker process is bound to a parked run: the runtime is never asked to start it.
  [ ! -e "$BATS_TEST_TMPDIR/rt-start" ]
  ordo_scheduler_complete "$b" >/dev/null
  clock 2026-09-11T10:30:00Z
  run ordo_scheduler_resume "$a" --reason approved
  [ "$status" -eq 0 ]
  [ "$(jq -r .state <<<"$output")" = "running" ]
  [ "$(jq -r .lease_id <<<"$output")" != "$first_lease" ]
  [ "$(jq -r .resumed <<<"$output")" = "true" ]
  local s; s=$(snap "$a")
  [ "$(jq -r .lease.state <<<"$s")" = "acquired" ]
  [ "$(jq -r .lease.owner <<<"$s")" = "w1@h1:$$" ]
  [ "$(jq -r .budgets.attempts_used <<<"$s")" = "1" ]              # a resume is not a new attempt
  [ "$(jq -r .metadata.active_since <<<"$s")" = "2026-09-11T10:30:00Z" ]
  [ "$(ordo_journal_events "$a" | jq -r .type | tail -n 2 | paste -sd, -)" = "lease.acquired,run.resumed" ]
  # The same holds for waiting and blocked.
  ordo_scheduler_wait "$a" >/dev/null;  [ "$(lease_states "$a" | tr ',' '\n' | tail -n 1)" = "released" ]
  ordo_scheduler_resume "$a" >/dev/null
  ordo_scheduler_block "$a" >/dev/null; [ "$(lease_states "$a" | tr ',' '\n' | tail -n 1)" = "released" ]
  run ordo_scheduler_status
  [ "$(jq -r .capacity.in_use <<<"$output")" = "0" ]
}

@test "readiness is explicit and fail-closed: unknown or missing dependency/provider state never becomes ready (#810)" {
  local u m d k ok f
  u=$(enqueue --title unknown --readiness '{"state":"unknown","source":"provider"}' --priority 0)
  m=$(enqueue --title malformed --readiness '{"checked_at":"x"}' --priority 0)
  d=$(enqueue --title dep-unknown --depends-on run_000000000000000000000000 --priority 0)
  ok=$(enqueue --title ready --readiness '{"state":"ready","source":"provider"}' --priority 5)
  run ordo_scheduler_tick
  [ "$status" -eq 0 ]
  [ "$(jq -c '.picked | map(.run_id)' <<<"$output")" = "[\"$ok\"]" ]
  [ "$(jq -r --arg r "$u" '.skipped[] | select(.run_id == $r) | .reason' <<<"$output")" = "readiness_unknown" ]
  [ "$(jq -r --arg r "$m" '.skipped[] | select(.run_id == $r) | .reason' <<<"$output")" = "readiness_unknown" ]
  [ "$(jq -r --arg r "$d" '.skipped[] | select(.run_id == $r) | .reason' <<<"$output")" = "dependency_unknown" ]
  [ "$(state "$u")" = "queued" ]; [ "$(state "$d")" = "queued" ]
  run --separate-stderr ordo_scheduler_ready "$u"
  [ "$status" -eq 3 ]; assert_error_line fail_closed
  [ "$(jq -r .reason <<<"$output")" = "readiness_unknown" ]
  # A dependency that is not succeeded keeps the dependant unready; a succeeded one frees it.
  k=$(enqueue --title dep-pending --depends-on "$ok" --priority 1)
  run --separate-stderr ordo_scheduler_ready "$k"
  [ "$status" -eq 3 ]; [ "$(jq -r .reason <<<"$output")" = "dependency_running" ]
  ordo_scheduler_complete "$ok" >/dev/null
  run ordo_scheduler_ready "$k"
  [ "$status" -eq 0 ]; [ "$(jq -r .reason <<<"$output")" = "ready" ]
  f=$(enqueue --title dep-failed --depends-on "$u" --priority 1)
  ordo_scheduler_cancel "$u" >/dev/null
  run --separate-stderr ordo_scheduler_ready "$f"
  [ "$status" -eq 3 ]; [ "$(jq -r .reason <<<"$output")" = "dependency_cancelled" ]
  # ORDO_SCHED_REQUIRE_READINESS=1: a run without any readiness record is not ready.
  local plain; plain=$(enqueue --title plain --priority 0)
  ORDO_SCHED_REQUIRE_READINESS=1 run --separate-stderr ordo_scheduler_ready "$plain"
  [ "$status" -eq 3 ]; [ "$(jq -r .reason <<<"$output")" = "readiness_missing" ]
  ORDO_SCHED_REQUIRE_READINESS=1 run ordo_scheduler_tick
  [ "$(jq -r --arg r "$plain" '.skipped[] | select(.run_id == $r) | .reason' <<<"$output")" = "readiness_missing" ]
  [ "$(state "$plain")" = "queued" ]
  # A blocked run whose dependency state became unknown stays blocked: resume is refused (3), no lease.
  local b; b=$(start --title blocked --priority 0)
  ordo_scheduler_block "$b" --reason "provider outage" --type provider >/dev/null
  ordo_journal_append "$b" run.updated '{"metadata":{"readiness":{"state":"unknown"}}}' >/dev/null
  run --separate-stderr ordo_scheduler_resume "$b"
  [ "$status" -eq 3 ]; assert_error_line fail_closed
  [ "$(printf '%s' "$stderr" | jq -r '.error.details.reason')" = "readiness_unknown" ]
  [ "$(state "$b")" = "blocked" ]
  [ "$(lease_states "$b" | tr ',' '\n' | tail -n 1)" = "released" ]
  run ordo_scheduler_tick
  [ "$(jq -r --arg b "$b" '.picked | map(.run_id) | index($b)' <<<"$output")" = "null" ]
  [ "$(state "$b")" = "blocked" ]
  # Any foreign open blocker also keeps a run parked; the scheduler's own blocker does not.
  ordo_journal_append "$b" run.updated '{"metadata":{"readiness":{"state":"ready"}}}' >/dev/null
  ordo_journal_append "$b" blocker.raised '{"id":"ext-1","type":"ci","severity":"blocking","summary":"red"}' >/dev/null
  run --separate-stderr ordo_scheduler_resume "$b"
  [ "$status" -eq 3 ]; [ "$(printf '%s' "$stderr" | jq -r '.error.details.reason')" = "blockers_open" ]
  ordo_journal_append "$b" blocker.resolved '{"id":"ext-1"}' >/dev/null
  ORDO_SCHED_MAX_FANOUT=10 run ordo_scheduler_resume "$b"        # other ready runs occupy the default slots
  [ "$status" -eq 0 ]; [ "$(state "$b")" = "running" ]
  [ "$(jq -r .counters.blockers_open <<<"$(snap "$b")")" = "0" ]
}

# --- runtime indirection -------------------------------------------------------------

@test "ordo_scheduler_runtime is a no-op with the fake adapter or without the adapter library, and tick starts a runtime target only through it (#810)" {
  run ordo_scheduler_runtime start pane:0.0 --text hi
  [ "$status" -eq 0 ]
  [ "$(jq -r .noop <<<"$output")" = "true" ]
  [ "$(jq -r .adapter <<<"$output")" = "fake" ]
  # Library absent: still a no-op (the indirection never hard-depends on #811).
  no_lib() { _ORDO_SCHEDULER_LIB_DIR="$BATS_TEST_TMPDIR/nolib" ORDO_RUNTIME_ADAPTER=tmux ordo_scheduler_runtime start t --text x; }
  mkdir -p "$BATS_TEST_TMPDIR/nolib"
  run no_lib
  [ "$status" -eq 0 ]
  [ "$(jq -r .noop <<<"$output")" = "true" ]
  [ "$(jq -r .adapter <<<"$output")" = "tmux" ]
  # With a runtime target the pick goes through the indirection (a stub here) and a failure requeues the run.
  printf 'brief\n' > "$BATS_TEST_TMPDIR/brief.md"
  local id; id=$(enqueue --title rt --runtime-target fleet-001:0.0 --text-file "$BATS_TEST_TMPDIR/brief.md")
  [ "$(jq -c .metadata.runtime <<<"$(snap "$id")")" = "{\"target\":\"fleet-001:0.0\",\"text_file\":\"$BATS_TEST_TMPDIR/brief.md\"}" ]
  ordo_scheduler_runtime() { printf '%s\n' "$*" >> "$BATS_TEST_TMPDIR/rt-calls"; return 1; }
  run ordo_scheduler_tick
  [ "$status" -eq 0 ]
  [ "$(cat "$BATS_TEST_TMPDIR/rt-calls")" = "start fleet-001:0.0 --text-file $BATS_TEST_TMPDIR/brief.md" ]
  [ "$(jq -r '.errors[0].step' <<<"$output")" = "start" ]
  [ "$(state "$id")" = "queued" ]
  [ "$(jq -r .metadata.requeue_reason <<<"$(snap "$id")")" = "runtime_start_failed" ]
  [ "$(lease_states "$id")" = "released" ]
  ordo_scheduler_runtime() { printf '%s\n' "$*" >> "$BATS_TEST_TMPDIR/rt-calls"; printf '{"ok":true}\n'; }
  clock 2026-09-11T10:00:30Z
  run ordo_scheduler_tick
  [ "$(jq -r '.picked[0].run_id' <<<"$output")" = "$id" ]
  ordo_scheduler_cancel "$id" >/dev/null
  [ "$(tail -n 1 "$BATS_TEST_TMPDIR/rt-calls")" = "stop fleet-001:0.0" ]
}

# --- operator script -----------------------------------------------------------------

write_project_config() {
  cat > "$BATS_TEST_TMPDIR/p.config.sh" <<EOF
PROJECT="$PROJECT"
GH_REPO="owner/repo"
DEFAULT_BRANCH="main"
GH_CONFIG_DIR="$GH_CONFIG_DIR"
AGENT_REPO_PREFIX="$BATS_TEST_TMPDIR/repos/"
AGENT_WORKDIR_TEMPLATE="$AGENT_WORKDIR_TEMPLATE"
AGENT_PANES=("fleet-001|s:0.0|$BATS_TEST_TMPDIR/repos/fleet-001")
EOF
  printf '%s' "$BATS_TEST_TMPDIR/p.config.sh"
}

@test "scripts/ordo_scheduler.sh: commands, command word anywhere after the project, --json passthrough, exit codes 2/4/5/7/8 (#810)" {
  local cfg; cfg=$(write_project_config)
  local S="$TK/scripts/ordo_scheduler.sh"
  [ -x "$S" ]
  run --separate-stderr bash "$S" "$cfg" enqueue --title A --priority 1 --json
  [ "$status" -eq 0 ]
  local a; a=$(jq -r .run_id <<<"$output")
  [ "$(jq -r .state <<<"$output")" = "queued" ]
  [ "$(jq -r '.actor.type' <<<"$(ordo_journal_events "$a")")" = "operator" ]
  bash "$S" "$cfg" enqueue --title B --priority 2 >/dev/null 2>&1
  run --separate-stderr bash "$S" "$cfg" run-once --json
  [ "$status" -eq 0 ]
  [ "$(jq -r .picks <<<"$output")" = "1" ]
  [ "$(jq -r '.picked[0].run_id' <<<"$output")" = "$a" ]
  [ "$(jq -r '.picked[0].owner' <<<"$output")" = "w1@h1:$$" ]      # pid = parent of the script (this shell)
  run --separate-stderr bash "$S" "$cfg" status
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == "scheduler status now=2026-09-11T10:00:00Z worker=w1@h1:$$ capacity=1/2 available=1" ]]
  [[ "${lines[1]}" == "counts: queued=1 running=1" ]]
  run --separate-stderr bash "$S" "$cfg" tick
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == tick\ now=2026-09-11T10:00:00Z*picked=1* ]]
  # The command word may come last (that is how the `ordo` CLI appends it).
  run --separate-stderr bash "$S" "$cfg" "$a" --reason human wait 2>/dev/null
  [ "$status" -eq 2 ]                                              # `wait` is not an operator command
  ordo_scheduler_wait "$a" >/dev/null
  run --separate-stderr bash "$S" "$cfg" "$a" --reason go resume --json
  [ "$status" -eq 0 ]
  [ "$(jq -r .state <<<"$output")" = "running" ]
  run --separate-stderr bash "$S" "$cfg" resume "$a"
  [ "$status" -eq 5 ]; assert_error_line invalid_transition
  run --separate-stderr bash "$S" "$cfg" cancel "$a" --reason done
  [ "$status" -eq 0 ]
  [ "$output" = "$a cancelled reason=done" ]
  run --separate-stderr bash "$S" "$cfg" cancel "$a"
  [ "$status" -eq 5 ]; assert_error_line invalid_transition
  run --separate-stderr bash "$S" "$cfg" cancel run_000000000000000000000000
  [ "$status" -eq 4 ]; assert_error_line not_found
  run --separate-stderr bash "$S" "$cfg" cancel
  [ "$status" -eq 2 ]; assert_error_line usage
  run --separate-stderr bash "$S" "$cfg"
  [ "$status" -eq 2 ]
  run --separate-stderr bash "$S" "$cfg" frobnicate
  [ "$status" -eq 2 ]
  run --separate-stderr bash "$S" "$BATS_TEST_TMPDIR/missing.config.sh" status
  [ "$status" -eq 4 ]
  # 7 and 8 surface unchanged from the library.
  local b; b=$(ordo_journal_runs --state running | jq -r .run_id)
  ORDO_SCHED_WORKER_ID=w2 run --separate-stderr ordo_scheduler_heartbeat "$b"
  [ "$status" -eq 8 ]
  ORDO_SCHED_MAX_FANOUT=0 run --separate-stderr bash "$S" "$cfg" resume "$b" 2>/dev/null
  [ "$status" -eq 5 ]                                              # running -> resume is a transition error, not a budget one
  ordo_scheduler_wait "$b" >/dev/null
  ORDO_SCHED_MAX_FANOUT=0 run --separate-stderr bash "$S" "$cfg" resume "$b"
  [ "$status" -eq 7 ]; assert_error_line budget_exhausted
  run --separate-stderr bash "$S" "$cfg" recover --json
  [ "$status" -eq 0 ]
  [ "$(jq -r .rebuilt <<<"$output")" = "2" ]
  run bash "$S" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"tick [--max-picks N]"* ]]
}

# --- journal additions used by the scheduler -----------------------------------------

@test "ordo_journal_runs lists projections in enqueue order with a state filter; run.* events merge payload.metadata (#810)" {
  local a b c
  a=$(enqueue --title a); b=$(enqueue --title b); c=$(enqueue --title c)
  [ "$(ordo_journal_runs | jq -r .run_id | paste -sd, -)" = "$a,$b,$c" ]
  ordo_scheduler_cancel "$b" >/dev/null
  [ "$(ordo_journal_runs --state queued | jq -r .run_id | paste -sd, -)" = "$a,$c" ]
  [ "$(ordo_journal_runs --state cancelled,queued | jq -r .run_id | paste -sd, -)" = "$a,$b,$c" ]
  [ -z "$(ordo_journal_runs --state running)" ]
  run --separate-stderr ordo_journal_runs --bogus
  [ "$status" -eq 2 ]
  ordo_journal_append "$a" run.leased '{"metadata":{"k":"v","priority":3}}' >/dev/null
  [ "$(jq -c '.metadata | {k, priority}' <<<"$(snap "$a")")" = '{"k":"v","priority":3}' ]
  ordo_journal_append "$a" run.budget '{"budget":{"max_turns":9,"max_cost":1.5},"usage":{"turns":2,"tool_calls":4,"cost":0.25}}' >/dev/null
  [ "$(jq -c '.budgets | {max_turns, max_cost, turns_used, tool_calls_used, cost_used, exhausted}' <<<"$(snap "$a")")" = '{"max_turns":9,"max_cost":1.5,"turns_used":2,"tool_calls_used":4,"cost_used":0.25,"exhausted":[]}' ]
}

# --- orch_loop opt-in hook ------------------------------------------------------------

@test "orch_loop.sh runs one scheduler tick per cycle only when ORDO_SCHEDULER_ENABLED=1 (default off, daemon confirmation untouched) (#810)" {
  local loop="$TK/scripts/orch_loop.sh"
  grep -q '^require_daemon_confirmation$' "$loop"
  grep -q '^orch_scheduler_tick_step() {' "$loop"
  # shellcheck disable=SC2016
  grep -q 'orch_scheduler_tick_step "\$cycle"' "$loop"
  # shellcheck disable=SC2016
  grep -q 'if \[\[ "\${ORDO_SCHEDULER_ENABLED:-0}" == "1" \]\]; then' "$loop"
  grep -q 'audit_blocked_dispatch scheduler-tick' "$loop"
  local helpers="$BATS_TEST_TMPDIR/hook.sh"
  awk '/^orch_scheduler_tick_step\(\) \{/ { in_fn = 1 } in_fn { print } in_fn && /^\}$/ { in_fn = 0 }' "$loop" > "$helpers"
  [ -s "$helpers" ]
  local tk="$BATS_TEST_TMPDIR/tk"
  mkdir -p "$tk/scripts"
  cat > "$tk/scripts/ordo_scheduler.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$BATS_TEST_TMPDIR/tick-calls"
printf 'worker=%s pid=%s\n' "\$ORDO_SCHED_WORKER_ID" "\$ORDO_SCHED_WORKER_PID" >> "$BATS_TEST_TMPDIR/tick-env"
[[ "\${TICK_FAIL:-0}" == 1 ]] && exit 7
printf '{"picks":1,"slots_used_before":0,"capacity":2,"expired_leases":[],"requeued":[],"failed":[],"timed_out":[],"heartbeats":[],"errors":[]}\n'
EOF
  chmod +x "$tk/scripts/ordo_scheduler.sh"
  run_hook() {
    (
      # shellcheck disable=SC1090
      source "$TK/lib/process_safety.sh"
      TK="$tk" PROJECT="$PROJECT" PROJECT_ARG="$PROJECT" LOOP_LOG="$BATS_TEST_TMPDIR/loop.log"
      unset ORDO_SCHED_WORKER_ID ORDO_SCHED_WORKER_PID      # prove the hook's own defaults
      audit() { printf 'AUDIT %s\n' "$*" >> "$BATS_TEST_TMPDIR/hook-audit.log"; }
      # shellcheck disable=SC1090
      source "$helpers"
      "$@"
    )
  }
  # Default off: nothing runs, nothing is audited.
  unset ORDO_SCHEDULER_ENABLED
  run_hook orch_scheduler_tick_step 1
  [ ! -e "$BATS_TEST_TMPDIR/tick-calls" ]
  [ ! -e "$BATS_TEST_TMPDIR/hook-audit.log" ]
  ORDO_SCHEDULER_ENABLED=0 run_hook orch_scheduler_tick_step 2
  [ ! -e "$BATS_TEST_TMPDIR/tick-calls" ]
  # Opt-in: one tick per call, audited, owner = the loop.
  ORDO_SCHEDULER_ENABLED=1 run_hook orch_scheduler_tick_step 3
  [ "$(cat "$BATS_TEST_TMPDIR/tick-calls")" = "$PROJECT tick --json" ]
  grep -q '^worker=orch-loop pid=[0-9]\+$' "$BATS_TEST_TMPDIR/tick-env"
  grep -q 'ORCH_LOOP SCHEDULER_TICK OK cycle=3 project='"$PROJECT"' picked=1 slots_used=0 capacity=2' "$BATS_TEST_TMPDIR/hook-audit.log"
  # A failing tick is a warning, never a loop failure.
  TICK_FAIL=1 ORDO_SCHEDULER_ENABLED=1 run_hook orch_scheduler_tick_step 4
  grep -q 'ORCH_LOOP SCHEDULER_TICK WARN cycle=4 project='"$PROJECT"' rc=7 (cycle continues)' "$BATS_TEST_TMPDIR/hook-audit.log"
  [ "$(wc -l < "$BATS_TEST_TMPDIR/tick-calls")" -eq 2 ]
}
