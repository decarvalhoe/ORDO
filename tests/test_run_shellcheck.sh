#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNNER="$ROOT/scripts/run_shellcheck.sh"
TEST_TMP=$(mktemp -d)

fail() {
  printf 'not ok - %s\n' "$*" >&2
  exit 1
}

cleanup() {
  rm -rf "$TEST_TMP"
}
trap cleanup EXIT

[[ -f "$RUNNER" ]] || fail "expected $RUNNER to exist"

fake_bin="$TEST_TMP/bin"
args_log="$TEST_TMP/shellcheck.args"
mkdir -p "$fake_bin"

cat > "$fake_bin/shellcheck" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

: "${SHELLCHECK_ARGS_LOG:?missing SHELLCHECK_ARGS_LOG}"
printf '%s\n' "$@" > "$SHELLCHECK_ARGS_LOG"
EOF
chmod +x "$fake_bin/shellcheck"

run_status=0
run_output=$(
  ORCH_HOST_GATE_LOCAL_VALIDATORS_MODE=off \
  ORCH_VALIDATOR_FORK_LATENCY_MAX_MS=999999 \
  ORCH_SHELLCHECK_PATHS="scripts/run_shellcheck.sh" \
  PATH="$fake_bin:$PATH" \
  SHELLCHECK_ARGS_LOG="$args_log" \
  timeout 10 bash "$RUNNER" 2>&1
) || run_status=$?

[[ "$run_status" -eq 0 ]] || \
  fail "expected bounded run_shellcheck smoke to pass, got $run_status: $run_output"

mapfile -t args < "$args_log"
expected=(-e "SC1090,SC1091" -x scripts/run_shellcheck.sh)

[[ "${#args[@]}" -eq "${#expected[@]}" ]] || \
  fail "expected ${#expected[@]} shellcheck args, got ${#args[@]}: ${args[*]}"

for i in "${!expected[@]}"; do
  [[ "${args[$i]}" == "${expected[$i]}" ]] || \
    fail "expected shellcheck arg $i to be ${expected[$i]}, got ${args[$i]}"
done

printf 'ok - run_shellcheck runner supports bounded target smoke\n'
