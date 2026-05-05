#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="$ROOT/.github/workflows/ci.yml"

fail() {
  printf 'not ok - %s\n' "$*" >&2
  exit 1
}

[[ -f "$WORKFLOW" ]] || fail "expected $WORKFLOW to exist"

content=$(tr -d '\r' < "$WORKFLOW")

[[ "$content" == *"pull_request:"* ]] || fail "workflow must run on pull_request"
[[ "$content" == *"push:"* ]] || fail "workflow must run on push"
[[ "$content" == *"scripts/run_shellcheck.sh"* ]] || fail "workflow must run the shellcheck runner"
[[ "$content" == *"scripts/run_shell_tests.sh"* ]] || fail "workflow must run the shell test runner"
[[ "$content" == *"scripts/run_bats.sh"* ]] || fail "workflow must run the bats runner"

printf 'ok - ci workflow wires repo runners\n'
