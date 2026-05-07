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

pass_load="$TEST_TMP/pass.loadavg"
pass_df="$TEST_TMP/pass.df"
pass_ps="$TEST_TMP/pass.ps"
fail_load="$TEST_TMP/fail.loadavg"
fail_df="$TEST_TMP/fail.df"
fail_ps="$TEST_TMP/fail.ps"
audit_log="$TEST_TMP/audit.log"

printf '0.25 0.20 0.10 1/100 123\n' > "$pass_load"
cat > "$pass_df" <<'EOF'
Filesystem     1024-blocks Used Available Capacity Mounted on
/dev/root              1000  200       800      20% /
EOF
cat > "$pass_ps" <<'EOF'
101 1 10 0.0 bash ordinary_worker
EOF

printf '9.50 8.00 7.00 1/100 456\n' > "$fail_load"
cat > "$fail_df" <<'EOF'
Filesystem     1024-blocks Used Available Capacity Mounted on
/dev/root              1000  950        50      95% /
EOF
cat > "$fail_ps" <<'EOF'
202 1 3600 3.0 bash backup_worker --fixture
EOF

set +e
pass_output=$(
  ORCH_HOST_LOAD_GATE=1 \
  ORCH_HOST_GATE_LOADAVG_FILE="$pass_load" \
  ORCH_HOST_GATE_CPU_COUNT=4 \
  ORCH_HOST_GATE_LOAD_PER_CPU_MAX=1 \
  ORCH_HOST_GATE_FORK_LATENCY_MS=10 \
  ORCH_HOST_GATE_FORK_LATENCY_MAX_MS=500 \
  ORCH_HOST_GATE_DF_FILE="$pass_df" \
  ORCH_HOST_GATE_DISK_USED_MAX_PCT=90 \
  ORCH_HOST_GATE_PS_FILE="$pass_ps" \
  ORCH_HOST_GATE_PROCESS_MARKER_RE='backup_worker' \
  bash "$ROOT/scripts/host_load_gate.sh" --context fixture-pass --mode refuse 2>&1
)
pass_status=$?
set -e
[[ "$pass_status" -eq 0 ]] || fail "expected pass fixture to succeed, got $pass_status: $pass_output"
[[ "$pass_output" != *"host_degraded"* ]] || fail "pass fixture should not degrade: $pass_output"

set +e
fail_output=$(
  ORCH_HOST_LOAD_GATE=1 \
  ORCH_HOST_GATE_LOADAVG_FILE="$fail_load" \
  ORCH_HOST_GATE_CPU_COUNT=2 \
  ORCH_HOST_GATE_LOAD_PER_CPU_MAX=2 \
  ORCH_HOST_GATE_FORK_LATENCY_MS=800 \
  ORCH_HOST_GATE_FORK_LATENCY_MAX_MS=500 \
  ORCH_HOST_GATE_DF_FILE="$fail_df" \
  ORCH_HOST_GATE_DISK_USED_MAX_PCT=90 \
  ORCH_HOST_GATE_PS_FILE="$fail_ps" \
  ORCH_HOST_GATE_PROCESS_MARKER_RE='backup_worker' \
  bash "$ROOT/scripts/host_load_gate.sh" --context fixture-fail --mode refuse 2>&1
)
fail_status=$?
set -e
[[ "$fail_status" -eq 75 ]] || fail "expected fail fixture to exit 75, got $fail_status: $fail_output"
[[ "$fail_output" == *"host_degraded"* ]] || fail "missing host_degraded output: $fail_output"
[[ "$fail_output" == *"load_average:"* ]] || fail "missing load reason: $fail_output"
[[ "$fail_output" == *"fork_latency:"* ]] || fail "missing fork reason: $fail_output"
[[ "$fail_output" == *"disk_pressure:"* ]] || fail "missing disk reason: $fail_output"
[[ "$fail_output" == *"process_marker:"* ]] || fail "missing process marker reason: $fail_output"

set +e
override_output=$(
  ORCH_HOST_LOAD_GATE=1 \
  ORCH_HOST_GATE_LOADAVG_FILE="$fail_load" \
  ORCH_HOST_GATE_CPU_COUNT=2 \
  ORCH_HOST_GATE_LOAD_PER_CPU_MAX=2 \
  ORCH_HOST_GATE_FORK_LATENCY_MS=800 \
  ORCH_HOST_GATE_FORK_LATENCY_MAX_MS=500 \
  ORCH_HOST_GATE_DF_FILE="$fail_df" \
  ORCH_HOST_GATE_DISK_USED_MAX_PCT=90 \
  ORCH_HOST_GATE_PS_FILE="$fail_ps" \
  ORCH_HOST_GATE_PROCESS_MARKER_RE='backup_worker' \
  ORCH_HOST_GATE_OVERRIDE=1 \
  ORCH_HOST_GATE_OVERRIDE_REASON='fixture override' \
  bash -c '
    set -euo pipefail
    # shellcheck source=/dev/null
    source "$1/lib/host_load_gate.sh"
    audit_file=$2
    audit() { printf "%s\n" "$*" >> "$audit_file"; }
    orch_host_load_gate "fixture-override" refuse
  ' bash "$ROOT" "$audit_log" 2>&1
)
override_status=$?
set -e
[[ "$override_status" -eq 0 ]] || fail "expected override fixture to pass, got $override_status: $override_output"
[[ "$override_output" == *"action=override"* ]] || fail "override output should be explicit: $override_output"
grep -q 'HOST_GATE override context=fixture-override' "$audit_log" \
  || fail "override should be audit logged"
grep -q 'override_reason=fixture_override' "$audit_log" \
  || fail "override audit should include sanitized reason"

printf 'ok - host load gate covers pass, fail, and override fixtures\n'
