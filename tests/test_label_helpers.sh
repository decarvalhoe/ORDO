#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/lib/label_helpers.sh"

fail() {
  printf 'not ok - %s\n' "$*" >&2
  exit 1
}

supported=$'priority:P0\npriority:P1'

[[ "$(label_helpers_priority_for_labels "" "$supported")" == "none|300|P3|unlabeled" ]] \
  || fail "unlabeled issue should keep default planning rank without a GitHub priority label"

[[ "$(label_helpers_priority_for_labels "priority:P3" "$supported")" == "none|400|P3|unsupported" ]] \
  || fail "unsupported priority label should not be emitted as a GitHub label"

[[ "$(label_helpers_priority_for_labels "priority:P1" "$supported")" == "P1|800|P1|supported" ]] \
  || fail "supported priority label should be preserved"

missing=$(label_helpers_missing_labels "$supported" "priority:P0,priority:P3")
[[ "$missing" == "priority:P3" ]] \
  || fail "missing label preflight should report required labels absent from the repo"

printf 'ok - label helpers align priority labels with repo vocabulary\n'
