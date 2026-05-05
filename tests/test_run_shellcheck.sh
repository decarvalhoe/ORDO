#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNNER="$ROOT/scripts/run_shellcheck.sh"

fail() {
  printf 'not ok - %s\n' "$*" >&2
  exit 1
}

[[ -f "$RUNNER" ]] || fail "expected $RUNNER to exist"

bash "$RUNNER"

printf 'ok - run_shellcheck runner passes\n'
