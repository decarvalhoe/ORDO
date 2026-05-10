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
  scripts/ensure_alive.sh

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
  *)
    printf 'unexpected tmux command: %s\n' "$*" >&2
    exit 99
    ;;
esac
EOF
chmod +x "$TEST_TMP/bin/tmux"

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
    PATH="$TEST_TMP/bin:$PATH" \
    ORCH_LOG_DIR="$TEST_TMP/logs" \
    ORCH_STATE_BASE="$TEST_TMP/state" \
    TK="$SANITIZED_ROOT" \
    FAKE_TMUX_LOG="$log" \
    "$@" \
    bash "$SANITIZED_ROOT/scripts/ensure_alive.sh" orch-loop "$config" --once
}

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

printf 'ok - ensure_alive respawns dead orch_loop service panes with open-loop guard\n'
