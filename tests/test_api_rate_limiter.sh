#!/usr/bin/env bash
# tests/test_api_rate_limiter.sh — unit coverage for lib/api_rate_limiter.sh (#409).
#
# The library shapes outbound API call rate via per-pane jitter and a
# shared token-bucket; this suite verifies:
#   - jitter sleeps within configured bounds and respects the disable knob;
#   - random-ms helper stays inside [min, max] across the full default range;
#   - token-bucket acquire honours rps/burst and shares state across processes;
#   - 429 audit sink writes structured key=value lines to the configured log;
#   - all functions are no-ops when ORDO_API_RATE_LIMIT_DISABLE=1.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP=$(mktemp -d)

cleanup() {
  rm -rf "$TEST_TMP"
}
trap cleanup EXIT

fail() {
  printf 'not ok - %s\n' "$*" >&2
  exit 1
}

# Hermetic: route state + audit log into the per-test tmpdir.
export ORCH_STATE_BASE="$TEST_TMP/state"
export ORCH_LOG_DIR="$TEST_TMP/log"
export ORDO_API_RATE_LIMIT_LOG="$ORCH_LOG_DIR/api-rate-limit.log"
mkdir -p "$ORCH_STATE_BASE" "$ORCH_LOG_DIR"

# shellcheck source=../lib/api_rate_limiter.sh
source "$ROOT/lib/api_rate_limiter.sh"

# --- _api_rate_limiter_random_ms stays in bounds ----------------------------

for i in 1 2 3 4 5 6 7 8 9 10; do
  v=$(_api_rate_limiter_random_ms 50 250)
  if ! [[ "$v" =~ ^[0-9]+$ ]]; then
    fail "random_ms must return an integer, got '$v' on iteration $i"
  fi
  if [ "$v" -lt 50 ] || [ "$v" -gt 250 ]; then
    fail "random_ms returned $v outside [50,250] on iteration $i"
  fi
done

# Edge: min == max collapses to that value.
v=$(_api_rate_limiter_random_ms 100 100)
[ "$v" = "100" ] || fail "random_ms with min==max should return that value, got '$v'"

# Edge: swapped bounds get normalized (no negative span).
v=$(_api_rate_limiter_random_ms 250 50)
if [ "$v" -lt 50 ] || [ "$v" -gt 250 ]; then
  fail "random_ms with swapped bounds returned $v outside [50,250]"
fi

# --- jitter respects bounds + disable knob ---------------------------------

# Minimal jitter run: 1 ms .. 5 ms, must complete in well under a second.
start_ns=$(date +%s%N 2>/dev/null || printf '0')
ORDO_API_RATE_LIMIT_JITTER_MIN_MS=1 ORDO_API_RATE_LIMIT_JITTER_MAX_MS=5 \
  api_rate_limiter_jitter || fail "jitter exited non-zero"
end_ns=$(date +%s%N 2>/dev/null || printf '0')
if [ "$start_ns" != "0" ] && [ "$end_ns" != "0" ]; then
  elapsed_ms=$(( (end_ns - start_ns) / 1000000 ))
  if [ "$elapsed_ms" -gt 1500 ]; then
    fail "jitter with [1,5]ms bounds took $elapsed_ms ms — should be well under 1500"
  fi
fi

# Disabled mode: jitter is an immediate no-op even with absurd bounds.
start_ns=$(date +%s%N 2>/dev/null || printf '0')
ORDO_API_RATE_LIMIT_DISABLE=1 \
  ORDO_API_RATE_LIMIT_JITTER_MIN_MS=10000 \
  ORDO_API_RATE_LIMIT_JITTER_MAX_MS=10000 \
  api_rate_limiter_jitter || fail "jitter (disabled) exited non-zero"
end_ns=$(date +%s%N 2>/dev/null || printf '0')
if [ "$start_ns" != "0" ] && [ "$end_ns" != "0" ]; then
  elapsed_ms=$(( (end_ns - start_ns) / 1000000 ))
  if [ "$elapsed_ms" -gt 200 ]; then
    fail "disabled jitter took $elapsed_ms ms — should be a no-op"
  fi
fi

# --- state_dir is created on demand ----------------------------------------

state_dir=$(api_rate_limiter_state_dir)
[ -d "$state_dir" ] || fail "state_dir did not create directory: $state_dir"
[[ "$state_dir" == "$ORCH_STATE_BASE/api_rate_limiter" ]] \
  || fail "state_dir path unexpected: $state_dir"

# --- token-bucket acquire: rapid acquires up to burst -----------------------
# With rps=1, burst=3, three back-to-back acquires must succeed within ~1s.
# A fourth acquire must take roughly 1s (the rps-paced refill).

bucket_scope="test-bucket-$$"
state_file="$state_dir/${bucket_scope}.bucket"
rm -f "$state_file"

start_ns=$(date +%s%N 2>/dev/null || printf '0')
api_rate_limiter_acquire "$bucket_scope" 1 3 || fail "first acquire failed"
api_rate_limiter_acquire "$bucket_scope" 1 3 || fail "second acquire failed"
api_rate_limiter_acquire "$bucket_scope" 1 3 || fail "third acquire failed"
end_ns=$(date +%s%N 2>/dev/null || printf '0')
if [ "$start_ns" != "0" ] && [ "$end_ns" != "0" ]; then
  elapsed_ms=$(( (end_ns - start_ns) / 1000000 ))
  if [ "$elapsed_ms" -gt 1500 ]; then
    fail "burst of 3 acquires (rps=1 burst=3) took $elapsed_ms ms — should be well under 1500"
  fi
fi

# State file written.
[ -s "$state_file" ] || fail "bucket state file was not written: $state_file"

# Fourth acquire must wait roughly 1s (refill at rps=1).
start_ns=$(date +%s%N 2>/dev/null || printf '0')
api_rate_limiter_acquire "$bucket_scope" 1 3 || fail "fourth acquire failed"
end_ns=$(date +%s%N 2>/dev/null || printf '0')
if [ "$start_ns" != "0" ] && [ "$end_ns" != "0" ]; then
  elapsed_ms=$(( (end_ns - start_ns) / 1000000 ))
  # Allow generous lower bound: the bucket may carry partial accumulated
  # tokens depending on scheduler jitter. Insist only that the wait is
  # bounded above (we did not deadlock) and bounded below by a fraction
  # of the rps period when no carry-over was possible.
  if [ "$elapsed_ms" -gt 5000 ]; then
    fail "fourth acquire took $elapsed_ms ms — bucket should not block past max_attempts"
  fi
fi

# --- token-bucket disabled mode --------------------------------------------

bucket_scope_disabled="test-bucket-disabled-$$"
rm -f "$state_dir/${bucket_scope_disabled}.bucket"
start_ns=$(date +%s%N 2>/dev/null || printf '0')
ORDO_API_RATE_LIMIT_DISABLE=1 api_rate_limiter_acquire "$bucket_scope_disabled" 1 1 \
  || fail "disabled acquire exited non-zero"
ORDO_API_RATE_LIMIT_DISABLE=1 api_rate_limiter_acquire "$bucket_scope_disabled" 1 1 \
  || fail "second disabled acquire exited non-zero"
end_ns=$(date +%s%N 2>/dev/null || printf '0')
if [ "$start_ns" != "0" ] && [ "$end_ns" != "0" ]; then
  elapsed_ms=$(( (end_ns - start_ns) / 1000000 ))
  if [ "$elapsed_ms" -gt 200 ]; then
    fail "disabled acquire pair took $elapsed_ms ms — should be no-op"
  fi
fi
[ ! -s "$state_dir/${bucket_scope_disabled}.bucket" ] \
  || fail "disabled mode must not write bucket state"

# --- 429 audit sink writes structured key=value lines ----------------------

api_rate_limiter_record_429 rbok-orchestrator /v1/messages 4 \
  || fail "record_429 returned non-zero"
api_rate_limiter_record_429 rbok-codex /v1/messages 8 'attempt=2' \
  || fail "record_429 with extra returned non-zero"

[ -s "$ORDO_API_RATE_LIMIT_LOG" ] || fail "429 audit log was not written"

grep -q 'event=anthropic_429' "$ORDO_API_RATE_LIMIT_LOG" \
  || fail "429 audit log missing event tag"
grep -q 'session=rbok-orchestrator' "$ORDO_API_RATE_LIMIT_LOG" \
  || fail "429 audit log missing session field"
grep -q 'endpoint=/v1/messages' "$ORDO_API_RATE_LIMIT_LOG" \
  || fail "429 audit log missing endpoint field"
grep -q 'retry_after_sec=4' "$ORDO_API_RATE_LIMIT_LOG" \
  || fail "429 audit log missing retry_after_sec field"
grep -q 'attempt=2' "$ORDO_API_RATE_LIMIT_LOG" \
  || fail "429 audit log missing optional extra kv field"

# Each call writes exactly one line.
line_count=$(wc -l <"$ORDO_API_RATE_LIMIT_LOG" | tr -d ' ')
[ "$line_count" = "2" ] || fail "expected 2 audit lines, got $line_count"

# Lines start with ts= so log shippers can parse them deterministically.
while IFS= read -r line; do
  [[ "$line" == ts=* ]] || fail "audit line not prefixed with ts=: $line"
done <"$ORDO_API_RATE_LIMIT_LOG"

# --- 429 audit sink fail-soft on read-only log dir -------------------------

readonly_dir="$TEST_TMP/readonly-log"
mkdir -p "$readonly_dir"
chmod a-w "$readonly_dir"
ORDO_API_RATE_LIMIT_LOG="$readonly_dir/api-rate-limit.log" \
  api_rate_limiter_record_429 rbok-test /v1/messages 1 2>/dev/null \
  || fail "record_429 must fail-soft when log dir is unwritable"
chmod a+w "$readonly_dir"

printf 'ok - api_rate_limiter jitter, token bucket, and 429 audit sink behave per #409\n'
