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

hang_test="$TEST_TMP/hang.sh"
cat > "$hang_test" <<'EOF'
#!/usr/bin/env bash
sleep 10
EOF
chmod +x "$hang_test"

set +e
output=$(
  ORCH_HOST_GATE_LOCAL_VALIDATORS_MODE=off \
  ORCH_VALIDATOR_FORK_LATENCY_MAX_MS=999999 \
  ORCH_SHELL_TEST_TIMEOUT_SEC=1 \
  ORCH_SHELL_TESTS="$hang_test" \
  bash "$ROOT/scripts/run_shell_tests.sh" 2>&1
)
status=$?
set -e

[[ "$status" -eq 124 ]] || fail "expected timeout exit 124, got $status: $output"
[[ "$output" == *"run_shell_tests: $hang_test"* ]] || \
  fail "expected culprit test to be printed, got: $output"
[[ "$output" == *"timed out after 1s: $hang_test"* ]] || \
  fail "expected timeout diagnostic, got: $output"

printf 'ok - run_shell_tests reports timed-out test culprit\n'

# Per-test timeout marker (#806 follow-up): a test may raise its own ceiling
# above the global ORCH_SHELL_TEST_TIMEOUT_SEC with a header comment.
marker_test="$TEST_TMP/marker.sh"
cat > "$marker_test" <<'EOF'
#!/usr/bin/env bash
# orch-shell-test-timeout-sec: 5
sleep 2
printf 'ok - marker test finished\n'
EOF
chmod +x "$marker_test"

set +e
output=$(
  ORCH_HOST_GATE_LOCAL_VALIDATORS_MODE=off \
  ORCH_VALIDATOR_FORK_LATENCY_MAX_MS=999999 \
  ORCH_SHELL_TEST_TIMEOUT_SEC=1 \
  ORCH_SHELL_TESTS="$marker_test" \
  bash "$ROOT/scripts/run_shell_tests.sh" 2>&1
)
status=$?
set -e

[[ "$status" -eq 0 ]] || fail "expected marker test to pass under its own 5s ceiling, got $status: $output"
[[ "$output" == *"ok - marker test finished"* ]] || \
  fail "expected marker test output, got: $output"

# An invalid marker falls back to the global ceiling.
bad_marker_test="$TEST_TMP/bad-marker.sh"
cat > "$bad_marker_test" <<'EOF'
#!/usr/bin/env bash
# orch-shell-test-timeout-sec: 99999
sleep 3
EOF
chmod +x "$bad_marker_test"

set +e
output=$(
  ORCH_HOST_GATE_LOCAL_VALIDATORS_MODE=off \
  ORCH_VALIDATOR_FORK_LATENCY_MAX_MS=999999 \
  ORCH_SHELL_TEST_TIMEOUT_SEC=1 \
  ORCH_SHELL_TESTS="$bad_marker_test" \
  bash "$ROOT/scripts/run_shell_tests.sh" 2>&1
)
status=$?
set -e

[[ "$status" -eq 124 ]] || fail "expected invalid marker to fall back to the 1s ceiling, got $status: $output"
[[ "$output" == *"timed out after 1s: $bad_marker_test"* ]] || \
  fail "expected fallback timeout diagnostic, got: $output"

printf 'ok - run_shell_tests honours a valid per-test timeout marker and ignores an invalid one\n'
