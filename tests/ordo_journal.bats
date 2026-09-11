#!/usr/bin/env bats
# tests/ordo_journal.bats — SQLite event journal and projections (#808, epic #806).
#
# Covers lib/ordo_journal.sh:
#   - idempotent schema init (WAL, versioned migrations);
#   - append: contract validation, gapless run_seq, idempotency keys;
#   - projection fold semantics (state table, blockers, budgets) and purity;
#   - crash safety (fault hook before COMMIT: raise / SIGKILL);
#   - concurrency: 8 parallel appenders, idempotency-key race;
#   - compat export reproducing the legacy assignments.json byte-for-byte;
#   - lease and approval CRUD incl. stale-lease expiry;
#   - error objects and exit codes (2, 4, 5, 6, 8).

bats_require_minimum_version 1.5.0

load './helpers.bash'

setup() {
  setup_orch_test
  # shellcheck disable=SC1090
  source "$TK/lib/audit_log.sh"
  # shellcheck disable=SC1090
  source "$TK/lib/state_persist.sh"
  # shellcheck disable=SC1090
  source "$TK/lib/ordo_journal.sh"
  export ORDO_JOURNAL_NOW=""
  export ORDO_JOURNAL_FAULT=""
  RUN=$(ordo_contracts_new_id run)
  export RUN
  ordo_journal_init >/dev/null
}

# Assert that $stderr holds exactly one JSON error line with the given code
# (module defaults to journal; contracts errors surface with module contracts).
assert_error_line() {
  local code="$1" module="${2:-journal}"
  [ "$(printf '%s\n' "$stderr" | grep -c .)" -eq 1 ] || { echo "stderr: $stderr"; return 1; }
  [ "$(printf '%s' "$stderr" | jq -r '.error.code')" = "$code" ] || { echo "stderr: $stderr"; return 1; }
  [ "$(printf '%s' "$stderr" | jq -r '.error.module')" = "$module" ]
  [ -n "$(printf '%s' "$stderr" | jq -r '.error.message')" ]
  printf '%s' "$stderr" | jq -e '.error.details | type == "object"' >/dev/null
}

# Query the journal DB directly (test-side, stdlib sqlite3) for assertions
# that must not go through the library under test.
db_query() {
  python3 - "$(ordo_journal_db_path)" "$1" <<'PY'
import sqlite3, sys, json
conn = sqlite3.connect(sys.argv[1], isolation_level=None)
for row in conn.execute(sys.argv[2]):
    print(json.dumps(list(row)))
PY
}

seed_run() {
  # queued -> leased -> running with a dispatch record on the run.
  ordo_journal_append "$RUN" run.created '{"title":"Widget","ticket_ref":"owner/repo#42","project":"demo","budget":{"max_attempts":2,"max_tokens":100},"dispatch":{"agent":"fleet-001","ticket":"42","branch":"feat/widget","workdir":"/work/fleet-001","repo_root":"/work/fleet-001","prompt_file":"/tmp/p.md","dispatched_at":"2026-09-11T05:00:00Z","head_at_dispatch":"abc123"}}' >/dev/null
  ordo_journal_append "$RUN" run.leased '{"lease_id":"lease_000000000000000000000001"}' >/dev/null
  ordo_journal_append "$RUN" run.started '{}' >/dev/null
}

# --- init ---------------------------------------------------------------------

@test "init creates the DB under state_dir in WAL mode with a versioned migration (#808)" {
  local db
  db=$(ordo_journal_db_path)
  [ "$db" = "$(state_dir)/ordo-journal.sqlite" ]
  [ -f "$db" ]
  run ordo_journal_init
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.journal_mode')" = "wal" ]
  [ "$(printf '%s' "$output" | jq -r '.schema_version')" = "1" ]
  [ "$(db_query 'SELECT version FROM schema_migrations' | jq -c .)" = "[1]" ]
  [ "$(db_query 'PRAGMA user_version' | jq -c .)" = "[1]" ]
  # Idempotent: a third init changes nothing.
  local before after
  before=$(db_query "SELECT name FROM sqlite_master WHERE type IN ('table','index') ORDER BY name")
  ordo_journal_init >/dev/null
  after=$(db_query "SELECT name FROM sqlite_master WHERE type IN ('table','index') ORDER BY name")
  [ "$before" = "$after" ]
  printf '%s\n' "$before" | grep -q '"events"'
  printf '%s\n' "$before" | grep -q '"projections"'
  printf '%s\n' "$before" | grep -q '"leases"'
  printf '%s\n' "$before" | grep -q '"approvals"'
}

@test "ORDO_JOURNAL_DB overrides the DB location (#808)" {
  export ORDO_JOURNAL_DB="$BATS_TEST_TMPDIR/elsewhere/j.sqlite"
  run ordo_journal_init
  [ "$status" -eq 0 ]
  [ -f "$ORDO_JOURNAL_DB" ]
  [ "$(ordo_journal_db_path)" = "$ORDO_JOURNAL_DB" ]
}

# --- append / events ------------------------------------------------------------

@test "append assigns a gapless run_seq, prints a valid event contract and events replays them in order (#808)" {
  local i ev
  for i in 1 2 3; do
    ev=$(ordo_journal_append "$RUN" "step.$i" "{\"n\":$i}")
    [ "$(printf '%s' "$ev" | jq -r '.run_seq')" = "$i" ]
    [ "$(printf '%s' "$ev" | jq -r '.type')" = "step.$i" ]
    [ "$(printf '%s' "$ev" | jq -r '.run_id')" = "$RUN" ]
    [ "$(printf '%s' "$ev" | jq -r '.correlation_id')" = "$RUN" ]
    [ "$(printf '%s' "$ev" | jq -r '.actor.type')" = "system" ]
    ordo_contracts_validate event "$ev"
  done
  run ordo_journal_events "$RUN"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 3 ]
  [ "$(printf '%s\n' "$output" | jq -r '.run_seq' | tr '\n' ' ')" = "1 2 3 " ]
  [ "$(printf '%s\n' "$output" | jq -r '.payload.n' | tr '\n' ' ')" = "1 2 3 " ]
  # events prints exactly what append printed.
  [ "${lines[2]}" = "$ev" ]
  run ordo_journal_events "$RUN" --since 2
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [ "$(printf '%s' "$output" | jq -r '.run_seq')" = "3" ]
  run ordo_journal_events "$RUN" --since 3
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "append honours --actor, --mutation, --correlation-id and --metadata (#808)" {
  run ordo_journal_append "$RUN" pr.commented '{"pr":7}' --mutation --idempotency-key mut-1 \
    --actor '{"type":"agent","id":"fleet-002"}' --correlation-id corr-xyz --metadata '{"source":"test"}'
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.mutation')" = "true" ]
  [ "$(printf '%s' "$output" | jq -r '.idempotency_key')" = "mut-1" ]
  [ "$(printf '%s' "$output" | jq -r '.actor.id')" = "fleet-002" ]
  [ "$(printf '%s' "$output" | jq -r '.correlation_id')" = "corr-xyz" ]
  [ "$(printf '%s' "$output" | jq -r '.metadata.source')" = "test" ]
  [ "$(db_query "SELECT mutation, actor_json FROM events" | jq -c .)" = '[1,"{\"id\":\"fleet-002\",\"type\":\"agent\"}"]' ]
}

@test "append accepts payload from stdin (-) and @file (#808)" {
  printf '{"via":"stdin"}' > "$BATS_TEST_TMPDIR/p.json"
  run ordo_journal_append "$RUN" a.b "@$BATS_TEST_TMPDIR/p.json"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.payload.via')" = "stdin" ]
  pipe_append() { printf '{"via":"pipe"}' | ordo_journal_append "$RUN" a.c -; }
  run pipe_append
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.payload.via')" = "pipe" ]
}

@test "append rejects invalid input with usage (2) or invalid contract (5) errors and appends nothing (#808)" {
  run --separate-stderr ordo_journal_append "$RUN"
  [ "$status" -eq 2 ]; assert_error_line usage
  run --separate-stderr ordo_journal_append "$RUN" a.b '{}' --bogus
  [ "$status" -eq 2 ]; assert_error_line usage
  run --separate-stderr ordo_journal_append not-a-run a.b '{}'
  [ "$status" -eq 2 ]; assert_error_line bad_argument
  run --separate-stderr ordo_journal_append "$RUN" 'Bad Type' '{}'
  [ "$status" -eq 5 ]; assert_error_line invalid_contract
  printf '%s' "$stderr" | jq -e '.error.details.errors | length >= 1' >/dev/null
  run --separate-stderr ordo_journal_append "$RUN" a.b '{not json'
  [ "$status" -eq 5 ]; assert_error_line invalid_json
  run --separate-stderr ordo_journal_append "$RUN" a.b '[1,2]'
  [ "$status" -eq 5 ]; assert_error_line invalid_contract
  # mutation=true requires an idempotency key (contract rule).
  run --separate-stderr ordo_journal_append "$RUN" a.b '{}' --mutation
  [ "$status" -eq 5 ]; assert_error_line invalid_contract
  run --separate-stderr ordo_journal_append "$RUN" a.b '{}' --actor '{"type":"model"}'
  [ "$status" -eq 5 ]; assert_error_line invalid_contract
  [ "$(db_query 'SELECT COUNT(*) FROM events' | jq -c .)" = "[0]" ]
}

@test "duplicate idempotency key exits 5 duplicate_event, prints the existing event and appends nothing (#808)" {
  local first
  first=$(ordo_journal_append "$RUN" pr.created '{"pr":1}' --idempotency-key pr-create-1)
  run --separate-stderr ordo_journal_append "$RUN" pr.created '{"pr":"different"}' --idempotency-key pr-create-1
  [ "$status" -eq 5 ]
  [ "$output" = "$first" ]
  assert_error_line duplicate_event
  [ "$(printf '%s' "$stderr" | jq -r '.error.details.idempotency_key')" = "pr-create-1" ]
  [ "$(printf '%s' "$stderr" | jq -r '.error.details.existing_run_seq')" = "1" ]
  # Same key on another run is still a duplicate: keys are global.
  local other
  other=$(ordo_contracts_new_id run)
  run --separate-stderr ordo_journal_append "$other" pr.created '{}' --idempotency-key pr-create-1
  [ "$status" -eq 5 ]; assert_error_line duplicate_event
  [ "$(db_query 'SELECT COUNT(*) FROM events' | jq -c .)" = "[1]" ]
  # The next append continues the sequence without a gap.
  run ordo_journal_append "$RUN" pr.updated '{}'
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.run_seq')" = "2" ]
}

@test "events / state / project on an unknown run exit 4 not_found (#808)" {
  local ghost=run_000000000000000000000000
  run --separate-stderr ordo_journal_events "$ghost"
  [ "$status" -eq 4 ]; [ -z "$output" ]; assert_error_line not_found
  run --separate-stderr ordo_journal_state "$ghost"
  [ "$status" -eq 4 ]; assert_error_line not_found
  run --separate-stderr ordo_journal_project "$ghost"
  [ "$status" -eq 4 ]; assert_error_line not_found
  run --separate-stderr ordo_journal_events "$RUN" --since x
  [ "$status" -eq 2 ]; assert_error_line bad_argument
  run --separate-stderr ordo_journal_state
  [ "$status" -eq 2 ]; assert_error_line usage
}

# --- projection -------------------------------------------------------------------

@test "project folds the run state table, counters, budgets and last_event (#808)" {
  seed_run
  ordo_journal_append "$RUN" attempt.started '{"attempt_id":"attempt_000000000000000000000001","usage":{"tokens":60,"seconds":5}}' >/dev/null
  ordo_journal_append "$RUN" attempt.started '{"usage":{"tokens":50}}' >/dev/null
  run ordo_journal_state "$RUN"
  [ "$status" -eq 0 ]; [ "$output" = "running" ]
  run ordo_journal_project "$RUN"
  [ "$status" -eq 0 ]
  local snap="$output"
  [ "$(jq -r '.state' <<<"$snap")" = "running" ]
  [ "$(jq -r '.terminal' <<<"$snap")" = "false" ]
  [ "$(jq -r '.run_id' <<<"$snap")" = "$RUN" ]
  [ "$(jq -r '.project' <<<"$snap")" = "$PROJECT" ]
  [ "$(jq -r '.title' <<<"$snap")" = "Widget" ]
  [ "$(jq -r '.ticket_ref' <<<"$snap")" = "owner/repo#42" ]
  [ "$(jq -r '.event_count' <<<"$snap")" = "5" ]
  [ "$(jq -r '.last_run_seq' <<<"$snap")" = "5" ]
  [ "$(jq -r '.last_event.type' <<<"$snap")" = "attempt.started" ]
  [ "$(jq -r '.last_event.run_seq' <<<"$snap")" = "5" ]
  [ "$(jq -r '.counters.events' <<<"$snap")" = "5" ]
  [ "$(jq -r '.counters.transitions' <<<"$snap")" = "2" ]
  [ "$(jq -r '.counters.invalid_transitions' <<<"$snap")" = "0" ]
  [ "$(jq -r '.counters.attempts' <<<"$snap")" = "2" ]
  [ "$(jq -r '.counters.by_type["attempt.started"]' <<<"$snap")" = "2" ]
  [ "$(jq -c '.transitions | map([.from, .to])' <<<"$snap")" = '[["queued","leased"],["leased","running"]]' ]
  [ "$(jq -r '.budgets.max_attempts' <<<"$snap")" = "2" ]
  [ "$(jq -r '.budgets.attempts_used' <<<"$snap")" = "2" ]
  [ "$(jq -r '.budgets.tokens_used' <<<"$snap")" = "110" ]
  [ "$(jq -r '.budgets.seconds_used' <<<"$snap")" = "5" ]
  [ "$(jq -c '.budgets.exhausted' <<<"$snap")" = '["max_attempts","max_tokens"]' ]
  [ "$(jq -r '.dispatch.agent' <<<"$snap")" = "fleet-001" ]
  [ "$(jq -r '.created_at' <<<"$snap")" != "null" ]
  [ "$(jq -r '.updated_at' <<<"$snap")" != "null" ]
  # Terminal state.
  ordo_journal_append "$RUN" run.succeeded '{}' >/dev/null
  [ "$(ordo_journal_state "$RUN")" = "succeeded" ]
  [ "$(ordo_journal_project "$RUN" | jq -r '.terminal')" = "true" ]
  # run.transition with an explicit target is honoured too.
  local r2
  r2=$(ordo_contracts_new_id run)
  ordo_journal_append "$r2" run.transition '{"to":"cancelled"}' >/dev/null
  [ "$(ordo_journal_state "$r2")" = "cancelled" ]
}

@test "project records invalid or unknown transitions as open blockers instead of crashing (#808)" {
  seed_run
  ordo_journal_append "$RUN" run.requeued '{}' >/dev/null           # running -> queued: not allowed
  ordo_journal_append "$RUN" run.transition '{"to":"bogus"}' >/dev/null
  ordo_journal_append "$RUN" run.transition '{}' >/dev/null           # missing target
  ordo_journal_append "$RUN" blocker.raised '{"id":"ci-red","type":"ci","severity":"blocking","summary":"CI is red"}' >/dev/null
  ordo_journal_append "$RUN" run.waiting '{}' >/dev/null             # still valid from running
  run ordo_journal_project "$RUN"
  [ "$status" -eq 0 ]
  local snap="$output"
  [ "$(jq -r '.state' <<<"$snap")" = "waiting" ]
  [ "$(jq -r '.counters.invalid_transitions' <<<"$snap")" = "3" ]
  [ "$(jq -r '.counters.transitions' <<<"$snap")" = "3" ]
  [ "$(jq -r '.counters.blockers_open' <<<"$snap")" = "4" ]
  [ "$(jq -c '.blockers | map(.type)' <<<"$snap")" = '["invalid_transition","unknown_state","unknown_state","ci"]' ]
  [ "$(jq -r '.blockers[0].from' <<<"$snap")" = "running" ]
  [ "$(jq -r '.blockers[0].to' <<<"$snap")" = "queued" ]
  [ "$(jq -r '.blockers[0].run_seq' <<<"$snap")" = "4" ]
  jq -e '.blockers | all(.state == "open")' <<<"$snap" >/dev/null
  # Contracts library agrees that the recorded transition is invalid.
  run ordo_contracts_transition run running queued
  [ "$status" -eq 5 ]
  # Resolving a blocker by id.
  ordo_journal_append "$RUN" blocker.resolved '{"id":"ci-red"}' >/dev/null
  run ordo_journal_project "$RUN"
  [ "$(jq -r '.counters.blockers_open' <<<"$output")" = "3" ]
  [ "$(jq -r '.blockers[3].state' <<<"$output")" = "resolved" ]
  [ "$(jq -r '.blockers[3].resolved_run_seq' <<<"$output")" = "9" ]
}

@test "project is side-effect free: no state files written, no external commands, byte-identical on replay (#808)" {
  seed_run
  ordo_journal_append "$RUN" run.waiting '{"why":"ci"}' >/dev/null
  local tool
  for tool in gh tmux curl git ssh; do
    write_mock_bin "$tool" <<EOF
#!/usr/bin/env bash
echo "$tool \$*" >> "$BATS_TEST_TMPDIR/external-calls.log"
exit 99
EOF
  done
  local before after first second third
  before=$(find "$(state_dir)" -type f ! -name 'ordo-journal.sqlite*' | sort)
  first=$(ordo_journal_project "$RUN")
  second=$(ordo_journal_project "$RUN")
  after=$(find "$(state_dir)" -type f ! -name 'ordo-journal.sqlite*' | sort)
  [ "$before" = "$after" ]
  [ ! -e "$BATS_TEST_TMPDIR/external-calls.log" ]
  [ "$first" = "$second" ]
  # Drop the cached projection and rebuild everything: still identical.
  db_query "DELETE FROM projections" >/dev/null
  run ordo_journal_rebuild_all
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.rebuilt')" = "1" ]
  [ "$(printf '%s' "$output" | jq -r --arg r "$RUN" '.runs[$r]')" = "waiting" ]
  third=$(ordo_journal_project "$RUN")
  [ "$first" = "$third" ]
  # The stored projection row equals the printed snapshot.
  [ "$(db_query "SELECT snapshot_json FROM projections WHERE run_id='$RUN'" | jq -r '.[0]')" = "$first" ]
  [ "$(db_query "SELECT state, last_seq FROM projections WHERE run_id='$RUN'" | jq -c .)" = '["waiting",4]' ]
  # Byte-identical through a temp file as well (no trailing-whitespace drift).
  ordo_journal_project "$RUN" > "$BATS_TEST_TMPDIR/snap1.json"
  ordo_journal_project "$RUN" > "$BATS_TEST_TMPDIR/snap2.json"
  cmp "$BATS_TEST_TMPDIR/snap1.json" "$BATS_TEST_TMPDIR/snap2.json"
}

@test "rebuild_all rebuilds every run and drops projections without events (#808)" {
  seed_run
  local r2
  r2=$(ordo_contracts_new_id run)
  ordo_journal_append "$r2" run.cancelled '{}' >/dev/null
  db_query "INSERT INTO projections(run_id,state,updated_at,last_seq,snapshot_json) VALUES ('run_deadbeefdeadbeefdeadbeef','queued','x',0,'{}')" >/dev/null
  run ordo_journal_rebuild_all
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.rebuilt')" = "2" ]
  [ "$(printf '%s' "$output" | jq -r --arg r "$RUN" '.runs[$r]')" = "running" ]
  [ "$(printf '%s' "$output" | jq -r --arg r "$r2" '.runs[$r]')" = "cancelled" ]
  [ "$(db_query 'SELECT COUNT(*) FROM projections' | jq -c .)" = "[2]" ]
}

# --- crash safety -----------------------------------------------------------------

@test "a transaction that fails before COMMIT leaves no partial event and no run_seq gap (#808)" {
  seed_run
  ORDO_JOURNAL_FAULT=before_commit run --separate-stderr ordo_journal_append "$RUN" run.waiting '{}'
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  assert_error_line internal_error
  [ "$(printf '%s' "$stderr" | jq -r '.error.details.raw')" != "" ]
  [ "$(db_query 'SELECT COUNT(*) FROM events' | jq -c .)" = "[3]" ]
  [ "$(ordo_journal_state "$RUN")" = "running" ]
  run ordo_journal_append "$RUN" run.waiting '{}'
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.run_seq')" = "4" ]
  run ordo_journal_check
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.ok')" = "true" ]
  [ "$(printf '%s' "$output" | jq -c '.run_seq_gaps')" = "[]" ]
}

@test "a writer killed (SIGKILL) between INSERT and COMMIT leaves the journal consistent (#808)" {
  seed_run
  ORDO_JOURNAL_FAULT=kill_before_commit run --separate-stderr ordo_journal_append "$RUN" run.waiting '{}'
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  assert_error_line internal_error
  [ "$(printf '%s' "$stderr" | jq -r '.error.details.rc')" = "137" ]
  [ "$(db_query 'SELECT COUNT(*) FROM events' | jq -c .)" = "[3]" ]
  [ "$(db_query "SELECT last_seq FROM projections WHERE run_id='$RUN'" | jq -c .)" = "[3]" ]
  run ordo_journal_append "$RUN" run.waiting '{}'
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.run_seq')" = "4" ]
  [ "$(ordo_journal_state "$RUN")" = "waiting" ]
  run ordo_journal_check
  [ "$(printf '%s' "$output" | jq -r '.integrity')" = "ok" ]
  [ "$(printf '%s' "$output" | jq -c '.run_seq_gaps')" = "[]" ]
  # The same hook also protects lease and approval writes.
  ORDO_JOURNAL_FAULT=before_commit run ordo_journal_lease_acquire "$RUN" worker-1
  [ "$status" -eq 1 ]
  [ "$(db_query 'SELECT COUNT(*) FROM leases' | jq -c .)" = "[0]" ]
  ORDO_JOURNAL_FAULT=before_commit run ordo_journal_approval_create "$RUN" pr.merge operator --policy-version v1 --idempotency-key ap-1
  [ "$status" -eq 1 ]
  [ "$(db_query 'SELECT COUNT(*) FROM approvals' | jq -c .)" = "[0]" ]
  [ "$(db_query 'SELECT COUNT(*) FROM events' | jq -c .)" = "[4]" ]
}

# --- concurrency -----------------------------------------------------------------

@test "8 concurrent appenders on one run produce a gapless 1..8 run_seq and a consistent projection (#808)" {
  local n=8 i dir="$BATS_TEST_TMPDIR/conc"
  mkdir -p "$dir"
  local other
  other=$(ordo_contracts_new_id run)
  for i in $(seq 1 "$n"); do
    ( rc=0; ordo_journal_append "$RUN" "worker.$i" "{\"i\":$i}" >"$dir/out.$i" 2>"$dir/err.$i" || rc=$?; echo "$rc" >"$dir/rc.$i" ) &
    # Interleave a second run to prove sequences are independent per run.
    ( rc=0; ordo_journal_append "$other" "other.$i" '{}' >"$dir/o-out.$i" 2>"$dir/o-err.$i" || rc=$?; echo "$rc" >"$dir/o-rc.$i" ) &
  done
  wait
  for i in $(seq 1 "$n"); do
    [ "$(cat "$dir/rc.$i")" = "0" ] || { cat "$dir/err.$i"; return 1; }
    [ "$(cat "$dir/o-rc.$i")" = "0" ] || { cat "$dir/o-err.$i"; return 1; }
  done
  local seqs
  seqs=$(ordo_journal_events "$RUN" | jq -r '.run_seq' | tr '\n' ' ')
  [ "$seqs" = "1 2 3 4 5 6 7 8 " ]
  [ "$(cat "$dir"/out.* | jq -r '.run_seq' | sort -n | uniq | wc -l)" -eq "$n" ]
  [ "$(cat "$dir"/out.* | jq -r '.id' | sort -u | wc -l)" -eq "$n" ]
  [ "$(ordo_journal_events "$other" | jq -r '.run_seq' | tr '\n' ' ')" = "1 2 3 4 5 6 7 8 " ]
  [ "$(db_query "SELECT COUNT(*), MAX(run_seq) FROM events WHERE run_id='$RUN'" | jq -c .)" = "[8,8]" ]
  run ordo_journal_project "$RUN"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.event_count')" = "8" ]
  [ "$(printf '%s' "$output" | jq -r '.last_run_seq')" = "8" ]
  [ "$(printf '%s' "$output" | jq -r '.counters.events')" = "8" ]
  # The projection maintained incrementally by the appenders matches the rebuild.
  [ "$(db_query "SELECT last_seq FROM projections WHERE run_id='$RUN'" | jq -r '.[0]')" = "$(printf '%s' "$output" | jq -r '.last_seq')" ]
  run ordo_journal_check
  [ "$(printf '%s' "$output" | jq -r '.ok')" = "true" ]
}

@test "concurrent appends racing on one idempotency key: exactly one wins, the rest get the same event (#808)" {
  local n=8 i dir="$BATS_TEST_TMPDIR/race"
  mkdir -p "$dir"
  for i in $(seq 1 "$n"); do
    ( rc=0; ordo_journal_append "$RUN" pr.merge "{\"attempt\":$i}" --mutation --idempotency-key merge-once >"$dir/out.$i" 2>"$dir/err.$i" || rc=$?; echo "$rc" >"$dir/rc.$i" ) &
  done
  wait
  local zero=0 five=0
  for i in $(seq 1 "$n"); do
    case "$(cat "$dir/rc.$i")" in
      0) zero=$((zero + 1)) ;;
      5) five=$((five + 1)); [ "$(jq -r '.error.code' "$dir/err.$i")" = "duplicate_event" ] ;;
      *) cat "$dir/err.$i"; return 1 ;;
    esac
  done
  [ "$zero" -eq 1 ]
  [ "$five" -eq $((n - 1)) ]
  [ "$(cat "$dir"/out.* | sort -u | wc -l)" -eq 1 ]
  [ "$(db_query 'SELECT COUNT(*) FROM events' | jq -c .)" = "[1]" ]
  [ "$(ordo_journal_events "$RUN" | jq -r '.run_seq')" = "1" ]
}

# --- compat export -----------------------------------------------------------------

@test "compat_export reproduces the legacy assignments.json byte-for-byte and removes it when the run ends (#808)" {
  seed_run
  # Legacy writer: the exact row builder from scripts/dispatch_ticket.sh
  # (dispatch_assignment_payload) applied the way promote_dispatch_assignment
  # writes it. Extracted at test time so any drift in the script fails here.
  local legacy_dir="$BATS_TEST_TMPDIR/legacy"
  mkdir -p "$legacy_dir"
  (
    export ORCH_STATE_BASE="$legacy_dir"
    # shellcheck disable=SC1090
    source "$TK/lib/audit_log.sh"
    # shellcheck disable=SC1090
    source "$TK/lib/state_persist.sh"
    eval "$(sed -n '/^dispatch_assignment_payload() {/,/^}/p' "$TK/scripts/dispatch_ticket.sh")"
    declare -F dispatch_assignment_payload >/dev/null
    agent_repo_root() { printf '/work/fleet-001'; }
    AGENT=fleet-001 TICKET_NUM=42 BRANCH=feat/widget WORKDIR=/work/fleet-001 STAGED=/tmp/p.md
    DISPATCHED_AT=2026-09-11T05:00:00Z HEAD_AT_DISPATCH=abc123 DISPATCH_ROUTE="" PANE_CONTEXT_PROOF_ROUTE="" PANE_CONTEXT_PROOF_LIVE_PATH=""
    payload=$(dispatch_assignment_payload "" "" "")
    state_get assignments | jq --arg agent "$AGENT" --argjson record "$payload" '.[$agent] = $record' > "$(state_file assignments.json)"
  ) >/dev/null 2>&1
  [ -s "$legacy_dir/$PROJECT/assignments.json" ]

  run --separate-stderr ordo_journal_compat_export "$RUN"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.assignment.action')" = "upserted" ]
  [ "$(printf '%s' "$output" | jq -r '.assignment.agent')" = "fleet-001" ]
  [ "$(printf '%s' "$output" | jq -r '.state')" = "running" ]
  cmp "$legacy_dir/$PROJECT/assignments.json" "$(state_dir)/assignments.json"
  # What the pre-migration readers compute (orch_ctl status, orch_loop,
  # monitor_heartbeat, recover.sh, worktree_helpers) is unchanged.
  [ "$(jq 'to_entries | length' "$(state_dir)/assignments.json")" = "1" ]
  [ "$(state_get assignments | jq -r '.["fleet-001"].issue')" = "42" ]
  [ "$(state_get assignments | jq -r '.["fleet-001"].workdir')" = "/work/fleet-001" ]
  [ "$(state_get assignments | jq -r '.["fleet-001"].ticket')" = "42" ]
  [ "$(state_get ordo-journal-compat | jq -r '.agents["fleet-001"]')" = "$RUN" ]
  # The per-run snapshot file is the pretty, key-sorted projection.
  [ -f "$(state_dir)/ordo-runs/$RUN.json" ]
  diff <(ordo_journal_project "$RUN" | jq -S .) "$(state_dir)/ordo-runs/$RUN.json"
  # Export is idempotent.
  ordo_journal_compat_export "$RUN" >/dev/null
  cmp "$legacy_dir/$PROJECT/assignments.json" "$(state_dir)/assignments.json"
  # A foreign row survives; the run's own row is removed once terminal.
  state_update assignments '.["fleet-009"] = {"ticket":"9","issue":9}'
  ordo_journal_append "$RUN" run.succeeded '{}' >/dev/null
  run --separate-stderr ordo_journal_compat_export "$RUN"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.assignment.action')" = "deleted" ]
  [ "$(jq -c 'keys' "$(state_dir)/assignments.json")" = '["fleet-009"]' ]
  [ "$(state_get ordo-journal-compat | jq -c '.agents')" = "{}" ]
  # A second export of a terminal run whose row belongs to someone else is a no-op.
  state_update assignments '.["fleet-001"] = {"ticket":"7","issue":7}'
  run --separate-stderr ordo_journal_compat_export "$RUN"
  [ "$(printf '%s' "$output" | jq -r '.assignment.action')" = "none" ]
  [ "$(jq -r '.["fleet-001"].issue' "$(state_dir)/assignments.json")" = "7" ]
}

@test "compat_export without a dispatch record only writes the per-run snapshot (#808)" {
  ordo_journal_append "$RUN" run.created '{"title":"no agent"}' >/dev/null
  run --separate-stderr ordo_journal_compat_export "$RUN"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.assignment.action')" = "none" ]
  [ "$(printf '%s' "$output" | jq -c '.files | length')" = "1" ]
  [ -f "$(state_dir)/ordo-runs/$RUN.json" ]
  [ ! -e "$(state_dir)/assignments.json" ]
  run --separate-stderr ordo_journal_compat_export run_000000000000000000000000
  [ "$status" -eq 4 ]; assert_error_line not_found
}

# --- leases ---------------------------------------------------------------------

@test "lease acquire/renew/release: exclusive per run, contract-valid, events journaled (#808)" {
  seed_run
  export ORDO_JOURNAL_NOW=2026-09-11T10:00:00Z
  run ordo_journal_lease_acquire "$RUN" worker-a --ttl 60 --task-id task_000000000000000000000001
  [ "$status" -eq 0 ]
  local lease="$output" lease_id
  lease_id=$(jq -r '.id' <<<"$lease")
  ordo_contracts_validate lease "$lease"
  [ "$(jq -r '.state' <<<"$lease")" = "active" ]
  [ "$(jq -r '.owner' <<<"$lease")" = "worker-a" ]
  [ "$(jq -r '.expires_at' <<<"$lease")" = "2026-09-11T10:01:00Z" ]
  [ "$(jq -r '.generation' <<<"$lease")" = "0" ]
  [ "$(jq -r '.task_id' <<<"$lease")" = "task_000000000000000000000001" ]
  [ "$(ordo_journal_lease_get "$lease_id")" = "$lease" ]
  [ "$(ordo_journal_lease_list "$RUN" | wc -l)" -eq 1 ]
  # Exclusive: another owner is refused with a conflict naming the holder.
  run --separate-stderr ordo_journal_lease_acquire "$RUN" worker-b
  [ "$status" -eq 5 ]; assert_error_line conflict
  [ "$(printf '%s' "$stderr" | jq -r '.error.details.owner')" = "worker-a" ]
  # Renew extends expiry, bumps the generation and heartbeat.
  export ORDO_JOURNAL_NOW=2026-09-11T10:00:30Z
  run ordo_journal_lease_renew "$lease_id"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.state')" = "renewed" ]
  [ "$(printf '%s' "$output" | jq -r '.generation')" = "1" ]
  [ "$(printf '%s' "$output" | jq -r '.expires_at')" = "2026-09-11T10:01:30Z" ]
  [ "$(printf '%s' "$output" | jq -r '.heartbeat_at')" = "2026-09-11T10:00:30Z" ]
  run ordo_journal_lease_renew "$lease_id" --ttl 600
  [ "$(printf '%s' "$output" | jq -r '.generation')" = "2" ]
  [ "$(printf '%s' "$output" | jq -r '.expires_at')" = "2026-09-11T10:10:30Z" ]
  # Release, then the lease is terminal.
  run ordo_journal_lease_release "$lease_id"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.state')" = "released" ]
  run --separate-stderr ordo_journal_lease_release "$lease_id"
  [ "$status" -eq 5 ]; assert_error_line invalid_transition contracts
  run --separate-stderr ordo_journal_lease_renew "$lease_id"
  [ "$status" -eq 5 ]; assert_error_line invalid_transition contracts
  # Events were journaled on the run and the projection mirrors the lease.
  [ "$(ordo_journal_events "$RUN" --since 3 | jq -r '.type' | tr '\n' ' ')" = "lease.acquired lease.renewed lease.renewed lease.released " ]
  [ "$(ordo_journal_project "$RUN" | jq -c '.lease | [.id, .state, .generation]')" = "[\"$lease_id\",\"released\",2]" ]
  # The run can be leased again.
  run ordo_journal_lease_acquire "$RUN" worker-b
  [ "$status" -eq 0 ]
  # Errors: unknown lease (4), usage (2), bad ttl (2).
  run --separate-stderr ordo_journal_lease_get lease_000000000000000000000000
  [ "$status" -eq 4 ]; assert_error_line not_found
  run --separate-stderr ordo_journal_lease_renew lease_000000000000000000000000
  [ "$status" -eq 4 ]; assert_error_line not_found
  run --separate-stderr ordo_journal_lease_acquire "$RUN"
  [ "$status" -eq 2 ]; assert_error_line usage
  run --separate-stderr ordo_journal_lease_acquire "$RUN" w --ttl nope
  [ "$status" -eq 2 ]; assert_error_line bad_argument
}

@test "expire_stale moves leases past expires_at to expired and emits lease_expired; renew of a lost lease exits 8 (#808)" {
  seed_run
  local r2
  r2=$(ordo_contracts_new_id run)
  export ORDO_JOURNAL_NOW=2026-09-11T10:00:00Z
  local short long other
  short=$(ordo_journal_lease_acquire "$RUN" worker-a --ttl 30 | jq -r '.id')
  long=$(ordo_journal_lease_acquire "$r2" worker-b --ttl 3600 | jq -r '.id')
  # Nothing is stale yet.
  run ordo_journal_lease_expire_stale
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.count')" = "0" ]
  # Past the short TTL but not yet swept: renew/release report lease_stale (8).
  export ORDO_JOURNAL_NOW=2026-09-11T10:01:00Z
  run --separate-stderr ordo_journal_lease_renew "$short"
  [ "$status" -eq 8 ]; assert_error_line lease_stale
  run ordo_journal_lease_expire_stale --actor '{"type":"system","id":"sweeper"}'
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.count')" = "1" ]
  [ "$(printf '%s' "$output" | jq -r '.expired[0].id')" = "$short" ]
  [ "$(printf '%s' "$output" | jq -r '.expired[0].state')" = "expired" ]
  [ "$(ordo_journal_lease_get "$short" | jq -r '.state')" = "expired" ]
  [ "$(ordo_journal_lease_get "$long" | jq -r '.state')" = "active" ]
  # A lease.expired event landed on the run, attributed to the sweeper.
  run ordo_journal_events "$RUN" --since 4
  [ "$(printf '%s' "$output" | jq -r '.type')" = "lease.expired" ]
  [ "$(printf '%s' "$output" | jq -r '.actor.id')" = "sweeper" ]
  [ "$(printf '%s' "$output" | jq -r '.payload.lease_id')" = "$short" ]
  [ "$(ordo_journal_project "$RUN" | jq -r '.lease.state')" = "expired" ]
  # Lost lease: renew / release exit 8 lease_lost; the run is free again.
  run --separate-stderr ordo_journal_lease_renew "$short"
  [ "$status" -eq 8 ]; assert_error_line lease_lost
  run --separate-stderr ordo_journal_lease_release "$short"
  [ "$status" -eq 8 ]; assert_error_line lease_lost
  other=$(ordo_journal_lease_acquire "$RUN" worker-c | jq -r '.id')
  [ "$other" != "$short" ]
  # Sweeping again is a no-op.
  run ordo_journal_lease_expire_stale
  [ "$(printf '%s' "$output" | jq -r '.count')" = "0" ]
  [ "$(db_query "SELECT state FROM leases ORDER BY rowid" | jq -r '.[0]' | tr '\n' ' ')" = "expired active active " ]
}

# --- approvals --------------------------------------------------------------------

@test "approval create/get/set_state follow the approval table and journal their events (#808)" {
  seed_run
  export ORDO_JOURNAL_NOW=2026-09-11T10:00:00Z
  run ordo_journal_approval_create "$RUN" pr.merge operator@example --policy-version policy-v3 --idempotency-key approve-merge-42 --ttl 3600
  [ "$status" -eq 0 ]
  local approval="$output" approval_id
  approval_id=$(jq -r '.id' <<<"$approval")
  ordo_contracts_validate approval "$approval"
  [ "$(jq -r '.state' <<<"$approval")" = "pending" ]
  [ "$(jq -r '.action' <<<"$approval")" = "pr.merge" ]
  [ "$(jq -r '.principal' <<<"$approval")" = "operator@example" ]
  [ "$(jq -r '.policy_version' <<<"$approval")" = "policy-v3" ]
  [ "$(jq -r '.expires_at' <<<"$approval")" = "2026-09-11T11:00:00Z" ]
  [ "$(ordo_journal_approval_get "$approval_id")" = "$approval" ]
  [ "$(ordo_journal_approval_list "$RUN" --state pending | jq -r '.id')" = "$approval_id" ]
  # Duplicate idempotency key: exit 5 conflict, existing approval printed.
  run --separate-stderr ordo_journal_approval_create "$RUN" pr.merge operator@example --policy-version policy-v3 --idempotency-key approve-merge-42
  [ "$status" -eq 5 ]
  [ "$output" = "$approval" ]
  assert_error_line conflict
  [ "$(printf '%s' "$stderr" | jq -r '.error.details.reason')" = "duplicate_idempotency_key" ]
  [ "$(db_query 'SELECT COUNT(*) FROM approvals' | jq -c .)" = "[1]" ]
  # pending -> granted -> consumed; consumed is terminal.
  export ORDO_JOURNAL_NOW=2026-09-11T10:05:00Z
  run ordo_journal_approval_set_state "$approval_id" granted --reason "reviewed" --decided-by '{"type":"operator","id":"eric"}' --result '{"pr":42}'
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.state')" = "granted" ]
  [ "$(printf '%s' "$output" | jq -r '.decided_at')" = "2026-09-11T10:05:00Z" ]
  [ "$(printf '%s' "$output" | jq -r '.decided_by.id')" = "eric" ]
  [ "$(printf '%s' "$output" | jq -r '.reason')" = "reviewed" ]
  [ "$(printf '%s' "$output" | jq -c '.result')" = '{"pr":42}' ]
  ordo_contracts_validate approval "$output"
  [ "$(db_query "SELECT state, result_json FROM approvals" | jq -c .)" = '["granted","{\"pr\":42}"]' ]
  run --separate-stderr ordo_journal_approval_set_state "$approval_id" pending
  [ "$status" -eq 5 ]; assert_error_line invalid_transition contracts
  run ordo_journal_approval_set_state "$approval_id" consumed
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.state')" = "consumed" ]
  run --separate-stderr ordo_journal_approval_set_state "$approval_id" denied
  [ "$status" -eq 5 ]; assert_error_line invalid_transition contracts
  [ "$(ordo_journal_approval_list "$RUN" | jq -r '.state')" = "consumed" ]
  [ "$(ordo_journal_events "$RUN" --since 3 | jq -r '.type' | tr '\n' ' ')" = "approval.requested approval.granted approval.consumed " ]
  [ "$(ordo_journal_project "$RUN" | jq -c '.approval')" = "{\"action\":\"pr.merge\",\"id\":\"$approval_id\",\"state\":\"consumed\"}" ]
  # pending -> denied and pending -> expired are also reachable.
  local second
  second=$(ordo_journal_approval_create "$RUN" pr.merge operator --policy-version v1 --idempotency-key approve-2 | jq -r '.id')
  [ "$(ordo_journal_approval_set_state "$second" denied --reason no | jq -r '.state')" = "denied" ]
  # Errors: unknown approval (4), usage (2).
  run --separate-stderr ordo_journal_approval_get approval_000000000000000000000000
  [ "$status" -eq 4 ]; assert_error_line not_found
  run --separate-stderr ordo_journal_approval_set_state approval_000000000000000000000000 granted
  [ "$status" -eq 4 ]; assert_error_line not_found
  run --separate-stderr ordo_journal_approval_create "$RUN" pr.merge operator
  [ "$status" -eq 2 ]; assert_error_line usage
  run --separate-stderr ordo_journal_approval_create "$RUN" pr.merge operator --policy-version v1
  [ "$status" -eq 2 ]; assert_error_line usage
}

# --- dependencies -------------------------------------------------------------------

@test "missing python3 on PATH exits 6 missing_dependency with an error object (#808)" {
  local nopy="$BATS_TEST_TMPDIR/nopy" tool
  mkdir -p "$nopy"
  for tool in bash jq date od tr mktemp rm cat mkdir dirname tail cut wc tee flock grep sed sort find; do
    ln -s "$(command -v "$tool")" "$nopy/$tool"
  done
  PATH="$nopy" run --separate-stderr ordo_journal_append "$RUN" a.b '{}'
  [ "$status" -eq 6 ]
  [ -z "$output" ]
  assert_error_line missing_dependency
  [ "$(printf '%s' "$stderr" | jq -r '.error.details.dependency')" = "python3" ]
  PATH="$nopy" run --separate-stderr ordo_journal_init
  [ "$status" -eq 6 ]; assert_error_line missing_dependency
  PATH="$nopy" run --separate-stderr ordo_journal_state "$RUN"
  [ "$status" -eq 6 ]; assert_error_line missing_dependency
  # ORDO_JOURNAL_PYTHON_BIN pointing nowhere behaves the same.
  ORDO_JOURNAL_PYTHON_BIN=/nonexistent/python3 run --separate-stderr ordo_journal_init
  [ "$status" -eq 6 ]; assert_error_line missing_dependency
}

@test "ordo_journal_check reports integrity, counts and run_seq gaps (#808)" {
  seed_run
  run ordo_journal_check
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.integrity')" = "ok" ]
  [ "$(printf '%s' "$output" | jq -r '.counts.events')" = "3" ]
  [ "$(printf '%s' "$output" | jq -r '.counts.projections')" = "1" ]
  [ "$(printf '%s' "$output" | jq -r '.ok')" = "true" ]
  # A gap forged behind the library's back is detected.
  db_query "DELETE FROM events WHERE run_seq = 2" >/dev/null
  run ordo_journal_check
  [ "$(printf '%s' "$output" | jq -r '.ok')" = "false" ]
  [ "$(printf '%s' "$output" | jq -r '.run_seq_gaps[0].run_id')" = "$RUN" ]
}

# --- batched commands (#817) -----------------------------------------------------

@test "tick_view returns stale leases, the runs of the requested states, slot usage and counts in one document (#817)" {
  seed_run
  local r2 r3
  r2=$(ordo_contracts_new_id run); r3=$(ordo_contracts_new_id run)
  ordo_journal_append "$r2" run.created '{"title":"queued one"}' >/dev/null
  ordo_journal_append "$r3" run.created '{"title":"done"}' >/dev/null
  ordo_journal_append "$r3" run.cancelled '{}' >/dev/null
  export ORDO_JOURNAL_NOW=2026-09-11T10:00:00Z
  local short
  short=$(ordo_journal_lease_acquire "$RUN" worker-a --ttl 30 | jq -r '.id')
  run ordo_journal_tick_view --state running,queued
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | wc -l)" -eq 1 ]
  [ "$(jq -r '.now' <<<"$output")" = "2026-09-11T10:00:00Z" ]
  [ "$(jq -c '.stale_leases' <<<"$output")" = "[]" ]
  [ "$(jq -r '.runs | map(.run_id) | join(",")' <<<"$output")" = "$RUN,$r2" ]
  [ "$(jq -r '.slots_used' <<<"$output")" = "1" ]
  [ "$(jq -c '.counts' <<<"$output")" = '{"cancelled":1,"queued":1,"running":1}' ]
  [ "$(jq -r --arg r "$r3" '.states[$r]' <<<"$output")" = "cancelled" ]
  # The runs are the stored projections, byte for byte.
  [ "$(jq -c '.runs[0]' <<<"$output")" = "$(ordo_journal_project "$RUN")" ]
  # Past the TTL the lease is listed as stale (as lease_expire_stale would sweep it); --now pins the clock.
  run ordo_journal_tick_view --now 2026-09-11T10:01:00Z
  [ "$status" -eq 0 ]
  [ "$(jq -r '.stale_leases[0].lease_id' <<<"$output")" = "$short" ]
  [ "$(jq -r '.stale_leases[0].run_id' <<<"$output")" = "$RUN" ]
  [ "$(jq -r '.runs | length' <<<"$output")" = "3" ]
  # Reading changes nothing.
  [ "$(ordo_journal_events "$RUN" | wc -l)" -eq 4 ]
  run --separate-stderr ordo_journal_tick_view --bogus
  [ "$status" -eq 2 ]; assert_error_line usage
}

@test "append_batch appends several events for several runs in ONE transaction; a duplicate key rejects the whole batch (#817)" {
  seed_run
  local r2
  r2=$(ordo_contracts_new_id run)
  ordo_journal_append "$r2" run.created '{"title":"two"}' >/dev/null
  local events
  events=$(jq -cn --arg a "$RUN" --arg b "$r2" '[
    {"run_id": $a, "type": "run.budget", "payload": {"usage": {"tokens": 5}}},
    {"run_id": $b, "type": "run.leased", "payload": {"lease_id": "lease_000000000000000000000002"}, "actor": {"type": "agent", "id": "fleet-001"}},
    {"run_id": $a, "type": "provider.mutation", "payload": {"op": "pr_merge"}, "mutation": true, "idempotency_key": "batch-key-1", "metadata": {"k": "v"}}]')
  run ordo_journal_append_batch "$events"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | wc -l)" -eq 3 ]
  # Each line is a stored event with its run_seq, exactly what ordo_journal_events replays.
  [ "$(printf '%s\n' "$output" | jq -r '.run_seq' | paste -sd, -)" = "4,2,5" ]
  [ "$(printf '%s\n' "$output" | jq -r '.type' | paste -sd, -)" = "run.budget,run.leased,provider.mutation" ]
  [ "$(printf '%s\n' "$output" | sed -n 2p | jq -r '.actor.id')" = "fleet-001" ]
  [ "$(printf '%s\n' "$output" | sed -n 3p | jq -r '.idempotency_key, .mutation, .metadata.k' | paste -sd, -)" = "batch-key-1,true,v" ]
  [ "$(printf '%s\n' "$output" | sed -n 1p)" = "$(ordo_journal_events "$RUN" --since 3 | sed -n 1p)" ]
  while IFS= read -r line; do ordo_contracts_validate event "$line"; done <<<"$output"
  [ "$(ordo_journal_project "$RUN" | jq -r '.budgets.tokens_used, .counters.mutations' | paste -sd, -)" = "5,1" ]
  [ "$(ordo_journal_state "$r2")" = "leased" ]
  # Payload from stdin, default actor.
  run ordo_journal_append_batch - <<<"$(jq -cn --arg a "$RUN" '[{"run_id": $a, "type": "run.updated", "payload": {"title": "T"}}]')"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.actor.id' <<<"$output")" = "ordo_journal" ]
  # A duplicate idempotency key anywhere in the batch: exit 5 duplicate_event, the existing event on stdout, NOTHING written.
  local before
  before=$(ordo_journal_events "$RUN" | wc -l)
  run --separate-stderr ordo_journal_append_batch "$(jq -cn --arg a "$RUN" --arg b "$r2" '[
    {"run_id": $b, "type": "run.started", "payload": {}},
    {"run_id": $a, "type": "provider.mutation", "payload": {"op": "again"}, "mutation": true, "idempotency_key": "batch-key-1"}]')"
  [ "$status" -eq 5 ]; assert_error_line duplicate_event
  [ "$(printf '%s' "$stderr" | jq -r '.error.details.batch_index')" = "1" ]
  [ "$(printf '%s' "$output" | jq -r '.idempotency_key')" = "batch-key-1" ]
  [ "$(ordo_journal_events "$RUN" | wc -l)" -eq "$before" ]
  [ "$(ordo_journal_state "$r2")" = "leased" ]
  [ "$(db_query "SELECT COUNT(*) FROM events WHERE type = 'run.started' AND run_id = '$r2'" | jq -c .)" = "[0]" ]
  # Invalid contract (5) and bad run id (2) also write nothing.
  run --separate-stderr ordo_journal_append_batch "$(jq -cn --arg a "$RUN" '[{"run_id": $a, "type": "ok.type", "payload": {}}, {"run_id": $a, "type": "BAD TYPE", "payload": {}}]')"
  [ "$status" -eq 5 ]; assert_error_line invalid_contract
  [ "$(printf '%s' "$stderr" | jq -r '.error.details.batch_index')" = "1" ]
  run --separate-stderr ordo_journal_append_batch '[{"run_id": "nope", "type": "a.b", "payload": {}}]'
  [ "$status" -eq 2 ]; assert_error_line bad_argument
  run --separate-stderr ordo_journal_append_batch '{"not": "an array"}'
  [ "$status" -eq 2 ]; assert_error_line bad_argument
  [ "$(ordo_journal_events "$RUN" | wc -l)" -eq "$before" ]
  ordo_journal_check | jq -e '.ok' >/dev/null
}

@test "batch runs lease ops and events in one transaction with the single-command guards; lenient lease ops skip instead of failing (#817)" {
  seed_run
  export ORDO_JOURNAL_NOW=2026-09-11T10:00:00Z
  local lease_id=lease_0123456789abcdef01234567
  run ordo_journal_batch "$(jq -cn --arg r "$RUN" --arg l "$lease_id" '[
    {"op": "lease_acquire", "run_id": $r, "owner": "w1", "id": $l, "ttl": 60},
    {"op": "append", "run_id": $r, "type": "run.waiting", "payload": {"lease_id": $l, "metadata": {"lease_id": $l}}}]')" --actor '{"type":"system","id":"sched"}'
  [ "$status" -eq 0 ]
  [ "$(jq -r '.results[0].id, .results[0].state, .results[0].expires_at' <<<"$output" | paste -sd, -)" = "$lease_id,active,2026-09-11T10:01:00Z" ]
  [ "$(jq -r '.results[1].type, .results[1].run_seq' <<<"$output" | paste -sd, -)" = "run.waiting,5" ]
  [ "$(jq -c '.touched' <<<"$output")" = "[\"$RUN\"]" ]
  [ "$(ordo_journal_events "$RUN" --since 3 | jq -r '.type + ":" + .actor.id' | paste -sd, -)" = "lease.acquired:sched,run.waiting:sched" ]
  [ "$(ordo_journal_project "$RUN" | jq -r '.state, .lease.id, .metadata.lease_id' | paste -sd, -)" = "waiting,$lease_id,$lease_id" ]
  # A second acquire on a leased run is the same conflict as ordo_journal_lease_acquire, and rolls the batch back.
  run --separate-stderr ordo_journal_batch "$(jq -cn --arg r "$RUN" '[{"op": "append", "run_id": $r, "type": "run.running", "payload": {}}, {"op": "lease_acquire", "run_id": $r, "owner": "w2"}]')"
  [ "$status" -eq 5 ]; assert_error_line conflict
  [ "$(printf '%s' "$stderr" | jq -r '.error.details.owner, .error.details.batch_index' | paste -sd, -)" = "w1,1" ]
  [ "$(ordo_journal_state "$RUN")" = "waiting" ]
  # renew (with the run bound), then a lenient release of a lease that is no longer live is skipped, a strict one exits 5.
  export ORDO_JOURNAL_NOW=2026-09-11T10:00:30Z
  run ordo_journal_batch "$(jq -cn --arg r "$RUN" --arg l "$lease_id" '[{"op": "lease_renew", "lease_id": $l, "run_id": $r, "ttl": 600}, {"op": "lease_release", "lease_id": $l}]')"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.results[0].generation, .results[0].expires_at, .results[1].state' <<<"$output" | paste -sd, -)" = "1,2026-09-11T10:10:30Z,released" ]
  run ordo_journal_batch "$(jq -cn --arg r "$RUN" --arg l "$lease_id" '[{"op": "lease_release", "lease_id": $l, "lenient": true}, {"op": "append", "run_id": $r, "type": "run.running", "payload": {}}]')"
  [ "$status" -eq 0 ]
  [ "$(jq -c '.results[0]' <<<"$output")" = "{\"lease_id\":\"$lease_id\",\"skipped\":\"invalid_transition\"}" ]
  [ "$(ordo_journal_state "$RUN")" = "running" ]
  run --separate-stderr ordo_journal_batch "$(jq -cn --arg l "$lease_id" '[{"op": "lease_release", "lease_id": $l}]')"
  [ "$status" -eq 5 ]; assert_error_line invalid_transition
  run --separate-stderr ordo_journal_batch '[{"op": "lease_renew", "lease_id": "lease_000000000000000000000009"}]'
  [ "$status" -eq 4 ]; assert_error_line not_found
  # A lease bound to another run is a conflict; a stale live lease exits 8 (lease_stale), lenient expires it instead.
  local other stale
  other=$(ordo_contracts_new_id run)
  ordo_journal_append "$other" run.created '{}' >/dev/null
  stale=$(ordo_journal_lease_acquire "$other" w3 --ttl 10 | jq -r '.id')
  run --separate-stderr ordo_journal_batch "$(jq -cn --arg r "$RUN" --arg l "$stale" '[{"op": "lease_renew", "lease_id": $l, "run_id": $r}]')"
  [ "$status" -eq 5 ]; assert_error_line conflict
  export ORDO_JOURNAL_NOW=2026-09-11T10:05:00Z
  run --separate-stderr ordo_journal_batch "$(jq -cn --arg l "$stale" '[{"op": "lease_release", "lease_id": $l}]')"
  [ "$status" -eq 8 ]; assert_error_line lease_stale
  run ordo_journal_batch "$(jq -cn --arg l "$stale" '[{"op": "lease_release", "lease_id": $l, "lenient": true}]')"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.results[0].skipped, .results[0].expired.state' <<<"$output" | paste -sd, -)" = "lease_stale,expired" ]
  [ "$(ordo_journal_events "$other" | jq -r '.type' | tail -n 1)" = "lease.expired" ]
  # Unknown ops and malformed input are usage errors; nothing is written.
  run --separate-stderr ordo_journal_batch '[{"op": "frobnicate"}]'
  [ "$status" -eq 2 ]; assert_error_line bad_argument
  run --separate-stderr ordo_journal_batch '[{"op": "lease_renew"}]'
  [ "$status" -eq 2 ]; assert_error_line bad_argument
  run --separate-stderr ordo_journal_batch '[]'
  [ "$status" -eq 2 ]; assert_error_line bad_argument
  ordo_journal_check | jq -e '.ok' >/dev/null
}

@test "approval_view returns the approval, its run state and the events naming it in one read (#817)" {
  seed_run
  local id
  id=$(ordo_journal_approval_create "$RUN" pr.merge operator --policy-version v1 --idempotency-key view-1 | jq -r '.id')
  ordo_journal_append "$RUN" approval_bridge.requested "$(jq -cn --arg id "$id" '{"approval_id": $id, "payload": {"args": ["42"]}}')" >/dev/null
  ordo_journal_append "$RUN" run.budget '{"usage":{"tokens":1}}' >/dev/null
  run ordo_journal_approval_view "$id"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | wc -l)" -eq 1 ]
  [ "$(jq -c '.approval' <<<"$output")" = "$(ordo_journal_approval_get "$id")" ]
  [ "$(jq -r '.run_id, .run_state' <<<"$output" | paste -sd, -)" = "$RUN,running" ]
  [ "$(jq -r '.events | map(.type) | join(",")' <<<"$output")" = "approval.requested,approval_bridge.requested" ]
  [ "$(jq -c '.events[1].payload.payload' <<<"$output")" = '{"args":["42"]}' ]
  run --separate-stderr ordo_journal_approval_view approval_000000000000000000000000
  [ "$status" -eq 4 ]; assert_error_line not_found
  run --separate-stderr ordo_journal_approval_view
  [ "$status" -eq 2 ]; assert_error_line usage
}

@test "the bytecode cache of the embedded program is transparent: same results with and without it (#817)" {
  seed_run
  local cache="$BATS_TEST_TMPDIR/pyc-cache"
  ORDO_JOURNAL_PYC_DIR="$cache" run ordo_journal_state "$RUN"
  [ "$status" -eq 0 ]; [ "$output" = "running" ]
  [ "$(find "$cache" -name 'ordo_journal_*.pyc' | wc -l)" -eq 1 ]
  [ "$(ORDO_JOURNAL_PYC_DIR="$cache" ordo_journal_project "$RUN")" = "$(ORDO_JOURNAL_PYC_CACHE=0 ordo_journal_project "$RUN")" ]
  # A cache directory that cannot be used just means running from source.
  ORDO_JOURNAL_PYC_DIR="$BATS_TEST_TMPDIR/not-a-dir/x" run ordo_journal_state "$RUN"
  [ "$status" -eq 0 ]; [ "$output" = "running" ]
  # Stale bytecode (wrong interpreter magic) is discarded and the call still succeeds.
  printf 'garbage' > "$cache"/ordo_journal_*.pyc
  ORDO_JOURNAL_PYC_DIR="$cache" run --separate-stderr ordo_journal_state "$RUN"
  [ "$status" -eq 0 ]; [ "$output" = "running" ]; [ -z "$stderr" ]
}
