#!/usr/bin/env bash
# tests/test_run_bats.sh -- exercises the aggregate path for the bats suites.
#
# scripts/run_bats.sh mirrors only config/, examples/, lib/, scripts/,
# templates/, tests/ (plus install.sh) into a sanitized toolkit dir under
# $TEST_TMP/toolkit before invoking bats. README.md, PRODUCT.md, and the
# docs/ tree are intentionally not mirrored, so any bats assertion that
# needs them must detect the sanitized-mirror context (e.g. via
# tests/helpers.bash:detect_real_repo_root) and `skip` rather than fail.
#
# Aggregate-vs-isolated parity (#323):
#
#   - Aggregate: `bash scripts/run_bats.sh` (this wrapper). Tests run
#     against $TEST_TMP/toolkit/. Tests that need the real docs tree
#     skip with a documented reason.
#   - Isolated: `bats tests/docs_*.bats` from the checkout. Tests run
#     against the real repo root, so docs-tree assertions execute.
#
# Reviewers comparing CI output to a local isolated run will see
# different `# skip` counts on docs-system suites; that is expected.
# See `docs/dispatch-planning.md` "Aggregate vs Isolated Bats Runs" for
# the parity contract and "Deferred Docs-system Skip Reporting" for the
# reading recipe that distinguishes a sanitized-mirror skip (no
# remediation owed) from a deferred-ticket skip (remediation owed once
# the owning ticket lands).
# orch-shell-test-timeout-sec: 1800
# (the aggregate bats suite grew past the global 120s ceiling with the #806
# control-plane suites; run_shell_tests.sh honours this per-test marker.)
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
