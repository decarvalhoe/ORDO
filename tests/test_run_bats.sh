#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNNER="$ROOT/scripts/run_bats.sh"

fail() {
  printf 'not ok - %s\n' "$*" >&2
  exit 1
}

[[ -f "$RUNNER" ]] || fail "expected $RUNNER to exist"

bash "$RUNNER"

printf 'ok - run_bats runner passes\n'
