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

printf 'ok - process_safety guards locks, budgets, and tmux probes\n'
