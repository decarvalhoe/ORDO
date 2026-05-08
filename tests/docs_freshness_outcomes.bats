#!/usr/bin/env bats
# tests/docs_freshness_outcomes.bats — verifies the four documented
# outcomes of the documentation impact gate (#260) under epic #257
# acceptance for #263. Runs as fixtures against the gate runner so the
# decision matrix is locked.
#
# The gate is owned by issue #260 and may not be present at this base.
# Each test detects the gate and either exercises it or `skip`s with a
# documented reason.

load './helpers.bash'

setup() {
  setup_orch_test
  ROOT="${ROOT:-$(cd "$BATS_TEST_DIRNAME/.." && pwd)}"
  GATE="$ROOT/scripts/docs_impact_gate.sh"
  export ROOT GATE
}

gate_present() {
  [ -x "$GATE" ] || [ -f "$GATE" ]
}

write_paths() {
  local file="$1"; shift
  : >"$file"
  printf '%s\n' "$@" >>"$file"
}

run_gate_check() {
  local paths_file="$1" decl_file="$2"
  run timeout 30 bash "$GATE" check \
    --paths-from "$paths_file" \
    --declaration-from "$decl_file" \
    --evidence-out "$BATS_TEST_TMPDIR/evidence.md" \
    --quiet
}

@test "gate fixture: docs-updated outcome on docs+surface change" {
  if ! gate_present; then
    skip "docs impact gate (#260) not yet present at this base"
  fi
  local paths="$BATS_TEST_TMPDIR/paths.txt"
  local decl="$BATS_TEST_TMPDIR/decl.txt"
  write_paths "$paths" "scripts/dispatch_ticket.sh" "docs/dispatch-planning.md"
  cat >"$decl" <<'EOF'
Docs-Impact: docs-updated
EOF
  run_gate_check "$paths" "$decl"
  [ "$status" -eq 0 ]
  grep -qE 'Decision:.*pass' "$BATS_TEST_TMPDIR/evidence.md"
}

@test "gate fixture: no-docs-needed outcome with explicit rationale" {
  if ! gate_present; then
    skip "docs impact gate (#260) not yet present at this base"
  fi
  local paths="$BATS_TEST_TMPDIR/paths.txt"
  local decl="$BATS_TEST_TMPDIR/decl.txt"
  write_paths "$paths" "scripts/dispatch_ticket.sh" "lib/audit_log.sh"
  cat >"$decl" <<'EOF'
Docs-Impact: no-docs-needed
Docs-Impact-Note: internal helper rename, no surface change
EOF
  run_gate_check "$paths" "$decl"
  [ "$status" -eq 0 ]
  grep -qE 'Decision:.*pass' "$BATS_TEST_TMPDIR/evidence.md"
}

@test "gate fixture: follow-up outcome with linked issue reference" {
  if ! gate_present; then
    skip "docs impact gate (#260) not yet present at this base"
  fi
  local paths="$BATS_TEST_TMPDIR/paths.txt"
  local decl="$BATS_TEST_TMPDIR/decl.txt"
  write_paths "$paths" "scripts/dispatch_ticket.sh"
  cat >"$decl" <<'EOF'
Docs-Impact: follow-up
Docs-Impact-Followup: RBOKproject/ORDO#9999
EOF
  run_gate_check "$paths" "$decl"
  [ "$status" -eq 0 ]
  grep -qE 'Decision:.*pass' "$BATS_TEST_TMPDIR/evidence.md"
}

@test "gate fixture: blocked outcome on undeclared surface change" {
  if ! gate_present; then
    skip "docs impact gate (#260) not yet present at this base"
  fi
  local paths="$BATS_TEST_TMPDIR/paths.txt"
  local decl="$BATS_TEST_TMPDIR/decl.txt"
  write_paths "$paths" "scripts/dispatch_ticket.sh"
  : >"$decl"
  run_gate_check "$paths" "$decl"
  # Undeclared surface change is the canonical blocked outcome.
  [ "$status" -eq 1 ]
  grep -qE 'Decision:.*block' "$BATS_TEST_TMPDIR/evidence.md"
}

@test "gate fixture: internal-only change auto-passes without declaration" {
  if ! gate_present; then
    skip "docs impact gate (#260) not yet present at this base"
  fi
  local paths="$BATS_TEST_TMPDIR/paths.txt"
  local decl="$BATS_TEST_TMPDIR/decl.txt"
  write_paths "$paths" "tests/test_findings_ledger.sh" ".gitignore"
  : >"$decl"
  run_gate_check "$paths" "$decl"
  [ "$status" -eq 0 ]
  grep -qE 'Decision:.*pass' "$BATS_TEST_TMPDIR/evidence.md"
}
