#!/usr/bin/env bash
# tests/test_orch_ctl_status.sh — coverage for #665 first-class portfolio
# supervisor surfacing in `orch_ctl <profile> status`.
#
# Validates:
#   - When no supervisor is registered, status emits
#     `portfolio_supervisor: not registered` and no other supervisor lines.
#   - When a supervisor registers itself (via portfolio_supervisor_register)
#     and the registered pid is alive AND its argv matches the wrapper
#     basename, status emits `portfolio_supervisor: alive (pid=<pid>)` with
#     the full metadata block (wrapper, log, model, reasoning_effort, slot,
#     paused, last_cycle elapsed annotation).
#   - When the state.json points at a dead pid, status emits
#     `portfolio_supervisor: STALE (registered pid=<pid> not alive)` rather
#     than misreporting it as alive.
#   - When the project loop is NOT RUNNING but the supervisor is alive,
#     status emits an explicit operator hint warning against double-dispatch.
#   - portfolio_supervisor_register writes atomically; partially-written
#     state never appears.
#   - portfolio_supervisor_pause/resume toggle the `paused:` line.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP=$(mktemp -d)
SANITIZED_ROOT="$TEST_TMP/toolkit"
FAKE_SUPERVISOR_PIDS=()

cleanup() {
  local pid
  for pid in "${FAKE_SUPERVISOR_PIDS[@]:-}"; do
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  rm -rf "$TEST_TMP"
}
trap cleanup EXIT

fail() {
  printf 'not ok - %s\n' "$*" >&2
  exit 1
}

mkdir -p \
  "$TEST_TMP/state/orch-ctl-test" \
  "$TEST_TMP/state/_portfolio/supervisor" \
  "$TEST_TMP/logs" \
  "$TEST_TMP/proc-empty"

# shellcheck source=../lib/test_sanitize.sh
source "$ROOT/lib/test_sanitize.sh"
sanitize_toolkit_copy "$SANITIZED_ROOT" \
  scripts/orch_ctl.sh

chmod +x "$SANITIZED_ROOT/scripts/orch_ctl.sh"

cat > "$TEST_TMP/test.config.sh" <<EOF
#!/usr/bin/env bash
PROJECT="orch-ctl-test"
GH_REPO="RBOKproject/ORDO"
GH_CONFIG_DIR="$TEST_TMP/gh"
DEFAULT_BRANCH="main"
AGENT_SESSION_PREFIX=""
AGENT_REPO_PREFIX="$TEST_TMP/repos/"
AGENT_WORKDIR_TEMPLATE="$TEST_TMP/repos/%s"
AGENTS=(claude)
EOF

# Stubbed gh: config_resolver does not balk on absent gh.
mkdir -p "$TEST_TMP/bin"
cat > "$TEST_TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$TEST_TMP/bin/gh"

# Plant a deterministic project-loop state so the elapsed annotation does not
# depend on wall-clock slippage between file writes and the status read.
fixed_now=2000000000
echo $((fixed_now - 90)) > "$TEST_TMP/state/orch-ctl-test/orch.last_activity"
echo 7 > "$TEST_TMP/state/orch-ctl-test/orch.cycle_count"

run_status() {
  PATH="$TEST_TMP/bin:$PATH" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  ORCH_PROC_DIR="$TEST_TMP/proc-empty" \
  ORCH_NOW_OVERRIDE="$fixed_now" \
  TK="$SANITIZED_ROOT" \
  bash "$SANITIZED_ROOT/scripts/orch_ctl.sh" "$TEST_TMP/test.config.sh" status 2>&1
}

# --- T1: no supervisor registered -----------------------------------------
set +e
out=$(run_status)
rc=$?
set -e
[[ $rc -eq 0 ]] || fail "T1: orch_ctl status exited $rc: $out"
[[ "$out" == *"portfolio_supervisor: not registered"* ]] || \
  fail "T1: expected 'not registered' when state.json absent, got: $out"
[[ "$out" != *"alive (pid="* ]] || \
  fail "T1: must not report alive when nothing registered, got: $out"
[[ "$out" != *"STALE"* ]] || \
  fail "T1: must not report STALE when nothing registered, got: $out"

# --- Helpers: spawn a long-lived fake supervisor that exposes the wrapper
#     basename in argv[0] so portfolio_supervisor_pid_matches accepts it. ---
fake_wrapper="$TEST_TMP/ordo-full-loop.sh"
cat > "$fake_wrapper" <<'EOF'
#!/usr/bin/env bash
while :; do sleep 1; done
EOF
chmod +x "$fake_wrapper"

start_fake_supervisor() {
  # Redirect stdio to /dev/null so the background pid does not keep this
  # function's command-substitution pipe open. Without it, $(start_fake_supervisor)
  # blocks until the fake wrapper exits, which never happens inside the test.
  "$fake_wrapper" </dev/null >/dev/null 2>&1 &
  FAKE_SUPERVISOR_PIDS+=("$!")
  printf '%s' "$!"
}

# Source the helper to use register/heartbeat/pause directly. We test the
# library through its public surface, not by hand-writing JSON.
ORCH_STATE_BASE="$TEST_TMP/state" \
  source "$SANITIZED_ROOT/lib/portfolio_supervisor.sh"

# --- T2: registered + alive --> full metadata block -----------------------
sup_pid=$(start_fake_supervisor)
ORCH_STATE_BASE="$TEST_TMP/state" portfolio_supervisor_register \
  --wrapper "$fake_wrapper" \
  --log "$TEST_TMP/logs/ordo-full-portfolio-loop.log" \
  --model "claude-opus-4-7" \
  --reasoning-effort "high" \
  --slot "fleet-000" \
  --pid "$sup_pid"

ORCH_STATE_BASE="$TEST_TMP/state" portfolio_supervisor_heartbeat $((fixed_now - 30))

state_path="$TEST_TMP/state/_portfolio/supervisor/state.json"
[[ -s "$state_path" ]] || fail "T2: register must produce state.json at $state_path"
[[ ! -e "$state_path.tmp.$$" ]] || fail "T2: atomic write must remove .tmp file"

# `ORCH_PROC_DIR=/proc` for this run so the real fake pid resolves.
out=$(
  PATH="$TEST_TMP/bin:$PATH" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  ORCH_PROC_DIR=/proc \
  ORCH_NOW_OVERRIDE="$fixed_now" \
  TK="$SANITIZED_ROOT" \
  bash "$SANITIZED_ROOT/scripts/orch_ctl.sh" "$TEST_TMP/test.config.sh" status 2>&1
)

[[ "$out" == *"portfolio_supervisor: alive (pid=$sup_pid)"* ]] || \
  fail "T2: expected alive (pid=$sup_pid) header, got: $out"
[[ "$out" == *"wrapper:           $fake_wrapper"* ]] || \
  fail "T2: wrapper line missing, got: $out"
[[ "$out" == *"log:               $TEST_TMP/logs/ordo-full-portfolio-loop.log"* ]] || \
  fail "T2: log line missing, got: $out"
[[ "$out" == *"model:             claude-opus-4-7"* ]] || \
  fail "T2: model line missing, got: $out"
[[ "$out" == *"reasoning_effort:  high"* ]] || \
  fail "T2: reasoning_effort line missing, got: $out"
[[ "$out" == *"slot:              fleet-000"* ]] || \
  fail "T2: slot line missing, got: $out"
[[ "$out" == *"paused:            false"* ]] || \
  fail "T2: paused=false line missing, got: $out"
[[ "$out" == *"last_cycle:        "*"30s ago"* ]] || \
  fail "T2: expected '30s ago' annotation on last_cycle, got: $out"

# The project loop reports NOT RUNNING (empty fake proc dir for that read);
# but the supervisor scan uses ORCH_PROC_DIR=/proc above. The status command
# is one invocation with ORCH_PROC_DIR=/proc, so the project loop scan also
# runs against the real /proc — that is fine because no real orch_loop.sh
# process matches PROJECT=orch-ctl-test in this test host. So the hint MUST
# fire here.
[[ "$out" == *"note: project loop is NOT RUNNING but the portfolio supervisor is alive"* ]] || \
  fail "T2: expected double-dispatch hint when project loop is down + supervisor alive, got: $out"

# --- T3: paused toggle ----------------------------------------------------
ORCH_STATE_BASE="$TEST_TMP/state" portfolio_supervisor_pause
out=$(
  PATH="$TEST_TMP/bin:$PATH" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  ORCH_PROC_DIR=/proc \
  ORCH_NOW_OVERRIDE="$fixed_now" \
  TK="$SANITIZED_ROOT" \
  bash "$SANITIZED_ROOT/scripts/orch_ctl.sh" "$TEST_TMP/test.config.sh" status 2>&1
)
[[ "$out" == *"paused:            true"* ]] || \
  fail "T3: paused=true line missing after portfolio_supervisor_pause, got: $out"

ORCH_STATE_BASE="$TEST_TMP/state" portfolio_supervisor_resume
out=$(
  PATH="$TEST_TMP/bin:$PATH" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  ORCH_PROC_DIR=/proc \
  ORCH_NOW_OVERRIDE="$fixed_now" \
  TK="$SANITIZED_ROOT" \
  bash "$SANITIZED_ROOT/scripts/orch_ctl.sh" "$TEST_TMP/test.config.sh" status 2>&1
)
[[ "$out" == *"paused:            false"* ]] || \
  fail "T3: paused=false line missing after portfolio_supervisor_resume, got: $out"

# --- T4: stale pid (process killed, state.json left behind) ---------------
# Kill the fake supervisor, leave state.json on disk. Status must report
# STALE rather than alive.
kill "$sup_pid" 2>/dev/null || true
wait "$sup_pid" 2>/dev/null || true
# Wait for /proc/<pid>/cmdline to actually disappear.
deadline=$((SECONDS + 5))
while (( SECONDS < deadline )); do
  [[ ! -r "/proc/$sup_pid/cmdline" ]] && break
  sleep 0.05
done
[[ ! -r "/proc/$sup_pid/cmdline" ]] || fail "T4: fake supervisor pid $sup_pid did not exit"

out=$(
  PATH="$TEST_TMP/bin:$PATH" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  ORCH_PROC_DIR=/proc \
  ORCH_NOW_OVERRIDE="$fixed_now" \
  TK="$SANITIZED_ROOT" \
  bash "$SANITIZED_ROOT/scripts/orch_ctl.sh" "$TEST_TMP/test.config.sh" status 2>&1
)
[[ "$out" == *"portfolio_supervisor: STALE (registered pid=$sup_pid not alive)"* ]] || \
  fail "T4: expected STALE header for dead pid $sup_pid, got: $out"
[[ "$out" != *"alive (pid="* ]] || \
  fail "T4: must not also report alive, got: $out"

# --- T5: unregister --> back to 'not registered' ---------------------------
ORCH_STATE_BASE="$TEST_TMP/state" portfolio_supervisor_unregister
out=$(run_status)
[[ "$out" == *"portfolio_supervisor: not registered"* ]] || \
  fail "T5: unregister must reset surface to 'not registered', got: $out"
[[ ! -e "$state_path" ]] || fail "T5: unregister must remove state.json"

# --- T6: register-with-special-characters --> JSON escape is honored ------
nasty_wrapper="$TEST_TMP/quoted \"wrapper\".sh"
cp "$fake_wrapper" "$nasty_wrapper"
ORCH_STATE_BASE="$TEST_TMP/state" portfolio_supervisor_register \
  --wrapper "$nasty_wrapper" \
  --log "$TEST_TMP/logs/with-quote\"in-it.log" \
  --model "model-with-quote\"X" \
  --reasoning-effort "" \
  --slot "fleet-000" \
  --pid "$$"

field=$(ORCH_STATE_BASE="$TEST_TMP/state" portfolio_supervisor_state_field wrapper)
[[ "$field" == "$nasty_wrapper" ]] || \
  fail "T6: round-trip of quoted wrapper failed (got: '$field' want: '$nasty_wrapper')"
field=$(ORCH_STATE_BASE="$TEST_TMP/state" portfolio_supervisor_state_field log)
[[ "$field" == "$TEST_TMP/logs/with-quote\"in-it.log" ]] || \
  fail "T6: round-trip of quoted log failed (got: '$field')"

ORCH_STATE_BASE="$TEST_TMP/state" portfolio_supervisor_unregister

printf 'ok - orch_ctl status surfaces the portfolio supervisor as first-class\n'
