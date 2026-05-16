#!/usr/bin/env bash
# tests/test_ensure_alive.sh - regression coverage for orch_loop service pane watchdog.
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

mkdir -p "$TEST_TMP/bin" "$TEST_TMP/logs" "$TEST_TMP/state" "$TEST_TMP/supervisor" "$TEST_TMP/worker"

# shellcheck source=../lib/test_sanitize.sh
source "$ROOT/lib/test_sanitize.sh"
sanitize_toolkit_copy "$SANITIZED_ROOT" \
  scripts/ensure_alive.sh \
  scripts/orch_loop.sh

cat > "$TEST_TMP/bin/tmux" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf 'tmux' >> "${FAKE_TMUX_LOG:?}"
for arg in "$@"; do
  printf '\t%s' "$arg" >> "$FAKE_TMUX_LOG"
done
printf '\n' >> "$FAKE_TMUX_LOG"

case "${1:-}" in
  has-session)
    [[ "${FAKE_TMUX_HAS_SESSION:-1}" == "1" ]]
    ;;
  list-panes)
    [[ "${FAKE_TMUX_LIST_PANES_FAIL:-0}" != "1" ]] || exit 1
    printf '%s\t%s\t%s\t%s\n' \
      "${FAKE_TMUX_PANE_INDEX:-0}" \
      "${FAKE_TMUX_PANE_DEAD:-1}" \
      "${FAKE_TMUX_PANE_STATUS:-9}" \
      "${FAKE_TMUX_PANE_PID:-1234}"
    ;;
  new-session|new-window|respawn-pane)
    exit 0
    ;;
  capture-pane)
    printf '%s\n' "${FAKE_TMUX_CAPTURE:-}"
    ;;
  *)
    printf 'unexpected tmux command: %s\n' "$*" >&2
    exit 99
    ;;
esac
EOF
chmod +x "$TEST_TMP/bin/tmux"

cat > "$TEST_TMP/bin/codex" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf 'codex' >> "${FAKE_CODEX_LOG:?}"
for arg in "$@"; do
  printf '\t%s' "$arg" >> "$FAKE_CODEX_LOG"
done
printf '\n' >> "$FAKE_CODEX_LOG"
EOF
chmod +x "$TEST_TMP/bin/codex"

cat > "$TEST_TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  auth) exit 0 ;;
  *) printf '[]\n' ;;
esac
EOF
chmod +x "$TEST_TMP/bin/gh"

write_config() {
  local project=$1 prefix=$2 target=$3
  cat > "$target" <<EOF
#!/usr/bin/env bash
PROJECT="$project"
GH_REPO="RBOKproject/ORDO"
GH_CONFIG_DIR="$TEST_TMP/gh"
DEFAULT_BRANCH="main"
AGENT_SESSION_PREFIX="$prefix"
ORCH_CLI_BIN="codex"
ORCH_SUPERVISOR_WORKDIR="$TEST_TMP/supervisor"
PROJECT_REPO_ROOT="$TEST_TMP/worker"
AGENT_WORKDIR_TEMPLATE="$TEST_TMP/worker/%s"
EOF
}

run_watchdog_once() {
  local config=$1 log=$2
  shift 2
  timeout 5 env \
    BASH_ENV=/dev/null \
    PATH="$TEST_TMP/bin:$PATH" \
    ORCH_LOG_DIR="$TEST_TMP/logs" \
    ORCH_STATE_BASE="$TEST_TMP/state" \
    TK="$SANITIZED_ROOT" \
    FAKE_TMUX_LOG="$log" \
    "$@" \
    bash "$SANITIZED_ROOT/scripts/ensure_alive.sh" orch-loop "$config" --once
}

write_supervisor_config() {
  local project=$1 prefix=$2 target=$3
  cat > "$target" <<EOF
#!/usr/bin/env bash
PROJECT="$project"
GH_REPO="RBOKproject/ORDO"
DEFAULT_BRANCH="main"
AGENT_SESSION_PREFIX="$prefix"
ORCH_CLI_BIN="codex"
ORCH_SUPERVISOR_CLI_FLAGS="--model gpt-5.5 --reasoning-effort xhigh --debug --yolo --search"
ORCH_SUPERVISOR_WORKDIR="$TEST_TMP/supervisor"
ORCH_SUPERVISOR_PRIORITY_QUEUE="priority queue snapshot"
ORCH_SUPERVISOR_ACTIVE_PRS="active prs snapshot"
ORCH_SUPERVISOR_ASSIGNMENTS="assignment snapshot"
ORCH_SUPERVISOR_AUDIT_LOGS="$TEST_TMP/logs/$project.log"
PROJECT_REPO_ROOT="$TEST_TMP/worker"
AGENT_WORKDIR_TEMPLATE="$TEST_TMP/worker/%s"
EOF
}

run_supervisor_once() {
  local config=$1 log=$2
  shift 2
  timeout 5 env \
    BASH_ENV=/dev/null \
    PATH="$TEST_TMP/bin:$PATH" \
    ORCH_LOG_DIR="$TEST_TMP/logs" \
    ORCH_STATE_BASE="$TEST_TMP/state" \
    TK="$SANITIZED_ROOT" \
    FAKE_TMUX_LOG="$log" \
    "$@" \
    bash "$SANITIZED_ROOT/scripts/ensure_alive.sh" orch-supervisor "$config" --once
}

write_loop_config_without_supervisor_workdir() {
  local target=$1
  cat > "$target" <<EOF
#!/usr/bin/env bash
PROJECT="loop-toolkit-workdir"
GH_REPO="RBOKproject/ORDO"
GH_CONFIG_DIR="$TEST_TMP/gh"
DEFAULT_BRANCH="main"
AGENTS=(cursor)
AGENT_SESSION_PREFIX="loop-toolkit-"
ORCH_CLI_BIN="codex"
ORCH_CODEX_MODEL="gpt-5.5"
ORCH_CODEX_APPROVAL="never"
SUPERVISOR_REPO=""
PROJECT_REPO_ROOT="$TEST_TMP/worker"
AGENT_WORKDIR_TEMPLATE="$TEST_TMP/worker/%s"
EOF
}

run_loop_once() {
  local config=$1 log=$2
  timeout 10 env \
    PATH="$TEST_TMP/bin:$PATH" \
    ORCH_LOG_DIR="$TEST_TMP/logs" \
    ORCH_STATE_BASE="$TEST_TMP/state" \
    TK="$SANITIZED_ROOT" \
    FAKE_CODEX_LOG="$log" \
    ORCH_DAEMON_CONFIRM="test" \
    ORCH_FLEET_SLOT="fleet-000" \
    ORCH_MAX_CYCLES=1 \
    ORCH_SIXSIGMA_DISABLED=1 \
    ORCH_MONITOR_HEARTBEAT_DISABLED=1 \
    bash "$SANITIZED_ROOT/scripts/orch_loop.sh" "$config"
}

assert_recovery_plan_contains() {
  local state_project=$1 pattern=$2
  local plan
  plan=$(find "$TEST_TMP/state/$state_project" -type f -name 'orchestrator-recovery-*.md' -print | head -n 1)
  [[ -n "$plan" ]] || fail "expected recovery plan under state for $state_project"
  grep -F "$pattern" "$plan" >/dev/null \
    || fail "recovery plan missing '$pattern': $(cat "$plan")"
}

loop_workdir_log="$TEST_TMP/codex-loop-workdir.log"
loop_workdir_config="$TEST_TMP/loop-toolkit-workdir.config.sh"
write_loop_config_without_supervisor_workdir "$loop_workdir_config"

set +e
loop_workdir_out=$(run_loop_once "$loop_workdir_config" "$loop_workdir_log" 2>&1)
loop_workdir_rc=$?
set -e

[[ "$loop_workdir_rc" -eq 0 ]] || fail "orch_loop exited $loop_workdir_rc: $loop_workdir_out"
grep -F $'codex\texec\t--ephemeral\t-C\t'"$SANITIZED_ROOT" "$loop_workdir_log" >/dev/null \
  || fail "orch_loop did not launch codex from toolkit workdir when ORCH_SUPERVISOR_WORKDIR is unset: $(cat "$loop_workdir_log")"
! grep -F $'\t-C\t'"$TEST_TMP/worker" "$loop_workdir_log" >/dev/null \
  || fail "orch_loop used PROJECT_REPO_ROOT instead of toolkit workdir: $(cat "$loop_workdir_log")"

respawn_log="$TEST_TMP/tmux-respawn.log"
respawn_config="$TEST_TMP/respawn.config.sh"
write_config "orch-watchdog-test" "orch-watchdog-" "$respawn_config"

set +e
respawn_out=$(run_watchdog_once "$respawn_config" "$respawn_log" 2>&1)
respawn_rc=$?
set -e

[[ "$respawn_rc" -eq 0 ]] || fail "dead pane watchdog exited $respawn_rc: $respawn_out"

expected_cmd="bash scripts/orch_loop.sh $respawn_config --daemon-confirm codex"
grep -F $'tmux\trespawn-pane\t-k\t-t\torch-watchdog-loop-svc:0.0\t-c\t'"$TEST_TMP/supervisor"$'\t'"$expected_cmd" "$respawn_log" >/dev/null \
  || fail "watchdog did not respawn service pane with supervisor workdir and command: $(cat "$respawn_log")"

! grep -F "$TEST_TMP/worker" "$respawn_log" >/dev/null \
  || fail "watchdog used worker checkout instead of ORCH_SUPERVISOR_WORKDIR: $(cat "$respawn_log")"

respawn_audit="$TEST_TMP/logs/orch-watchdog-test.log"
grep -F "ORCH_LOOP_WATCHDOG_RESPAWN" "$respawn_audit" >/dev/null \
  || fail "watchdog did not audit respawn: $(cat "$respawn_audit" 2>/dev/null || true)"
grep -F "previous_pid=1234" "$respawn_audit" >/dev/null \
  || fail "watchdog audit missing previous pane PID: $(cat "$respawn_audit")"
grep -F "previous_status=9" "$respawn_audit" >/dev/null \
  || fail "watchdog audit missing previous pane status: $(cat "$respawn_audit")"

open_loop_log="$TEST_TMP/tmux-open-loop.log"
open_loop_config="$TEST_TMP/open-loop.config.sh"
write_config "orch-watchdog-open-loop" "open-loop-" "$open_loop_config"
mkdir -p "$TEST_TMP/state/orch-watchdog-open-loop"
cat > "$TEST_TMP/state/orch-watchdog-open-loop/orch_loop_watchdog_respawns.tsv" <<'EOF'
1700000000
1699999900
1699999801
EOF

set +e
open_loop_out=$(run_watchdog_once \
  "$open_loop_config" \
  "$open_loop_log" \
  ORCH_NOW_OVERRIDE=1700000001 \
  2>&1)
open_loop_rc=$?
set -e

[[ "$open_loop_rc" -eq 2 ]] || fail "open-loop death guard should exit 2, got $open_loop_rc: $open_loop_out"
! grep -F $'tmux\trespawn-pane' "$open_loop_log" >/dev/null \
  || fail "open-loop guard respawned despite rapid-death threshold: $(cat "$open_loop_log")"

open_loop_audit="$TEST_TMP/logs/orch-watchdog-open-loop.log"
grep -F "ORCH_LOOP_WATCHDOG_OPEN_LOOP" "$open_loop_audit" >/dev/null \
  || fail "open-loop guard did not audit alert: $(cat "$open_loop_audit" 2>/dev/null || true)"
grep -F "death_count=4" "$open_loop_audit" >/dev/null \
  || fail "open-loop audit missing death_count=4: $(cat "$open_loop_audit")"

missing_pane_log="$TEST_TMP/tmux-supervisor-missing-pane.log"
missing_pane_config="$TEST_TMP/supervisor-missing-pane.config.sh"
write_supervisor_config "supervisor-missing-pane" "supervisor-missing-" "$missing_pane_config"

set +e
missing_pane_out=$(run_supervisor_once \
  "$missing_pane_config" \
  "$missing_pane_log" \
  FAKE_TMUX_LIST_PANES_FAIL=1 \
  ORCH_NOW_OVERRIDE=1700000100 \
  2>&1)
missing_pane_rc=$?
set -e

[[ "$missing_pane_rc" -eq 0 ]] || fail "missing-pane supervisor exited $missing_pane_rc: $missing_pane_out"
grep -F $'tmux\tnew-window\t-d\t-t\tsupervisor-missing-orchestrator:0\t-c\t'"$TEST_TMP/supervisor" "$missing_pane_log" >/dev/null \
  || fail "missing-pane supervisor did not create the orchestrator window: $(cat "$missing_pane_log")"
grep -F "codex exec --ephemeral -C $TEST_TMP/supervisor --model gpt-5.5 --reasoning-effort xhigh --debug --yolo --search" "$missing_pane_log" >/dev/null \
  || fail "missing-pane supervisor did not preserve codex runtime flags: $(cat "$missing_pane_log")"
missing_pane_audit="$TEST_TMP/logs/supervisor-missing-pane.log"
grep -F "ORCH_SUPERVISOR_RELAUNCH" "$missing_pane_audit" >/dev/null \
  || fail "missing-pane supervisor did not audit relaunch: $(cat "$missing_pane_audit" 2>/dev/null || true)"
grep -F "reason=missing-pane" "$missing_pane_audit" >/dev/null \
  || fail "missing-pane audit missing reason: $(cat "$missing_pane_audit")"
assert_recovery_plan_contains "supervisor-missing-pane" "Current project: supervisor-missing-pane"
assert_recovery_plan_contains "supervisor-missing-pane" "Priority queue: priority queue snapshot"
assert_recovery_plan_contains "supervisor-missing-pane" "Active PRs: active prs snapshot"
assert_recovery_plan_contains "supervisor-missing-pane" "Assignments: assignment snapshot"
assert_recovery_plan_contains "supervisor-missing-pane" "Opportunity findings policy:"

shell_pane_log="$TEST_TMP/tmux-supervisor-shell-pane.log"
shell_pane_config="$TEST_TMP/supervisor-shell-pane.config.sh"
write_supervisor_config "supervisor-shell-pane" "supervisor-shell-" "$shell_pane_config"

set +e
shell_pane_out=$(run_supervisor_once \
  "$shell_pane_config" \
  "$shell_pane_log" \
  FAKE_TMUX_PANE_DEAD=0 \
  FAKE_TMUX_CAPTURE='$ ' \
  ORCH_NOW_OVERRIDE=1700000200 \
  2>&1)
shell_pane_rc=$?
set -e

[[ "$shell_pane_rc" -eq 0 ]] || fail "shell-pane supervisor exited $shell_pane_rc: $shell_pane_out"
grep -F $'tmux\trespawn-pane\t-k\t-t\tsupervisor-shell-orchestrator:0.0\t-c\t'"$TEST_TMP/supervisor" "$shell_pane_log" >/dev/null \
  || fail "shell-pane supervisor did not respawn non-Codex pane: $(cat "$shell_pane_log")"
shell_pane_audit="$TEST_TMP/logs/supervisor-shell-pane.log"
grep -F "reason=non-supervisor-pane" "$shell_pane_audit" >/dev/null \
  || fail "shell-pane audit missing non-supervisor reason: $(cat "$shell_pane_audit" 2>/dev/null || true)"

stopped_pane_log="$TEST_TMP/tmux-supervisor-stopped-pane.log"
stopped_pane_config="$TEST_TMP/supervisor-stopped-pane.config.sh"
write_supervisor_config "supervisor-stopped-pane" "supervisor-stopped-" "$stopped_pane_config"

set +e
stopped_pane_out=$(run_supervisor_once \
  "$stopped_pane_config" \
  "$stopped_pane_log" \
  FAKE_TMUX_PANE_DEAD=1 \
  FAKE_TMUX_PANE_STATUS=143 \
  ORCH_NOW_OVERRIDE=1700000300 \
  2>&1)
stopped_pane_rc=$?
set -e

[[ "$stopped_pane_rc" -eq 0 ]] || fail "stopped-pane supervisor exited $stopped_pane_rc: $stopped_pane_out"
grep -F $'tmux\trespawn-pane\t-k\t-t\tsupervisor-stopped-orchestrator:0.0\t-c\t'"$TEST_TMP/supervisor" "$stopped_pane_log" >/dev/null \
  || fail "stopped-pane supervisor did not respawn stopped pane: $(cat "$stopped_pane_log")"
stopped_pane_audit="$TEST_TMP/logs/supervisor-stopped-pane.log"
grep -F "reason=stopped-pane" "$stopped_pane_audit" >/dev/null \
  || fail "stopped-pane audit missing stopped reason: $(cat "$stopped_pane_audit" 2>/dev/null || true)"

interactive_only_log="$TEST_TMP/tmux-supervisor-interactive-only.log"
interactive_only_config="$TEST_TMP/supervisor-interactive-only.config.sh"
write_supervisor_config "supervisor-interactive-only" "supervisor-interactive-" "$interactive_only_config"
cat >> "$interactive_only_config" <<'EOF'
ORCH_SUPERVISOR_INTERACTIVE_ONLY=1
EOF

set +e
interactive_only_out=$(run_supervisor_once \
  "$interactive_only_config" \
  "$interactive_only_log" \
  FAKE_TMUX_HAS_SESSION=0 \
  ORCH_NOW_OVERRIDE=1700000325 \
  2>&1)
interactive_only_rc=$?
set -e

[[ "$interactive_only_rc" -eq 14 ]] || \
  fail "interactive-only supervisor should refuse detached relaunch, got rc=$interactive_only_rc output=$interactive_only_out"
[[ "$interactive_only_out" == *"interactive-only mode refused detached relaunch"* ]] || \
  fail "interactive-only refusal should be explicit: $interactive_only_out"
! grep -F $'tmux\tnew-session' "$interactive_only_log" >/dev/null \
  || fail "interactive-only supervisor should not create detached tmux session: $(cat "$interactive_only_log")"
interactive_only_audit="$TEST_TMP/logs/supervisor-interactive-only.log"
grep -F "ORCH_SUPERVISOR_RELAUNCH_REFUSED" "$interactive_only_audit" >/dev/null \
  || fail "interactive-only audit missing refusal: $(cat "$interactive_only_audit" 2>/dev/null || true)"
grep -F "mode=interactive-only" "$interactive_only_audit" >/dev/null \
  || fail "interactive-only audit missing mode: $(cat "$interactive_only_audit")"

collide_log="$TEST_TMP/tmux-supervisor-collide.log"
collide_config="$TEST_TMP/supervisor-collide.config.sh"
cat > "$collide_config" <<EOF
#!/usr/bin/env bash
PROJECT="supervisor-collide"
GH_REPO="RBOKproject/ORDO"
DEFAULT_BRANCH="main"
AGENT_SESSION_PREFIX="supervisor-collide-"
ORCH_CLI_BIN="codex"
ORCH_SUPERVISOR_WORKDIR="$TEST_TMP/worker"
AGENT_PANES=("worker|worker:0.0|$TEST_TMP/worker")
PROJECT_REPO_ROOT="$TEST_TMP/worker"
AGENT_WORKDIR_TEMPLATE="$TEST_TMP/worker/%s"
EOF

set +e
collide_out=$(run_supervisor_once \
  "$collide_config" \
  "$collide_log" \
  FAKE_TMUX_HAS_SESSION=0 \
  ORCH_NOW_OVERRIDE=1700000350 \
  2>&1)
collide_rc=$?
set -e

[[ "$collide_rc" -ne 0 ]] || fail "supervisor watchdog should refuse colliding workdir"
[[ "$collide_out" == *"supervisor workdir collides with AGENT_PANES"* ]] || \
  fail "expected colliding workdir diagnostic, got: $collide_out"
! grep -F $'tmux\tnew-session' "$collide_log" >/dev/null \
  || fail "colliding supervisor workdir should not relaunch tmux: $(cat "$collide_log")"
collide_audit="$TEST_TMP/logs/supervisor-collide.log"
grep -F "reason=supervisor-workdir-collides" "$collide_audit" >/dev/null \
  || fail "collision audit missing reason: $(cat "$collide_audit" 2>/dev/null || true)"

healthy_pane_log="$TEST_TMP/tmux-supervisor-healthy-pane.log"
healthy_pane_config="$TEST_TMP/supervisor-healthy-pane.config.sh"
write_supervisor_config "supervisor-healthy-pane" "supervisor-healthy-" "$healthy_pane_config"

set +e
healthy_pane_out=$(run_supervisor_once \
  "$healthy_pane_config" \
  "$healthy_pane_log" \
  FAKE_TMUX_PANE_DEAD=0 \
  FAKE_TMUX_CAPTURE='codex exec --ephemeral active supervisor' \
  ORCH_NOW_OVERRIDE=1700000400 \
  2>&1)
healthy_pane_rc=$?
set -e

[[ "$healthy_pane_rc" -eq 0 ]] || fail "healthy-pane supervisor exited $healthy_pane_rc: $healthy_pane_out"
! grep -F $'tmux\tnew-window' "$healthy_pane_log" >/dev/null \
  || fail "healthy supervisor unexpectedly created a window: $(cat "$healthy_pane_log")"
! grep -F $'tmux\trespawn-pane' "$healthy_pane_log" >/dev/null \
  || fail "healthy supervisor unexpectedly respawned: $(cat "$healthy_pane_log")"
healthy_pane_audit="$TEST_TMP/logs/supervisor-healthy-pane.log"
if [[ -f "$healthy_pane_audit" ]]; then
  ! grep -F "ORCH_SUPERVISOR_RELAUNCH" "$healthy_pane_audit" >/dev/null \
    || fail "healthy supervisor unexpectedly audited relaunch: $(cat "$healthy_pane_audit")"
fi

printf 'ok - ensure_alive supervises orch_loop and orchestrator panes\n'
