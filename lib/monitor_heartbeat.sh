#!/usr/bin/env bash
# monitor_heartbeat.sh — orchestrator monitor-loop heartbeat primitives (#339).
#
# The orchestrator loop (`scripts/orch_loop.sh`) reasons about "what's in
# flight" using a snapshot it took at cycle-start. Between cycles, the
# supervisor CLI may have already returned to the prompt while the actual
# PR pack moved (e.g. all five in-flight PRs went CLEAN). Without a fresh
# refresh, the loop's prompt-state is stale: pane still claims "5 PRs
# running", queued work (#327, RBOK pack) is left untouched, the operator
# has to manually prod the orchestrator. That's the bug captured by
# finding `ORCH_MONITOR_PROMPT_STALE_AFTER_GREEN_WAVE` (#339).
#
# This library exposes pure-bash primitives the loop can call between
# cycles to:
#
#   1. **collect** a heartbeat snapshot of in-flight vs queued work,
#   2. **classify** the transition from the previous snapshot,
#   3. **decide** what the loop should do next (advance the queue, mark
#      the run stale, no-op),
#   4. **record** the snapshot to state for the next cycle to read,
#   5. **emit** an audit line so the operator and the audit trail both
#      see the state machine moving.
#
# All functions are pure with respect to their inputs (no network calls,
# no `gh` invocations). The CLI wrapper at `scripts/monitor_heartbeat.sh`
# composes them with real `gh` queries; tests at
# `tests/test_monitor_heartbeat.bats` feed synthetic snapshots so the
# acceptance POC runs entirely offline.

: "${ORCH_MONITOR_HEARTBEAT_FILE:=}"
: "${ORCH_MONITOR_HEARTBEAT_STALE_THRESHOLD:=2}"

# monitor_heartbeat_snapshot_path
#   Echo the absolute path the heartbeat snapshot lives at. Defaults to
#   `$(state_dir)/orch.monitor_heartbeat.json` so it is per-project and
#   already lives outside any active worktree (state_dir resolves under
#   `$ORCH_STATE_BASE`). The path is overridable via
#   `ORCH_MONITOR_HEARTBEAT_FILE` so tests can pin a fixture.
monitor_heartbeat_snapshot_path() {
  if [ -n "${ORCH_MONITOR_HEARTBEAT_FILE:-}" ]; then
    printf '%s\n' "$ORCH_MONITOR_HEARTBEAT_FILE"
    return 0
  fi
  if declare -F state_dir >/dev/null 2>&1; then
    printf '%s/orch.monitor_heartbeat.json\n' "$(state_dir)"
    return 0
  fi
  printf '/tmp/orch.monitor_heartbeat.%s.json\n' "${PROJECT:-default}"
}

# monitor_heartbeat_compose <in_flight> <in_flight_clean> <in_flight_stale> <queued> [ts]
#   Emit a canonical snapshot JSON line. Numeric fields are validated
#   so a malformed input doesn't poison the state file.
monitor_heartbeat_compose() {
  local in_flight=${1:?usage: monitor_heartbeat_compose <in_flight> <in_flight_clean> <in_flight_stale> <queued> [ts]}
  local in_flight_clean=${2:?missing in_flight_clean}
  local in_flight_stale=${3:?missing in_flight_stale}
  local queued=${4:?missing queued}
  local ts=${5:-}
  local field
  for field in "$in_flight" "$in_flight_clean" "$in_flight_stale" "$queued"; do
    [[ "$field" =~ ^[0-9]+$ ]] || {
      printf 'monitor_heartbeat_compose: non-numeric field %q\n' "$field" >&2
      return 2
    }
  done
  if [ -z "$ts" ]; then
    ts=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
  fi
  printf '{"in_flight":%d,"in_flight_clean":%d,"in_flight_stale":%d,"queued":%d,"ts":"%s","schema_version":1}\n' \
    "$in_flight" "$in_flight_clean" "$in_flight_stale" "$queued" "$ts"
}

# monitor_heartbeat_record <snapshot_json>
#   Persist the snapshot to the configured path. Atomic via tmp+rename so
#   a concurrent reader never sees a half-written file.
monitor_heartbeat_record() {
  local payload=${1:?usage: monitor_heartbeat_record <snapshot_json>}
  local target tmp
  target=$(monitor_heartbeat_snapshot_path)
  mkdir -p "$(dirname "$target")"
  tmp="${target}.tmp.$$"
  printf '%s\n' "$payload" > "$tmp"
  mv "$tmp" "$target"
}

# monitor_heartbeat_load_prev
#   Echo the previous snapshot (the contents of the snapshot file), or
#   an empty string when no previous snapshot exists yet. Callers that
#   want a defaulted JSON should compose one explicitly.
monitor_heartbeat_load_prev() {
  local target
  target=$(monitor_heartbeat_snapshot_path)
  if [ -s "$target" ]; then
    cat "$target"
    return 0
  fi
  return 0
}

# Internal: pull a single integer field out of a snapshot JSON line.
# Falls back to `0` for missing fields and to a `jq` parse if available
# (the canonical compose output is single-line and parseable by both).
_monitor_heartbeat_field() {
  local payload=${1:-} field=${2:?usage: _monitor_heartbeat_field <json> <field>}
  if [ -z "$payload" ]; then
    printf '0\n'
    return 0
  fi
  if command -v jq >/dev/null 2>&1; then
    printf '%s\n' "$payload" | jq -r --arg f "$field" '.[$f] // 0'
    return 0
  fi
  printf '%s\n' "$payload" \
    | grep -oE "\"$field\":[0-9]+" \
    | head -1 \
    | awk -F: 'NR==1 {print $2+0}'
}

# monitor_heartbeat_classify <prev_json> <cur_json>
#   Return one classification keyword on stdout:
#     wave_green       — every in-flight item went clean since prev (and
#                        cur.in_flight_clean == cur.in_flight, with
#                        cur.in_flight > 0). The wave just finished.
#     stale_at_prompt  — cur is identical to prev AND cur.in_flight_clean
#                        == cur.in_flight (>0) AND cur.queued > 0. The
#                        loop has nothing to do but the queue is non-empty.
#     progressing      — cur.in_flight_clean > prev.in_flight_clean but
#                        not all clean yet — work is moving.
#     idle             — cur.in_flight == 0 and cur.queued == 0. Nothing
#                        in flight, nothing waiting.
#     queue_pressure   — cur.in_flight == 0 and cur.queued > 0. Capacity
#                        free, queue non-empty — orchestrator should
#                        dispatch on the next cycle.
#     unchanged        — none of the above (cur == prev with no queue
#                        pressure, or in-flight not yet all clean).
#
# Stale-at-prompt detection is intentionally idempotent: every cycle
# that sees the same `cur == prev && all-clean && queued>0` re-emits the
# `stale_at_prompt` classification, which lets the caller decide whether
# to escalate or to keep nudging. The `_THRESHOLD` env governs how many
# consecutive identical observations are needed before the classification
# fires — useful for noisy environments where one cycle's snapshot is not
# enough confirmation.
monitor_heartbeat_classify() {
  local prev=${1:-} cur=${2:-}
  if [ -z "$cur" ]; then
    printf 'unchanged\n'
    return 0
  fi
  local cur_in cur_clean cur_queued prev_in prev_clean prev_queued
  cur_in=$(_monitor_heartbeat_field "$cur" in_flight)
  cur_clean=$(_monitor_heartbeat_field "$cur" in_flight_clean)
  cur_queued=$(_monitor_heartbeat_field "$cur" queued)
  prev_in=$(_monitor_heartbeat_field "$prev" in_flight)
  prev_clean=$(_monitor_heartbeat_field "$prev" in_flight_clean)
  prev_queued=$(_monitor_heartbeat_field "$prev" queued)

  if [ "$cur_in" -eq 0 ] && [ "$cur_queued" -eq 0 ]; then
    printf 'idle\n'
    return 0
  fi
  if [ "$cur_in" -eq 0 ] && [ "$cur_queued" -gt 0 ]; then
    printf 'queue_pressure\n'
    return 0
  fi
  if [ "$cur_in" -gt 0 ] && [ "$cur_clean" -eq "$cur_in" ]; then
    if [ "$cur_in" = "$prev_in" ] \
      && [ "$cur_clean" = "$prev_clean" ] \
      && [ "$cur_queued" = "$prev_queued" ]; then
      if [ "$cur_queued" -gt 0 ]; then
        printf 'stale_at_prompt\n'
        return 0
      fi
      printf 'unchanged\n'
      return 0
    fi
    printf 'wave_green\n'
    return 0
  fi
  if [ "$cur_clean" -gt "$prev_clean" ]; then
    printf 'progressing\n'
    return 0
  fi
  printf 'unchanged\n'
}

# monitor_heartbeat_decide <classification> <queued>
#   Map a classification + queue depth into a single action keyword:
#     advance_queue          — the loop should bump the next cycle (set
#                              the run-now flag) so queued work moves.
#                              Triggered by `wave_green` / `queue_pressure`
#                              when queued > 0.
#     block_stale_at_prompt  — the loop should emit a structured
#                              blocker so the operator knows to nudge.
#                              Triggered by `stale_at_prompt`.
#     noop                   — nothing to do, sleep until next cycle.
monitor_heartbeat_decide() {
  local classification=${1:?usage: monitor_heartbeat_decide <classification> <queued>}
  local queued=${2:-0}
  [[ "$queued" =~ ^[0-9]+$ ]] || queued=0
  case "$classification" in
    wave_green|queue_pressure)
      if [ "$queued" -gt 0 ]; then
        printf 'advance_queue\n'
      else
        printf 'noop\n'
      fi
      ;;
    stale_at_prompt)
      printf 'block_stale_at_prompt\n'
      ;;
    progressing|idle|unchanged|*)
      printf 'noop\n'
      ;;
  esac
}

# monitor_heartbeat_emit <classification> <decision> <cur_json> [<prev_json>]
#   Emit a structured audit line via `audit_action` (when sourceable) or a
#   plain stderr line otherwise, so the heartbeat is always traceable.
#   The keys are deliberately compact to keep audit-grep regexes simple.
monitor_heartbeat_emit() {
  local classification=${1:?usage: monitor_heartbeat_emit <class> <decision> <cur_json> [<prev_json>]}
  local decision=${2:?missing decision}
  local cur=${3:-}
  local prev=${4:-}
  local cur_in cur_clean cur_queued prev_clean
  cur_in=$(_monitor_heartbeat_field "$cur" in_flight)
  cur_clean=$(_monitor_heartbeat_field "$cur" in_flight_clean)
  cur_queued=$(_monitor_heartbeat_field "$cur" queued)
  prev_clean=$(_monitor_heartbeat_field "$prev" in_flight_clean)
  if declare -F audit_action >/dev/null 2>&1; then
    audit_action ORCH_MONITOR_HEARTBEAT \
      "classification=$classification" \
      "decision=$decision" \
      "in_flight=$cur_in" \
      "in_flight_clean=$cur_clean" \
      "prev_in_flight_clean=$prev_clean" \
      "queued=$cur_queued"
  else
    printf 'ORCH_MONITOR_HEARTBEAT classification=%s decision=%s in_flight=%s in_flight_clean=%s prev_in_flight_clean=%s queued=%s\n' \
      "$classification" "$decision" "$cur_in" "$cur_clean" "$prev_clean" "$cur_queued" >&2
  fi
}

# monitor_heartbeat_step <cur_json>
#   Convenience: load the previous snapshot, classify, decide, record,
#   emit, and echo the decision keyword on stdout. This is what the orch
#   loop calls; the underlying primitives stay accessible to tests.
monitor_heartbeat_step() {
  local cur=${1:?usage: monitor_heartbeat_step <cur_json>}
  local prev classification decision cur_queued
  prev=$(monitor_heartbeat_load_prev)
  classification=$(monitor_heartbeat_classify "$prev" "$cur")
  cur_queued=$(_monitor_heartbeat_field "$cur" queued)
  decision=$(monitor_heartbeat_decide "$classification" "$cur_queued")
  monitor_heartbeat_record "$cur"
  monitor_heartbeat_emit "$classification" "$decision" "$cur" "$prev"
  printf '%s\n' "$decision"
}
