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

lock_file="$TEST_TMP/ordo-validators.lock"
ran_file="$TEST_TMP/ran"

(
  exec 9>"$lock_file"
  flock 9

  set +e
  output=$(
    ORCH_VALIDATOR_SEMAPHORE_FILE="$lock_file" \
    ORCH_VALIDATOR_SEMAPHORE_WAIT_SEC=1 \
    ORCH_HOST_GATE_LOCAL_VALIDATORS_MODE=off \
    ORCH_VALIDATOR_FORK_LATENCY_MAX_MS=999999 \
    ORCH_SHELL_TESTS="$TEST_TMP/should-not-run.sh" \
      bash "$ROOT/scripts/run_shell_tests.sh" 2>&1
  )
  status=$?
  set -e

  [[ "$status" -eq 75 ]] || fail "expected semaphore timeout exit 75, got $status: $output"
  [[ "$output" == *"validators_degraded"* && "$output" == *"reason=semaphore_timeout"* ]] \
    || fail "expected validators_degraded semaphore timeout, got: $output"
)

cat > "$TEST_TMP/quick.sh" <<EOF
#!/usr/bin/env bash
printf ran > "$ran_file"
EOF
chmod +x "$TEST_TMP/quick.sh"

success_output=$(
  ORCH_VALIDATOR_SEMAPHORE_FILE="$lock_file" \
  ORCH_VALIDATOR_SEMAPHORE_WAIT_SEC=1 \
  ORCH_HOST_GATE_LOCAL_VALIDATORS_MODE=off \
  ORCH_VALIDATOR_FORK_LATENCY_MAX_MS=999999 \
  ORCH_SHELL_TESTS="$TEST_TMP/quick.sh" \
    bash "$ROOT/scripts/run_shell_tests.sh" 2>&1
)

[[ "$success_output" == *"validator_semaphore: validator=run_shell_tests"* ]] \
  || fail "expected semaphore acquisition message, got: $success_output"
[[ "$(cat "$ran_file" 2>/dev/null || true)" == "ran" ]] \
  || fail "expected quick shell test to run after semaphore was available"

fake_bats="$TEST_TMP/bats"
cat > "$fake_bats" <<EOF
#!/usr/bin/env bash
printf ran > "$ran_file.bats"
EOF
chmod +x "$fake_bats"

(
  exec 9>"$lock_file"
  flock 9

  set +e
  bats_output=$(
    ORCH_VALIDATOR_SEMAPHORE_FILE="$lock_file" \
    ORCH_VALIDATOR_SEMAPHORE_WAIT_SEC=1 \
    ORCH_HOST_GATE_LOCAL_VALIDATORS_MODE=off \
    ORCH_VALIDATOR_FORK_LATENCY_MAX_MS=999999 \
    BATS_BIN="$fake_bats" \
      bash "$ROOT/scripts/run_bats.sh" 2>&1
  )
  bats_status=$?
  set -e

  [[ "$bats_status" -eq 75 ]] || fail "expected run_bats semaphore timeout exit 75, got $bats_status: $bats_output"
  [[ "$bats_output" == *"validator=run_bats"* && "$bats_output" == *"reason=semaphore_timeout"* ]] \
    || fail "expected run_bats semaphore timeout, got: $bats_output"
)

[[ ! -f "$ran_file.bats" ]] || fail "run_bats should not execute while semaphore is unavailable"

printf 'ok - validator runners serialize through host semaphore\n'
