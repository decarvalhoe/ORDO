#!/usr/bin/env bats
# tests/dispatch_ticket_wave_resilience.bats — coverage for ORDO #327.
#
# `scripts/dispatch_wave.sh` MUST decouple individual dispatch invocations:
#   - one entry failing or being denied does NOT cancel sibling entries;
#   - per-entry outcomes are recorded in a durable JSON ledger;
#   - --resume skips entries already recorded as dispatched;
#   - the wave summary reflects the actual matrix outcome, not the
#     interactive tool harness's view of cancellation.
#
# These tests stub `scripts/dispatch_ticket.sh` with a deterministic
# script whose exit code is controlled by the agent name, then run the
# wave dispatcher against a 4-row matrix and assert the ledger.

load './helpers.bash'

setup() {
  setup_orch_test

  # Sanitize the toolkit pieces that dispatch_wave.sh sources.
  toolkit_file scripts/dispatch_wave.sh >/dev/null
  toolkit_file lib/audit_log.sh >/dev/null
  toolkit_file lib/config_check.sh >/dev/null
  toolkit_file lib/dry_run.sh >/dev/null
  toolkit_file lib/log_bounds.sh >/dev/null
  toolkit_file lib/process_safety.sh >/dev/null
  toolkit_file lib/state_persist.sh >/dev/null
  chmod +x "$SANITIZED_TK/scripts/dispatch_wave.sh"

  # Stub dispatch_ticket.sh: exit codes are encoded in the agent name so
  # the test can simulate (a) ok, (b) "auto-mode denial" (exit 79 ==
  # ORCH_DISPATCH_NOT_CONSUMED_EXIT_CODE), (c) generic failure (exit 1).
  cat > "$SANITIZED_TK/scripts/dispatch_ticket.sh" <<'STUB'
#!/usr/bin/env bash
# stub dispatch_ticket.sh — exit code controlled by agent name.
agent=$2
case "$agent" in
  ok-*)
    printf 'stub-dispatch-ok agent=%s ticket=%s\n' "$agent" "$3"
    exit 0 ;;
  deny-*)
    printf 'stub-deny agent=%s ticket=%s\n' "$agent" "$3" >&2
    exit 79 ;;
  fail-*)
    printf 'stub-fail agent=%s ticket=%s\n' "$agent" "$3" >&2
    exit 1 ;;
  *)
    printf 'stub-unknown-agent %s\n' "$agent" >&2
    exit 2 ;;
esac
STUB
  chmod +x "$SANITIZED_TK/scripts/dispatch_ticket.sh"

  export PROJECT="ordo"
  mkdir -p "$BATS_TEST_TMPDIR/configs" "$BATS_TEST_TMPDIR/prompts"
  cat > "$BATS_TEST_TMPDIR/configs/ordo.config.sh" <<'EOF'
PROJECT="ordo"
GH_REPO="example/ordo"
DEFAULT_BRANCH="main"
EOF

  # Each entry needs a real prompt file path even though the stub ignores
  # the contents — dispatch_wave.sh forwards $prompt to dispatch_ticket.sh.
  for slot in ok-alpha deny-bravo ok-charlie fail-delta; do
    printf 'noop\n' > "$BATS_TEST_TMPDIR/prompts/${slot}.md"
  done

  cat > "$BATS_TEST_TMPDIR/matrix.tsv" <<EOF
# wave matrix: agent\tticket\tprompt\tproject_config
ok-alpha	101	$BATS_TEST_TMPDIR/prompts/ok-alpha.md	$BATS_TEST_TMPDIR/configs/ordo.config.sh
deny-bravo	102	$BATS_TEST_TMPDIR/prompts/deny-bravo.md	$BATS_TEST_TMPDIR/configs/ordo.config.sh
ok-charlie	103	$BATS_TEST_TMPDIR/prompts/ok-charlie.md	$BATS_TEST_TMPDIR/configs/ordo.config.sh
fail-delta	104	$BATS_TEST_TMPDIR/prompts/fail-delta.md	$BATS_TEST_TMPDIR/configs/ordo.config.sh
EOF
}

run_wave() {
  local wave=$1
  shift
  ORCH_LOG_DIR="$ORCH_LOG_DIR" \
  ORCH_STATE_BASE="$ORCH_STATE_BASE" \
  ORCH_DISPATCH_WAVE_CHILD_TIMEOUT_SEC=10 \
  bash "$SANITIZED_TK/scripts/dispatch_wave.sh" \
    "$wave" "$BATS_TEST_TMPDIR/matrix.tsv" "$@"
}

ledger_path() {
  printf '%s/_waves/%s.json' "$ORCH_STATE_BASE" "$1"
}

@test "denied or failed entry does not cancel sibling dispatches" {
  run run_wave "wave-iso"
  [ "$status" -eq 0 ]

  ledger="$(ledger_path wave-iso)"
  [ -s "$ledger" ]

  # All four agents must have a recorded outcome — none silently
  # cancelled even though the matrix contains a deny + a failure.
  recorded=$(jq -r '.entries | length' "$ledger")
  [ "$recorded" -eq 4 ]

  status_alpha=$(jq -r '.entries[] | select(.agent == "ok-alpha") | .status' "$ledger")
  status_bravo=$(jq -r '.entries[] | select(.agent == "deny-bravo") | .status' "$ledger")
  status_charlie=$(jq -r '.entries[] | select(.agent == "ok-charlie") | .status' "$ledger")
  status_delta=$(jq -r '.entries[] | select(.agent == "fail-delta") | .status' "$ledger")

  [ "$status_alpha" = "dispatched" ]
  [ "$status_bravo" = "denied" ]
  [ "$status_charlie" = "dispatched" ]
  [ "$status_delta" = "failed" ]
}

@test "wave summary line reports per-status totals" {
  run run_wave "wave-summary"
  [ "$status" -eq 0 ]
  echo "$output"
  [[ "$output" == *"total=4 dispatched=2 denied=1 failed=1 skipped=0"* ]]
}

@test "ledger captures exit codes and stderr tail per entry" {
  run run_wave "wave-stderr"
  [ "$status" -eq 0 ]

  ledger="$(ledger_path wave-stderr)"
  bravo_exit=$(jq -r '.entries[] | select(.agent == "deny-bravo") | .exit_code' "$ledger")
  bravo_tail=$(jq -r '.entries[] | select(.agent == "deny-bravo") | .stderr_tail' "$ledger")
  delta_exit=$(jq -r '.entries[] | select(.agent == "fail-delta") | .exit_code' "$ledger")

  [ "$bravo_exit" = "79" ]
  [[ "$bravo_tail" == *"stub-deny"* ]]
  [ "$delta_exit" = "1" ]
}

@test "--resume skips already-dispatched entries" {
  run run_wave "wave-resume"
  [ "$status" -eq 0 ]

  ledger="$(ledger_path wave-resume)"
  initial_count=$(jq -r '.entries | length' "$ledger")
  [ "$initial_count" -eq 4 ]

  run run_wave "wave-resume" --resume
  [ "$status" -eq 0 ]
  echo "$output"

  # Every dispatched entry from the prior run must be reported as SKIP.
  [[ "$output" == *"SKIP"*"agent=ok-alpha"* ]]
  [[ "$output" == *"SKIP"*"agent=ok-charlie"* ]]
  # Denied / failed entries are NOT skipped — operator can re-dispatch.
  [[ "$output" == *"DENIED"*"agent=deny-bravo"* ]]
  [[ "$output" == *"FAILED"*"agent=fail-delta"* ]]

  total_after=$(jq -r '.entries | length' "$ledger")
  # Resume appends two new outcome rows for bravo + delta; alpha + charlie
  # are skipped and NOT re-recorded.
  [ "$total_after" -eq 6 ]
}

@test "--all-must-succeed exits non-zero when any entry is denied or failed" {
  run run_wave "wave-strict" --all-must-succeed
  [ "$status" -eq 1 ]
  ledger="$(ledger_path wave-strict)"
  # The strict gate is on exit code only — the ledger must still contain
  # all four entries (not aborted mid-wave).
  count=$(jq -r '.entries | length' "$ledger")
  [ "$count" -eq 4 ]
}

@test "--dry-run records dry_run rows without invoking dispatch_ticket" {
  cat > "$SANITIZED_TK/scripts/dispatch_ticket.sh" <<'STUB'
#!/usr/bin/env bash
echo "dispatch_ticket.sh MUST NOT run during --dry-run" >&2
exit 99
STUB
  chmod +x "$SANITIZED_TK/scripts/dispatch_ticket.sh"

  run run_wave "wave-dry" --dry-run
  [ "$status" -eq 0 ]

  ledger="$(ledger_path wave-dry)"
  count=$(jq -r '.entries | length' "$ledger")
  [ "$count" -eq 4 ]
  statuses=$(jq -r '.entries | map(.status) | unique | join(",")' "$ledger")
  [ "$statuses" = "dry_run" ]
}

@test "matrix file rejects malformed wave id" {
  run bash "$SANITIZED_TK/scripts/dispatch_wave.sh" "wave with spaces" "$BATS_TEST_TMPDIR/matrix.tsv"
  [ "$status" -eq 2 ]
  [[ "$output" == *"invalid wave id"* ]]
}

@test "missing matrix file yields a clear usage error" {
  run bash "$SANITIZED_TK/scripts/dispatch_wave.sh" "wave-missing" "/no/such/path.tsv"
  [ "$status" -eq 2 ]
  [[ "$output" == *"matrix file not found"* ]]
}
