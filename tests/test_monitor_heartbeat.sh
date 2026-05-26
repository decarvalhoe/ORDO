#!/usr/bin/env bash
# tests/test_monitor_heartbeat.sh — issue #790 stopped-loop watchdog coverage.
#
# The monitor heartbeat must not silently observe queued work while the
# per-project orch_loop is stopped. It should invoke the existing audited
# orch-loop watchdog when the profile is not explicitly paused, and
# orch_ctl status should show the watchdog state that was recorded.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP=$(mktemp -d)
SANITIZED_ROOT="$TEST_TMP/toolkit"

cleanup() {
  rm -rf "$TEST_TMP"
}
trap cleanup EXIT

fail() {
  printf 'not ok - %s\n' "$*" >&2
  exit 1
}

# shellcheck source=../lib/test_sanitize.sh
# shellcheck disable=SC1091
source "$ROOT/lib/test_sanitize.sh"
sanitize_toolkit_copy "$SANITIZED_ROOT" \
  scripts/monitor_heartbeat.sh \
  scripts/orch_ctl.sh

mkdir -p \
  "$TEST_TMP/bin" \
  "$TEST_TMP/logs" \
  "$TEST_TMP/proc-empty" \
  "$TEST_TMP/state/monitor-watchdog-test" \
  "$SANITIZED_ROOT/scripts"

cat > "$SANITIZED_ROOT/scripts/ensure_alive.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${ORCH_TEST_RESTART_LOG:?missing restart log}"
exit "${ORCH_TEST_RESTART_RC:-0}"
EOF
chmod +x "$SANITIZED_ROOT/scripts/ensure_alive.sh"

cat > "$TEST_TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$TEST_TMP/bin/gh"

config="$TEST_TMP/monitor.config.sh"
cat > "$config" <<EOF
#!/usr/bin/env bash
PROJECT="monitor-watchdog-test"
GH_REPO="RBOKproject/ORDO"
GH_CONFIG_DIR="$TEST_TMP/gh"
DEFAULT_BRANCH="main"
AGENT_SESSION_PREFIX=""
AGENT_REPO_PREFIX="$TEST_TMP/repos/"
AGENT_WORKDIR_TEMPLATE="$TEST_TMP/repos/%s"
AGENTS=(fleet-001)
ORCH_SUPERVISOR_WORKDIR="$TEST_TMP/supervisor"
ORCH_LOOP_DAEMON_CONFIRM="test-operator"
EOF

run_monitor() {
  PATH="$TEST_TMP/bin:$PATH" \
  TK="$SANITIZED_ROOT" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  ORCH_PROC_DIR="$TEST_TMP/proc-empty" \
  ORCH_RUNTIME_FRESHNESS_DISABLED=1 \
  ORCH_MONITOR_HEARTBEAT_IN_FLIGHT="${ORCH_MONITOR_HEARTBEAT_IN_FLIGHT:-0}" \
  ORCH_MONITOR_HEARTBEAT_IN_FLIGHT_CLEAN="${ORCH_MONITOR_HEARTBEAT_IN_FLIGHT_CLEAN:-0}" \
  ORCH_MONITOR_HEARTBEAT_IN_FLIGHT_STALE="${ORCH_MONITOR_HEARTBEAT_IN_FLIGHT_STALE:-0}" \
  ORCH_MONITOR_HEARTBEAT_QUEUED="${ORCH_MONITOR_HEARTBEAT_QUEUED:-0}" \
  ORCH_TEST_RESTART_RC="${ORCH_TEST_RESTART_RC:-0}" \
  ORCH_TEST_RESTART_LOG="$TEST_TMP/restart.log" \
  bash "$SANITIZED_ROOT/scripts/monitor_heartbeat.sh" "$config" 2>&1
}

run_status() {
  PATH="$TEST_TMP/bin:$PATH" \
  TK="$SANITIZED_ROOT" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  ORCH_PROC_DIR="$TEST_TMP/proc-empty" \
  ORCH_NOW_OVERRIDE=2000000000 \
  bash "$SANITIZED_ROOT/scripts/orch_ctl.sh" "$config" status 2>&1
}

# T1: stopped + not paused + queued work invokes the audited orch-loop
# watchdog path and records visible status fields.
ORCH_MONITOR_HEARTBEAT_QUEUED=3 out=$(run_monitor)
[[ "$out" == *"restart_attempted"* ]] || \
  fail "T1: stopped loop with queued work should emit restart_attempted, got: $out"
[[ -s "$TEST_TMP/restart.log" ]] || \
  fail "T1: restart watchdog was not invoked"
grep -F "orch-loop $config --once" "$TEST_TMP/restart.log" >/dev/null || \
  fail "T1: restart watchdog call was not the audited orch-loop path: $(cat "$TEST_TMP/restart.log")"
grep -F "ORCH_LOOP_WATCHDOG_SUPERVISION" "$TEST_TMP/logs/monitor-watchdog-test.log" >/dev/null || \
  fail "T1: supervision audit line missing: $(cat "$TEST_TMP/logs/monitor-watchdog-test.log" 2>/dev/null || true)"

status_out=$(run_status)
[[ "$status_out" == *"supervised:      true"* ]] || \
  fail "T1: orch_ctl status missing supervised=true, got: $status_out"
[[ "$status_out" == *"restart_attempts: 1"* ]] || \
  fail "T1: orch_ctl status missing restart_attempts=1, got: $status_out"
[[ "$status_out" == *"last_restart:   "*"Z"* ]] || \
  fail "T1: orch_ctl status missing last_restart timestamp, got: $status_out"
[[ "$status_out" == *"last_stop_reason: loop-not-running work-remaining"* ]] || \
  fail "T1: orch_ctl status missing last_stop_reason, got: $status_out"

# T2: an explicit pause is a hard no-restart gate, even with ready work.
rm -f "$TEST_TMP/restart.log"
touch "$TEST_TMP/state/monitor-watchdog-test/orch.paused"
ORCH_MONITOR_HEARTBEAT_QUEUED=4 paused_out=$(run_monitor)
[[ "$paused_out" != *"restart_attempted"* ]] || \
  fail "T2: paused profile must not emit restart_attempted, got: $paused_out"
[[ ! -s "$TEST_TMP/restart.log" ]] || \
  fail "T2: paused profile must not invoke restart watchdog: $(cat "$TEST_TMP/restart.log")"
grep -F "reason=paused" "$TEST_TMP/logs/monitor-watchdog-test.log" >/dev/null || \
  fail "T2: paused no-restart decision was not audited"

# T3: if the audited restart path refuses, record an operator intervention
# row so the failure does not end in silence.
rm -f "$TEST_TMP/restart.log" "$TEST_TMP/state/monitor-watchdog-test/orch.paused" \
  "$TEST_TMP/state/monitor-watchdog-test/intervention_queue.md"
ORCH_MONITOR_HEARTBEAT_QUEUED=2 ORCH_TEST_RESTART_RC=14 blocked_out=$(run_monitor)
[[ "$blocked_out" == *"restart_blocked"* ]] || \
  fail "T3: restart failure should emit restart_blocked, got: $blocked_out"
grep -F "OPERATOR_AUTHORIZATION_REQUIRED" "$TEST_TMP/logs/monitor-watchdog-test.log" >/dev/null || \
  fail "T3: restart failure did not emit operator authorization audit row"
queue_path="$TEST_TMP/state/monitor-watchdog-test/intervention_queue.md"
[[ -s "$queue_path" ]] || \
  fail "T3: restart failure must append to intervention_queue.md"
grep -F "| monitor_heartbeat | monitor-watchdog-test |" "$queue_path" >/dev/null || \
  fail "T3: intervention row missing monitor_heartbeat/project: $(cat "$queue_path")"

printf 'ok - monitor heartbeat supervises stopped loops with queued work\n'
