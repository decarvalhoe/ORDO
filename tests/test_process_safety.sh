#!/usr/bin/env bash
set -euo pipefail

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

source "$ROOT/lib/process_safety.sh"

ORCH_STATE_BASE="$TEST_TMP/state"
orch_single_flight_enter "test.scan" 60 || fail "expected first single-flight lock"
set +e
orch_single_flight_enter "test.scan" 60
second_status=$?
set -e
[[ "$second_status" -eq 75 ]] || fail "expected overlapping lock to return 75, got $second_status"
[[ "${ORCH_SINGLE_FLIGHT_OWNER_PID:-}" == "$$" ]] || fail "expected current pid as lock owner"
orch_single_flight_release "$(orch_lock_path "test.scan")"
orch_single_flight_enter "test.scan" 60 || fail "expected lock to be acquirable after release"
orch_single_flight_release "$(orch_lock_path "test.scan")"

# #146 — dead owner PID is reclaimed even within the TTL window.
dead_lock_dir=$(orch_lock_path "test.dead")
mkdir -p "$dead_lock_dir"
# Pick a PID that cannot exist (max + 1 within /proc/sys/kernel/pid_max bounds).
dead_pid=$(($(cat /proc/sys/kernel/pid_max 2>/dev/null || printf '4194304') - 1))
while kill -0 "$dead_pid" 2>/dev/null; do
  dead_pid=$((dead_pid - 1))
done
printf '%s\n' "$dead_pid" > "$dead_lock_dir/pid"
date +%s > "$dead_lock_dir/started"
orch_single_flight_enter "test.dead" 600 \
  || fail "expected dead-owner lock to be reclaimed under TTL"
[[ "$(cat "$dead_lock_dir/pid")" == "$$" ]] \
  || fail "expected reclaimed lock to record current pid"
orch_single_flight_release "$dead_lock_dir"

# #146 — TTL is capped to ORCH_SINGLE_FLIGHT_TTL_MAX_SEC, so a 20-day-old lock
# left behind by a long-gone alive-looking owner is reclaimed instead of
# blocking forever.
stale_lock_dir=$(orch_lock_path "test.stale")
mkdir -p "$stale_lock_dir"
printf '%s\n' "$$" > "$stale_lock_dir/pid"
old_started=$(( $(date +%s) - 1778161647 ))  # ~20 days, matches the bug repro.
printf '%s\n' "$old_started" > "$stale_lock_dir/started"
ORCH_SINGLE_FLIGHT_TTL_MAX_SEC=60 \
  orch_single_flight_enter "test.stale" 99999999 \
  || fail "expected ttl-capped reclaim of 20-day-old lock"
[[ "$(date +%s)" -ge "$(cat "$stale_lock_dir/started")" ]] \
  || fail "expected reclaimed lock to refresh started timestamp"
orch_single_flight_release "$stale_lock_dir"

# #146 — unwritable state base falls back to a writable mktemp root.
fallback_block_root="$TEST_TMP/blocked"
: > "$fallback_block_root"  # create as a regular file → mkdir -p will fail
ORCH_STATE_BASE="$fallback_block_root/state-base" \
  orch_single_flight_enter "test.fallback" 60 \
  || fail "expected fallback lock acquisition under unwritable state base"
[[ -n "${ORCH_STATE_BASE_FALLBACK:-}" ]] \
  || fail "expected ORCH_STATE_BASE_FALLBACK to be exported after fallback"
[[ -d "$ORCH_STATE_BASE_FALLBACK/_locks" ]] \
  || fail "expected fallback lock root to exist"
[[ "${ORCH_SINGLE_FLIGHT_LOCK_DIR:-}" == "$ORCH_STATE_BASE_FALLBACK/_locks/test.fallback.lock" ]] \
  || fail "expected lock dir under fallback root, got ${ORCH_SINGLE_FLIGHT_LOCK_DIR:-}"
orch_single_flight_release
rm -rf "$ORCH_STATE_BASE_FALLBACK"
unset ORCH_STATE_BASE_FALLBACK
ORCH_STATE_BASE="$TEST_TMP/state"

ORCH_PROCESS_BUDGET_WARN_PROCS=1
ORCH_PROCESS_BUDGET_MAX_PROCS=1
set +e
budget_signal=$(orch_process_budget_signal)
budget_status=$?
set -e
[[ "$budget_status" -eq 1 ]] || fail "expected process budget hard degradation"
[[ "$budget_signal" == "process_budget_degraded,fork_risk" ]] || fail "unexpected budget signal: $budget_signal"

mkdir -p "$TEST_TMP/bin"
cat > "$TEST_TMP/bin/tmux" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "list-panes" ]]; then
  sleep 2
fi
EOF
chmod +x "$TEST_TMP/bin/tmux"

ORCH_TMUX_LIST_PANES_TIMEOUT_SEC=1
set +e
PATH="$TEST_TMP/bin:$PATH" orch_tmux_probe
tmux_status=$?
set -e
[[ "$tmux_status" -eq 1 ]] || fail "expected tmux probe timeout"
[[ "${ORCH_TMUX_DEGRADED_REASON:-}" == *"tmux list-panes exceeded 1s"* ]] || \
  fail "unexpected tmux degraded reason: ${ORCH_TMUX_DEGRADED_REASON:-missing}"

latency_ms=$(orch_fork_latency_ms)
[[ "$latency_ms" =~ ^[0-9]+$ ]] || fail "expected numeric fork latency, got: $latency_ms"

set +e
degraded_output=$(ORCH_VALIDATOR_FORK_LATENCY_MAX_MS=0 orch_validator_fork_preflight "unit-test" 2>&1)
degraded_status=$?
set -e
[[ "$degraded_status" -eq 75 ]] || fail "expected fork preflight degraded exit 75, got $degraded_status"
[[ "$degraded_output" == *"validators_degraded"* ]] || fail "expected validators_degraded message, got: $degraded_output"
[[ "$degraded_output" == *"validator=unit-test"* ]] || fail "expected validator name in degraded message, got: $degraded_output"

ORCH_VALIDATOR_FORK_LATENCY_MAX_MS=999999 orch_validator_fork_preflight "unit-test" \
  || fail "expected high threshold fork preflight to pass"

printf 'ok - process_safety guards locks, budgets, and tmux probes\n'
