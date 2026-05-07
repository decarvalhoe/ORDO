#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  printf 'not ok - %s\n' "$*" >&2
  exit 1
}

for runner in \
  scripts/run_shellcheck.sh \
  scripts/run_shell_tests.sh \
  scripts/run_bats.sh
do
  set +e
  output=$(ORCH_VALIDATOR_FORK_LATENCY_MAX_MS=0 bash "$ROOT/$runner" 2>&1)
  status=$?
  set -e

  [[ "$status" -eq 75 ]] || fail "$runner should exit 75 when fork latency preflight degrades, got $status: $output"
  [[ "$output" == *"validators_degraded"* ]] || fail "$runner should report validators_degraded, got: $output"
  [[ "$output" == *"fork_latency_ms="* ]] || fail "$runner should report fork latency, got: $output"
done

printf 'ok - validator runners short-circuit on degraded fork latency\n'
