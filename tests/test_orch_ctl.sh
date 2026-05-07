#!/usr/bin/env bash
# tests/test_orch_ctl.sh — coverage for #126 status reliability fixes.
#
# Validates:
#   - find_loop_pids exact argv matching (F-002): only argv pairs of the form
#     [..., orch_loop.sh, <project>, ...] count as alive; substring matches
#     and self PID are excluded.
#   - format_last_activity elapsed annotation (F-005): renders Xs / Xm Ys /
#     Xh Ym / Xd Yh ago instead of the raw epoch and emits "never" for 0.
#   - end-to-end `orch_ctl.sh status` shows "NOT RUNNING" with empty fake /proc.
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

mkdir -p \
  "$SANITIZED_ROOT/scripts" \
  "$SANITIZED_ROOT/lib" \
  "$TEST_TMP/proc" \
  "$TEST_TMP/state/orch-ctl-test" \
  "$TEST_TMP/logs"

for rel in \
  scripts/orch_ctl.sh \
  lib/audit_log.sh \
  lib/config_check.sh \
  lib/config_resolver.sh \
  lib/process_safety.sh
do
  tr -d '\r' < "$ROOT/$rel" > "$SANITIZED_ROOT/$rel"
done
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

# Helper: write a synthetic /proc/<pid>/cmdline with NUL-separated argv.
write_cmdline() {
  local pid=$1; shift
  mkdir -p "$TEST_TMP/proc/$pid"
  local out="$TEST_TMP/proc/$pid/cmdline"
  : > "$out"
  local arg
  for arg in "$@"; do
    printf '%s\0' "$arg" >> "$out"
  done
}

# --- F-002 unit checks via direct function call ----------------------------
# Source orch_ctl.sh in dry-run shape: the script needs PROJECT_ARG/CMD to
# parse argv, but we want to source only the helper definitions. Re-exec
# the script through a tiny wrapper that aborts immediately after the
# function definitions but keeps them in the caller's scope.

# Extract just the function definitions block we want to unit-test by
# sourcing orch_ctl.sh after stripping its body. We do this by copying it
# to a temp file and running our assertions in a subshell that injects
# the helpers + the surrounding env.

# Build a sourced copy that exposes find_loop_pids / format_last_activity
# without entering the main case dispatch. Source it in *this* shell so the
# self-PID exclusion is anchored to the test runner's own $$.
HELPERS_SH="$TEST_TMP/orch_ctl_helpers.sh"
awk '
  /^find_loop_pids\(\) \{/        { in_fn = 1 }
  /^format_last_activity\(\) \{/  { in_fn = 1 }
  in_fn { print }
  in_fn && /^\}$/                 { in_fn = 0 }
' "$SANITIZED_ROOT/scripts/orch_ctl.sh" > "$HELPERS_SH"

[[ -s "$HELPERS_SH" ]] || fail "failed to extract helper functions from orch_ctl.sh"
# shellcheck disable=SC1090
source "$HELPERS_SH"

# Build the synthetic /proc layout.
self_pid=$$
fake_pids=(1001 1002 1003 1004 1006)
for fp in "${fake_pids[@]}"; do
  [[ "$self_pid" == "$fp" ]] && fail "self_pid=$self_pid collides with fake test PID $fp; rerun"
done

# 1. Real loop process — should match.
write_cmdline 1001 "bash" "/root/repos/ORDO-orchestrator/scripts/orch_loop.sh" "orch-ctl-test"

# 2. Wrong project — must NOT match.
write_cmdline 1002 "bash" "/root/repos/ORDO-orchestrator/scripts/orch_loop.sh" "other-project"

# 3. Substring-only match — argv contains "orch_loop.sh" inside a single
#    longer arg; must NOT match because basename comparison is exact.
write_cmdline 1003 "bash" "-c" "echo orch_loop.sh orch-ctl-test"

# 4. Pgrep transient — argv looks like the old false-positive offender:
#    a pgrep command line that contains the literal pattern as ONE arg.
write_cmdline 1004 "pgrep" "-af" "orch_loop.sh orch-ctl-test"

# 5. Self PID — must always be excluded even if argv would otherwise match.
write_cmdline "$self_pid" "bash" "/scripts/orch_loop.sh" "orch-ctl-test"

# 6. Bare invocation (./orch_loop.sh project) — should match (basename rule).
write_cmdline 1006 "./orch_loop.sh" "orch-ctl-test"

set +e
out=$(ORCH_PROC_DIR="$TEST_TMP/proc" find_loop_pids orch-ctl-test)
set -e

[[ "$out" == *"1001"* ]] || fail "find_loop_pids should return PID 1001 for the real loop, got: $out"
[[ "$out" == *"1006"* ]] || fail "find_loop_pids should match bare ./orch_loop.sh invocation (PID 1006), got: $out"
[[ "$out" != *"1002"* ]] || fail "find_loop_pids must reject mismatched project (PID 1002), got: $out"
[[ "$out" != *"1003"* ]] || fail "find_loop_pids must reject substring-only matches (PID 1003), got: $out"
[[ "$out" != *"1004"* ]] || fail "find_loop_pids must reject pgrep transients (PID 1004), got: $out"
[[ "$out" != *"$self_pid"* ]] || fail "find_loop_pids must exclude its own caller PID ($self_pid), got: $out"

# --- F-005 unit checks ------------------------------------------------------
fixed_now=2000000000
declare -A elapsed_cases=(
  ["0"]="never"
  ["${fixed_now}"]="0s ago"
  ["$((fixed_now - 5))"]="5s ago"
  ["$((fixed_now - 130))"]="2m 10s ago"
  ["$((fixed_now - 4000))"]="1h 6m ago"
  ["$((fixed_now - 200000))"]="2d 7h ago"
)

for ts in "${!elapsed_cases[@]}"; do
  expected=${elapsed_cases[$ts]}
  set +e
  rendered=$(ORCH_NOW_OVERRIDE="$fixed_now" format_last_activity "$ts")
  rc=$?
  set -e
  [[ $rc -eq 0 ]] || fail "format_last_activity exit=$rc for ts=$ts"
  if [[ "$ts" == "0" ]]; then
    [[ "$rendered" == "never" ]] || fail "ts=0 should render 'never', got: $rendered"
  else
    [[ "$rendered" == *"$expected"* ]] || fail "ts=$ts should contain '$expected', got: $rendered"
    # Regression guard for the original bug: the literal epoch must not leak
    # into the elapsed annotation.
    [[ "$rendered" != *"$ts ago"* ]] || fail "ts=$ts must not render the raw epoch as elapsed: $rendered"
  fi
done

# Future timestamps are clamped to a stable label rather than negative seconds.
set +e
future=$(ORCH_NOW_OVERRIDE="$fixed_now" format_last_activity "$((fixed_now + 10))")
set -e
[[ "$future" == *"in the future"* ]] || fail "future ts should render 'in the future', got: $future"

# --- end-to-end smoke: orch_ctl.sh status with empty fake /proc ------------
# Provide a no-op gh shell so config_resolver does not balk on absent gh.
mkdir -p "$TEST_TMP/bin"
cat > "$TEST_TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$TEST_TMP/bin/gh"

# Empty proc dir => status must report NOT RUNNING and never spawn alive PIDs.
empty_proc="$TEST_TMP/proc-empty"
mkdir -p "$empty_proc"

# Plant a known last_activity 90 seconds before a fixed override "now" so the
# rendered elapsed annotation is deterministic regardless of test wall-clock
# slippage between writing the state file and orch_ctl reading it.
status_now=$fixed_now
status_last_act=$((status_now - 90))
echo "$status_last_act" > "$TEST_TMP/state/orch-ctl-test/orch.last_activity"
echo 7 > "$TEST_TMP/state/orch-ctl-test/orch.cycle_count"

set +e
status_out=$(
  PATH="$TEST_TMP/bin:$PATH" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  ORCH_PROC_DIR="$empty_proc" \
  ORCH_NOW_OVERRIDE="$status_now" \
  TK="$SANITIZED_ROOT" \
  bash "$SANITIZED_ROOT/scripts/orch_ctl.sh" "$TEST_TMP/test.config.sh" status 2>&1
)
status_rc=$?
set -e

[[ "$status_rc" -eq 0 ]] || fail "orch_ctl status exited $status_rc: $status_out"
[[ "$status_out" == *"loop:           NOT RUNNING"* ]] || \
  fail "expected NOT RUNNING with empty proc, got: $status_out"
[[ "$status_out" == *"cycles_run:     7"* ]] || \
  fail "expected cycles_run=7, got: $status_out"
[[ "$status_out" == *"1m 30s ago"* ]] || \
  fail "expected '1m 30s ago' annotation in status, got: $status_out"
# Regression guard against the F-005 bug pattern.
[[ "$status_out" != *"$status_last_act ago"* ]] || \
  fail "status leaked raw epoch as elapsed: $status_out"

printf 'ok - orch_ctl status uses exact loop matching and elapsed-time rendering\n'
