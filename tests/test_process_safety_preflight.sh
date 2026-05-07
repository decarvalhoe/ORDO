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

default_output=$(env -u BASH_ENV \
  PROC_SAFETY_RUNAWAY_MIN_ETIME_SEC=999999 \
  PROC_SAFETY_RUNAWAY_MIN_PCPU=999 \
  PROC_SAFETY_PS_TIMEOUT_SEC=1 \
  timeout 20 bash "$ROOT/scripts/process_safety_preflight.sh" 2>&1)
[[ "$default_output" != *"awk: warning"* ]] \
  || fail "default process scan should not emit awk warnings, got: $default_output"

write_task_output_fixture() {
  local path=${1:?usage: write_task_output_fixture <path>}
  cat > "$path" <<'EOF'
Bash(timeout 300 bash tests/test_example.sh)
Task Output task-abc123
Re-run focused validator with a bounded timeout
   Waiting for task (esc to give additional instructions)
EOF
}

write_monitor_fixture() {
  local path=${1:?usage: write_monitor_fixture <path>}
  cat > "$path" <<'EOF'
Bash(timeout 300 bash tests/test_example.sh > /tmp/generic-validator.out 2>&1 &)
Monitor(Watch focused validator progress)
  Interrupted - What should the agent do instead?
EOF
}

write_polling_fixture() {
  local path=${1:?usage: write_polling_fixture <path>}
  cat > "$path" <<'EOF'
Bash(until grep -qE "RC=" /tmp/generic/tasks/check.output 2>/dev/null; do
  sleep 30
done; cat /tmp/generic/tasks/check.output)
  Running... (3m 58s timeout 10m)
EOF
}

run_preflight_capture_dir() {
  local capture_dir=${1:?usage: run_preflight_capture_dir <capture-dir> <state-dir> [args...]}
  local state_dir=${2:?usage: run_preflight_capture_dir <capture-dir> <state-dir> [args...]}
  shift 2
  env -u BASH_ENV \
    PROC_SAFETY_STUCK_WAIT_CAPTURE_DIR="$capture_dir" \
    PROC_SAFETY_STUCK_WAIT_STATE_DIR="$state_dir" \
    PROC_SAFETY_RUNAWAY_MIN_ETIME_SEC=999999 \
    PROC_SAFETY_RUNAWAY_MIN_PCPU=999 \
    PROC_SAFETY_PS_TIMEOUT_SEC=1 \
    timeout 20 bash "$ROOT/scripts/process_safety_preflight.sh" \
      --detect-stuck-task-output "$@"
}

task_dir="$TEST_TMP/task-captures"
task_state="$TEST_TMP/task-state"
mkdir -p "$task_dir" "$task_state"
write_task_output_fixture "$task_dir/pane.task"

first_output=$(PROC_SAFETY_STUCK_WAIT_MIN_HITS=2 run_preflight_capture_dir "$task_dir" "$task_state" 2>&1)
[[ "$first_output" == *"stuck wait observations below threshold"* ]] \
  || fail "expected first task-output observation below threshold, got: $first_output"
[[ "$first_output" == *"task_output_waiting"* ]] \
  || fail "expected task_output_waiting variant, got: $first_output"

set +e
second_output=$(PROC_SAFETY_STUCK_WAIT_MIN_HITS=2 \
  run_preflight_capture_dir "$task_dir" "$task_state" --refuse 2>&1)
second_status=$?
set -e
[[ "$second_status" -eq 7 ]] \
  || fail "expected second task-output observation to refuse with 7, got $second_status: $second_output"
[[ "$second_output" == *"stuck wait candidates found"* ]] \
  || fail "expected stuck wait candidate on repeated task-output capture, got: $second_output"
[[ "$second_output" == *"pane.task"* && "$second_output" == *"task_output_waiting"* ]] \
  || fail "expected pane.task task_output_waiting candidate, got: $second_output"

variant_dir="$TEST_TMP/variant-captures"
variant_state="$TEST_TMP/variant-state"
mkdir -p "$variant_dir" "$variant_state"
write_monitor_fixture "$variant_dir/pane.monitor"
write_polling_fixture "$variant_dir/pane.poll"

variant_output=$(PROC_SAFETY_STUCK_WAIT_MIN_HITS=1 \
  run_preflight_capture_dir "$variant_dir" "$variant_state" 2>&1)
[[ "$variant_output" == *"monitor_interrupted_waiting"* ]] \
  || fail "expected monitor_interrupted_waiting variant, got: $variant_output"
[[ "$variant_output" == *"polling_without_progress"* ]] \
  || fail "expected polling_without_progress variant, got: $variant_output"

quiet_dir="$TEST_TMP/quiet-captures"
quiet_state="$TEST_TMP/quiet-state"
mkdir -p "$quiet_dir" "$quiet_state"
cat > "$quiet_dir/pane.quiet" <<'EOF'
Bash(timeout 60 bash tests/test_example.sh)
  exit=0
EOF

quiet_output=$(PROC_SAFETY_STUCK_WAIT_MIN_HITS=1 \
  run_preflight_capture_dir "$quiet_dir" "$quiet_state" 2>&1)
[[ "$quiet_output" != *"stuck wait candidates found"* ]] \
  || fail "did not expect stuck wait candidate for quiet pane, got: $quiet_output"
[[ "$quiet_output" != *"task_output_waiting"* \
  && "$quiet_output" != *"monitor_interrupted_waiting"* \
  && "$quiet_output" != *"polling_without_progress"* ]] \
  || fail "did not expect stuck wait variants for quiet pane, got: $quiet_output"

nudge_dir="$TEST_TMP/nudge-captures"
nudge_state="$TEST_TMP/nudge-state"
fake_bin="$TEST_TMP/bin"
tmux_log="$TEST_TMP/tmux.log"
mkdir -p "$nudge_dir" "$nudge_state" "$fake_bin"
write_task_output_fixture "$nudge_dir/pane.nudge"
cat > "$fake_bin/tmux" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TMUX_LOG"
EOF
chmod +x "$fake_bin/tmux"

nudge_output=$(env -u BASH_ENV \
  PATH="$fake_bin:$PATH" \
  TMUX_LOG="$tmux_log" \
  PROC_SAFETY_STUCK_WAIT_MIN_HITS=1 \
  PROC_SAFETY_STUCK_WAIT_CAPTURE_DIR="$nudge_dir" \
  PROC_SAFETY_STUCK_WAIT_STATE_DIR="$nudge_state" \
  PROC_SAFETY_RUNAWAY_MIN_ETIME_SEC=999999 \
  PROC_SAFETY_RUNAWAY_MIN_PCPU=999 \
  PROC_SAFETY_PS_TIMEOUT_SEC=1 \
  timeout 20 bash "$ROOT/scripts/process_safety_preflight.sh" \
    --detect-stuck-task-output --nudge 2>&1)
[[ "$nudge_output" == *"nudged"* ]] \
  || fail "expected nudged action, got: $nudge_output"
mapfile -t tmux_calls < "$tmux_log"
[[ "${#tmux_calls[@]}" -eq 3 ]] \
  || fail "expected exactly 3 fake tmux calls, got ${#tmux_calls[@]}: $(cat "$tmux_log")"
[[ "${tmux_calls[0]}" == "send-keys -t pane.nudge Escape" ]] \
  || fail "expected Escape nudge first, got: ${tmux_calls[0]}"
[[ "${tmux_calls[1]}" == send-keys\ -t\ pane.nudge\ validator-hang:* ]] \
  || fail "expected text-only validator-hang nudge second, got: ${tmux_calls[1]}"
[[ "${tmux_calls[1]}" != *" Enter" ]] \
  || fail "expected nudge text without Enter in same call, got: ${tmux_calls[1]}"
[[ "${tmux_calls[2]}" == "send-keys -t pane.nudge Enter" ]] \
  || fail "expected separate Enter nudge third, got: ${tmux_calls[2]}"

forensics_ps="$TEST_TMP/forensics.ps"
wildcard='*'
printf '4242 1 3600 97.0 journalctl --user-unit %s -u demo.service --no-pager --since 2026-01-01T00:00:00Z\n' \
  "$wildcard" > "$forensics_ps"

set +e
forensics_output=$(env -u BASH_ENV \
  PROC_SAFETY_PS_FILE="$forensics_ps" \
  PROC_SAFETY_RUNAWAY_MIN_ETIME_SEC=900 \
  PROC_SAFETY_RUNAWAY_MIN_PCPU=80 \
  PROC_SAFETY_PS_TIMEOUT_SEC=1 \
    timeout 20 bash "$ROOT/scripts/process_safety_preflight.sh" --refuse 2>&1)
forensics_status=$?
set -e
[[ "$forensics_status" -eq 7 ]] \
  || fail "expected forensic runaway to refuse with 7, got $forensics_status: $forensics_output"
[[ "$forensics_output" == *"host_forensics_degraded: runaway forensic probe candidates found"* ]] \
  || fail "expected explicit host_forensics_degraded output, got: $forensics_output"
[[ "$forensics_output" == *$'host_forensics_degraded\t4242'* ]] \
  || fail "expected forensic signal in offender table, got: $forensics_output"

printf 'ok - process_safety_preflight detects and nudges stuck validator waits\n'
