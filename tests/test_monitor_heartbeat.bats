#!/usr/bin/env bats

# POC fixtures and unit tests for the orchestrator monitor-loop heartbeat
# (#339, finding ORCH_MONITOR_PROMPT_STALE_AFTER_GREEN_WAVE).
#
# The acceptance from the issue body:
#
#   Fixture or integration smoke: simulate all in-flight PRs becoming
#   CLEAN while queued work exists, then assert the orchestrator records
#   refreshed state and advances/flags the queue without relying on
#   external manual input.
#
# The POC ("acceptance fixture") cases below replay that exact sequence
# end-to-end: a `wave_green` transition writes a fresh snapshot AND emits
# `decision=advance_queue`; a follow-up cycle on the same snapshot then
# emits `decision=block_stale_at_prompt` so the operator and the audit
# trail both see the stall. The unit cases pin every classification path.

load './helpers.bash'

setup() {
  setup_orch_test
  toolkit_file lib/log_bounds.sh >/dev/null
  toolkit_file lib/config_check.sh >/dev/null
  AUDIT_LOG_LIB=$(toolkit_file lib/audit_log.sh)
  HEARTBEAT_LIB=$(toolkit_file lib/monitor_heartbeat.sh)
  HEARTBEAT_FILE="$BATS_TEST_TMPDIR/orch.monitor_heartbeat.json"
}

# Run the heartbeat library in a sub-shell with a fresh
# ORCH_MONITOR_HEARTBEAT_FILE, the audit/log fixtures already exported by
# setup_orch_test, and an explicit script body. Returns whatever the body
# echoes on stdout; status is the body's exit code.
heartbeat_eval() {
  local body=${1:?usage: heartbeat_eval <bash-body>}
  bash -lc "$(orch_env_exports)
    export ORCH_MONITOR_HEARTBEAT_FILE='$HEARTBEAT_FILE'
    source '$AUDIT_LOG_LIB'
    source '$HEARTBEAT_LIB'
    $body
  "
}

# --- Compose / record / load primitives -----------------------------------

@test "compose validates numeric fields and rejects garbage" {
  run heartbeat_eval 'monitor_heartbeat_compose 5 5 0 2 "ts"'
  [ "$status" -eq 0 ]
  [[ "$output" == *'"in_flight":5'* ]]
  [[ "$output" == *'"in_flight_clean":5'* ]]
  [[ "$output" == *'"queued":2'* ]]
  [[ "$output" == *'"schema_version":1'* ]]

  run heartbeat_eval 'monitor_heartbeat_compose 5 5 0 abc "ts"'
  [ "$status" -eq 2 ]
}

@test "record persists the snapshot atomically and load returns it" {
  run heartbeat_eval '
    snap=$(monitor_heartbeat_compose 3 1 2 4 "2026-05-08T10:00:00Z")
    monitor_heartbeat_record "$snap"
    monitor_heartbeat_load_prev
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *'"in_flight":3'* ]]
  [[ "$output" == *'"queued":4'* ]]
  [ -s "$HEARTBEAT_FILE" ]
}

@test "load_prev returns empty when no prior snapshot exists" {
  run heartbeat_eval 'monitor_heartbeat_load_prev'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- Classification matrix ------------------------------------------------

@test "classify wave_green: every in-flight PR went clean since prev" {
  run heartbeat_eval '
    prev=$(monitor_heartbeat_compose 5 0 5 2 "t1")
    cur=$(monitor_heartbeat_compose 5 5 0 2 "t2")
    monitor_heartbeat_classify "$prev" "$cur"
  '
  [ "$status" -eq 0 ]
  [ "$output" = "wave_green" ]
}

@test "classify stale_at_prompt: identical snapshot, all clean, queue waiting" {
  run heartbeat_eval '
    prev=$(monitor_heartbeat_compose 5 5 0 2 "t1")
    cur=$(monitor_heartbeat_compose 5 5 0 2 "t2")
    monitor_heartbeat_classify "$prev" "$cur"
  '
  [ "$status" -eq 0 ]
  [ "$output" = "stale_at_prompt" ]
}

@test "classify unchanged: identical snapshot, all clean, empty queue" {
  run heartbeat_eval '
    prev=$(monitor_heartbeat_compose 5 5 0 0 "t1")
    cur=$(monitor_heartbeat_compose 5 5 0 0 "t2")
    monitor_heartbeat_classify "$prev" "$cur"
  '
  [ "$status" -eq 0 ]
  [ "$output" = "unchanged" ]
}

@test "classify progressing: clean count grew but not all clean yet" {
  run heartbeat_eval '
    prev=$(monitor_heartbeat_compose 5 1 4 2 "t1")
    cur=$(monitor_heartbeat_compose 5 3 2 2 "t2")
    monitor_heartbeat_classify "$prev" "$cur"
  '
  [ "$status" -eq 0 ]
  [ "$output" = "progressing" ]
}

@test "classify idle: nothing in flight, nothing queued" {
  run heartbeat_eval '
    prev=$(monitor_heartbeat_compose 0 0 0 0 "t1")
    cur=$(monitor_heartbeat_compose 0 0 0 0 "t2")
    monitor_heartbeat_classify "$prev" "$cur"
  '
  [ "$status" -eq 0 ]
  [ "$output" = "idle" ]
}

@test "classify queue_pressure: nothing in flight, queue waiting" {
  run heartbeat_eval '
    prev=$(monitor_heartbeat_compose 0 0 0 1 "t1")
    cur=$(monitor_heartbeat_compose 0 0 0 1 "t2")
    monitor_heartbeat_classify "$prev" "$cur"
  '
  [ "$status" -eq 0 ]
  [ "$output" = "queue_pressure" ]
}

# --- Decision matrix ------------------------------------------------------

@test "decide wave_green + queued>0 → advance_queue" {
  run heartbeat_eval 'monitor_heartbeat_decide wave_green 2'
  [ "$output" = "advance_queue" ]
}

@test "decide wave_green + queued=0 → noop" {
  run heartbeat_eval 'monitor_heartbeat_decide wave_green 0'
  [ "$output" = "noop" ]
}

@test "decide queue_pressure + queued>0 → advance_queue" {
  run heartbeat_eval 'monitor_heartbeat_decide queue_pressure 3'
  [ "$output" = "advance_queue" ]
}

@test "decide stale_at_prompt → block_stale_at_prompt" {
  run heartbeat_eval 'monitor_heartbeat_decide stale_at_prompt 2'
  [ "$output" = "block_stale_at_prompt" ]
}

@test "decide progressing/idle/unchanged → noop" {
  run heartbeat_eval 'monitor_heartbeat_decide progressing 5'
  [ "$output" = "noop" ]
  run heartbeat_eval 'monitor_heartbeat_decide idle 0'
  [ "$output" = "noop" ]
  run heartbeat_eval 'monitor_heartbeat_decide unchanged 1'
  [ "$output" = "noop" ]
}

# --- Audit emission -------------------------------------------------------

@test "emit writes a structured audit line via audit_action" {
  run heartbeat_eval '
    cur=$(monitor_heartbeat_compose 5 5 0 2 "ts")
    prev=$(monitor_heartbeat_compose 5 0 5 2 "tp")
    monitor_heartbeat_emit wave_green advance_queue "$cur" "$prev"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"ORCH_MONITOR_HEARTBEAT classification=wave_green decision=advance_queue"* ]]
  [[ "$output" == *"in_flight=5"* ]]
  [[ "$output" == *"in_flight_clean=5"* ]]
  [[ "$output" == *"prev_in_flight_clean=0"* ]]
  [[ "$output" == *"queued=2"* ]]
  grep -q 'ORCH_MONITOR_HEARTBEAT classification=wave_green decision=advance_queue' \
    "$ORCH_LOG_DIR/$PROJECT.log"
}

# --- POC acceptance scenario (issue body POC plan) ------------------------
#
# Simulate: 5 in-flight PRs are all stale (CI running). Then they all go
# CLEAN while 2 queued issues remain. Assert refreshed state is recorded
# and the next decision advances the queue. Then simulate a second cycle
# with no further state change and assert the heartbeat now flags
# stale_at_prompt — the orchestrator does not silently park.

@test "POC: wave goes green with queued work → advance_queue, snapshot refreshed" {
  # Prime the previous snapshot: 5 in-flight stale, 2 queued.
  run heartbeat_eval '
    snap=$(monitor_heartbeat_compose 5 0 5 2 "before-wave")
    monitor_heartbeat_record "$snap"
    cur=$(monitor_heartbeat_compose 5 5 0 2 "after-wave")
    monitor_heartbeat_step "$cur"
  '
  [ "$status" -eq 0 ]
  # Last line of stdout is the decision keyword.
  [ "${lines[-1]}" = "advance_queue" ]
  # Audit line records the wave-green transition.
  grep -q 'classification=wave_green' "$ORCH_LOG_DIR/$PROJECT.log"
  grep -q 'decision=advance_queue'    "$ORCH_LOG_DIR/$PROJECT.log"
  # Snapshot file refreshed to the current state.
  [ -s "$HEARTBEAT_FILE" ]
  grep -q '"in_flight_clean":5'        "$HEARTBEAT_FILE"
  grep -q '"queued":2'                 "$HEARTBEAT_FILE"
}

@test "POC: second cycle with no progress flags stale_at_prompt" {
  # Cycle A: same as the previous test ends.
  run heartbeat_eval '
    snap=$(monitor_heartbeat_compose 5 0 5 2 "before-wave")
    monitor_heartbeat_record "$snap"
    cur=$(monitor_heartbeat_compose 5 5 0 2 "after-wave")
    monitor_heartbeat_step "$cur"
  '
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "advance_queue" ]

  # Cycle B: no change — the supervisor returned to the prompt, queued
  # work is still waiting, in-flight is still all clean. Heartbeat must
  # now blow the whistle.
  run heartbeat_eval '
    cur=$(monitor_heartbeat_compose 5 5 0 2 "still-stuck")
    monitor_heartbeat_step "$cur"
  '
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "block_stale_at_prompt" ]
  grep -q 'classification=stale_at_prompt'   "$ORCH_LOG_DIR/$PROJECT.log"
  grep -q 'decision=block_stale_at_prompt'   "$ORCH_LOG_DIR/$PROJECT.log"
}

@test "POC: empty queue after wave-green → decision noop, snapshot still refreshed" {
  # Operator drained the queue while the wave was running — once it goes
  # green there is nothing to advance. The heartbeat should still record
  # the refresh so a subsequent dispatch starts from accurate state.
  run heartbeat_eval '
    snap=$(monitor_heartbeat_compose 5 0 5 0 "before-wave")
    monitor_heartbeat_record "$snap"
    cur=$(monitor_heartbeat_compose 5 5 0 0 "after-wave")
    monitor_heartbeat_step "$cur"
  '
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "noop" ]
  grep -q 'classification=wave_green' "$ORCH_LOG_DIR/$PROJECT.log"
  grep -q 'decision=noop'             "$ORCH_LOG_DIR/$PROJECT.log"
  grep -q '"in_flight_clean":5'       "$HEARTBEAT_FILE"
}
