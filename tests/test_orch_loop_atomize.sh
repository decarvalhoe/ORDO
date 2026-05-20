#!/usr/bin/env bash
# Issue #763: queue resolver phase B — orch_loop auto-atomize step.
#
# Validates the auto-atomize helpers wired into scripts/orch_loop.sh:
#
#   * orch_auto_atomize_budget_remaining counts entries within the rolling
#     hour and caps below ORCH_AUTO_ATOMIZE_MAX_PER_HOUR.
#   * orch_auto_atomize_should_run returns success only when
#     ready_count == 0 AND shipped_suspect_count == 0 AND atomize_count > 0.
#   * orch_auto_atomize_step invokes dispatch_plan with the computed
#     budget = min(cycle-cap, hourly-cap-remaining), parses
#     AUTO_ATOMIZE_SUMMARY stderr lines into the rate-limit ledger, and
#     emits one structured `AUTO_ATOMIZE parent=#N children=[#a,#b]
#     cycle=K project=...` audit row per parent.
#   * The hourly cap is enforced from the ledger: once
#     ORCH_AUTO_ATOMIZE_MAX_PER_HOUR creations land in the past 3600s,
#     subsequent cycles must skip with a cap-exhausted audit row.
#
# The test mirrors the test_orch_loop_single_orchestrator.sh pattern:
# extract the helpers from orch_loop.sh into a sourceable file so we do
# not pay the cost of a full daemon boot (which would source ~10 libs +
# require a Codex/Claude CLI binary). The extraction proves the helpers
# remain reachable from the boot path.
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

mkdir -p "$TEST_TMP/logs" "$TEST_TMP/state/auto-atomize-test" \
  "$TEST_TMP/toolkit/scripts" "$TEST_TMP/bin"

# Extract the auto-atomize helpers from orch_loop.sh. The boot guard
# (require_daemon_confirmation + require_single_orchestrator) sits one
# call below these functions; loading them in isolation lets us assert
# their behaviour without paying the boot cost.
HELPERS_SH="$TEST_TMP/orch_auto_atomize_helpers.sh"
awk '
  /^orch_auto_atomize_budget_remaining\(\) \{/ { in_fn = 1 }
  /^orch_auto_atomize_should_run\(\) \{/       { in_fn = 1 }
  /^orch_auto_atomize_step\(\) \{/             { in_fn = 1 }
  in_fn { print }
  in_fn && /^\}$/                               { in_fn = 0 }
' "$ROOT/scripts/orch_loop.sh" > "$HELPERS_SH"
[[ -s "$HELPERS_SH" ]] \
  || fail "failed to extract orch_auto_atomize_* helpers from orch_loop.sh"

# All three helpers must round-trip; if any is missing the extraction
# regex silently dropped it and the rest of the assertions would be
# meaningless.
for fn in orch_auto_atomize_budget_remaining orch_auto_atomize_should_run orch_auto_atomize_step; do
  grep -q "^${fn}() {" "$HELPERS_SH" \
    || fail "extracted helpers missing ${fn}"
done

# Fake dispatch_plan.sh: reads $FAKE_PLAN_FILE for --json output, and
# reads $FAKE_ATOMIZE_SUMMARY_FILE for the stderr AUTO_ATOMIZE_SUMMARY
# lines emitted under --atomize. We also record every invocation so the
# test can assert the CLI shape the helper produces.
FAKE_TK="$TEST_TMP/toolkit"
cat > "$FAKE_TK/scripts/dispatch_plan.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${FAKE_DISPATCH_PLAN_LOG:?FAKE_DISPATCH_PLAN_LOG required}"
if [[ "$*" == *"--atomize"* ]]; then
  if [[ -n "${FAKE_ATOMIZE_SUMMARY_FILE:-}" && -f "$FAKE_ATOMIZE_SUMMARY_FILE" ]]; then
    cat "$FAKE_ATOMIZE_SUMMARY_FILE" >&2
  fi
  exit 0
fi
if [[ "$*" == *"--json"* && -n "${FAKE_PLAN_FILE:-}" && -f "$FAKE_PLAN_FILE" ]]; then
  cat "$FAKE_PLAN_FILE"
  exit 0
fi
printf '[]\n'
EOF
chmod +x "$FAKE_TK/scripts/dispatch_plan.sh"

# --- 1. orch_auto_atomize_budget_remaining --------------------------------
run_budget() {
  bash -c '
    set -euo pipefail
    source "$1"
    orch_auto_atomize_budget_remaining "$2"
  ' _ "$HELPERS_SH" "$1"
}

ledger="$TEST_TMP/budget.ledger"
rm -f "$ledger"

got=$(ORCH_AUTO_ATOMIZE_MAX_PER_HOUR=6 run_budget "$ledger")
[[ "$got" == "6" ]] \
  || fail "empty ledger should expose full cap=6 budget; got '$got'"

now=$(date +%s)
{
  printf '%s 100 200 1\n' "$((now - 60))"
  printf '%s 100 201 1\n' "$((now - 30))"
  printf '%s 101 202 2\n' "$((now - 10))"
} >> "$ledger"

got=$(ORCH_AUTO_ATOMIZE_MAX_PER_HOUR=6 run_budget "$ledger")
[[ "$got" == "3" ]] \
  || fail "ledger with 3 recent entries should leave 3 remaining; got '$got'"

got=$(ORCH_AUTO_ATOMIZE_MAX_PER_HOUR=2 run_budget "$ledger")
[[ "$got" == "0" ]] \
  || fail "ledger over-cap should clamp budget at 0; got '$got'"

# Aged entries (>3600s) must not count toward the rolling-hour cap.
printf '%s 102 203 0\n' "$((now - 7200))" >> "$ledger"
got=$(ORCH_AUTO_ATOMIZE_MAX_PER_HOUR=6 run_budget "$ledger")
[[ "$got" == "3" ]] \
  || fail "stale entry past the 1h cutoff must not reduce the budget; got '$got'"

# --- 2. orch_auto_atomize_should_run --------------------------------------
run_should() {
  local plan_json=$1
  bash -c '
    set -euo pipefail
    source "$1"
    if orch_auto_atomize_should_run "$2"; then
      printf "RUN\n"
    else
      printf "SKIP\n"
    fi
  ' _ "$HELPERS_SH" "$plan_json"
}

# ready=0, shipped_suspect=0, atomize=1 → should run
plan_ok='[{"issue":1,"status":"atomize","priority":"P1"}]'
[[ "$(run_should "$plan_ok")" == "RUN" ]] \
  || fail "should_run must return RUN when only atomize rows are present"

# stale_parent rows also count as atomize candidates per the helper
plan_followup='[{"issue":1,"status":"stale_parent","priority":"P1"}]'
[[ "$(run_should "$plan_followup")" == "RUN" ]] \
  || fail "stale_parent rows must count toward atomize candidates"

# shipped_suspect present → must skip (Phase A clears these first)
plan_shipped='[{"issue":1,"status":"atomize","priority":"P1"},{"issue":2,"status":"shipped_suspect","priority":"P2"}]'
[[ "$(run_should "$plan_shipped")" == "SKIP" ]] \
  || fail "should_run must SKIP when shipped_suspect rows remain"

# ready row present → must skip (we only auto-atomize on empty ready queue)
plan_ready='[{"issue":1,"status":"atomize","priority":"P1"},{"issue":2,"status":"ready","priority":"P3"}]'
[[ "$(run_should "$plan_ready")" == "SKIP" ]] \
  || fail "should_run must SKIP when ready rows are present"

# no atomize candidates → must skip
plan_none='[{"issue":1,"status":"blocked","priority":"P1"}]'
[[ "$(run_should "$plan_none")" == "SKIP" ]] \
  || fail "should_run must SKIP when no atomize candidates exist"

# --- 3. orch_auto_atomize_step --------------------------------------------
# Drive the full step with a controlled plan + summary fixture. Audit and
# state_dir are stubbed so we can inspect the events without booting the
# daemon.

run_step() {
  local cycle=$1
  local ledger_file=$2
  local plan_file=$3
  local summary_file=$4
  local audit_capture=$5
  local invocations_log=$6
  bash -c '
    set -euo pipefail
    HELPERS_SH=$1
    LEDGER=$2
    PLAN_FILE=$3
    SUMMARY_FILE=$4
    AUDIT_CAPTURE=$5
    INVOC_LOG=$6
    CYCLE=$7
    FAKE_TK=$8
    state_dir() { printf "%s\n" "$LEDGER_DIR"; }
    audit() { printf "AUDIT %s\n" "$*" >> "$AUDIT_CAPTURE"; }
    LEDGER_DIR=$(dirname "$LEDGER")
    mkdir -p "$LEDGER_DIR"
    TK="$FAKE_TK"
    PROJECT_ARG="auto-atomize-test"
    PROJECT="auto-atomize-test"
    export FAKE_PLAN_FILE="$PLAN_FILE"
    export FAKE_ATOMIZE_SUMMARY_FILE="$SUMMARY_FILE"
    export FAKE_DISPATCH_PLAN_LOG="$INVOC_LOG"
    export ORCH_AUTO_ATOMIZE_LEDGER="$LEDGER"
    source "$HELPERS_SH"
    orch_auto_atomize_step "$CYCLE"
  ' _ "$HELPERS_SH" "$ledger_file" "$plan_file" "$summary_file" \
      "$audit_capture" "$invocations_log" "$cycle" "$FAKE_TK"
}

ATOMIZE_LEDGER="$TEST_TMP/state/auto-atomize-test/auto_atomize.ledger"
AUDIT_CAPTURE="$TEST_TMP/logs/audit.log"
INVOC_LOG="$TEST_TMP/logs/dispatch_plan.invocations"
PLAN_FILE="$TEST_TMP/plan.json"
SUMMARY_FILE="$TEST_TMP/atomize.summary"

# Scenario 3a: conditions met, ledger empty → step invokes --atomize with
# budget=min(cycle-cap, hourly-cap) and records two child entries.
rm -f "$ATOMIZE_LEDGER" "$AUDIT_CAPTURE" "$INVOC_LOG"
cat > "$PLAN_FILE" <<'JSON'
[
  {"issue":501,"status":"atomize","priority":"P1"},
  {"issue":502,"status":"atomize","priority":"P2"}
]
JSON
cat > "$SUMMARY_FILE" <<'EOS'
AUTO_ATOMIZE_SUMMARY parent=501 children=601,602 project=auto-atomize-test max_per_cycle=2
EOS

ORCH_AUTO_ATOMIZE_MAX_PER_HOUR=6 ORCH_AUTO_ATOMIZE_MAX_PER_CYCLE=2 \
  run_step 5 "$ATOMIZE_LEDGER" "$PLAN_FILE" "$SUMMARY_FILE" \
  "$AUDIT_CAPTURE" "$INVOC_LOG"

# The step must invoke dispatch_plan twice: once for the --json plan
# snapshot and once for the --atomize --apply --max-children-per-cycle
# mutation. The mutation must carry the budget we computed (2).
grep -q -- "--json" "$INVOC_LOG" \
  || fail "step must run dispatch_plan --json to read the plan; log=$(cat "$INVOC_LOG")"
grep -q -- "--atomize --apply --max-children-per-cycle 2" "$INVOC_LOG" \
  || fail "step must invoke dispatch_plan with --atomize --apply --max-children-per-cycle 2; log=$(cat "$INVOC_LOG")"

grep -q '^AUDIT AUTO_ATOMIZE parent=#501 children=\[#601,#602\] cycle=5 project=auto-atomize-test mode=apply max_per_cycle=2 hourly_cap=6$' \
  "$AUDIT_CAPTURE" \
  || fail "expected AUTO_ATOMIZE audit row for parent=501; capture=$(cat "$AUDIT_CAPTURE")"

# Ledger must carry one row per child with the correct shape:
# `<ts> <parent> <child> <cycle>`.
[[ -f "$ATOMIZE_LEDGER" ]] \
  || fail "ledger must be created by the step"
ledger_lines=$(wc -l < "$ATOMIZE_LEDGER" | tr -d ' ')
[[ "$ledger_lines" == "2" ]] \
  || fail "ledger must record one entry per child (expected 2, got $ledger_lines): $(cat "$ATOMIZE_LEDGER")"
awk '{ if ($2 != "501" || ($3 != "601" && $3 != "602") || $4 != "5") exit 1 }' "$ATOMIZE_LEDGER" \
  || fail "ledger entries must use shape <ts> 501 <child> 5; got: $(cat "$ATOMIZE_LEDGER")"

# Scenario 3b: hourly cap exhausted by an existing ledger → step must
# skip and audit the reason without running --atomize again.
now=$(date +%s)
rm -f "$ATOMIZE_LEDGER" "$AUDIT_CAPTURE" "$INVOC_LOG"
mkdir -p "$(dirname "$ATOMIZE_LEDGER")"
for i in 1 2 3 4 5 6; do
  printf '%s 800 %s 1\n' "$now" "$((900 + i))" >> "$ATOMIZE_LEDGER"
done

ORCH_AUTO_ATOMIZE_MAX_PER_HOUR=6 ORCH_AUTO_ATOMIZE_MAX_PER_CYCLE=2 \
  run_step 7 "$ATOMIZE_LEDGER" "$PLAN_FILE" "$SUMMARY_FILE" \
  "$AUDIT_CAPTURE" "$INVOC_LOG"

if grep -q -- "--atomize" "$INVOC_LOG"; then
  fail "hourly-cap-exhausted run must NOT call dispatch_plan --atomize; log=$(cat "$INVOC_LOG")"
fi
grep -q '^AUDIT AUTO_ATOMIZE skip cycle=7 project=auto-atomize-test reason=hourly-cap-exhausted cap=6$' \
  "$AUDIT_CAPTURE" \
  || fail "expected hourly-cap-exhausted skip audit row; capture=$(cat "$AUDIT_CAPTURE")"
ledger_lines=$(wc -l < "$ATOMIZE_LEDGER" | tr -d ' ')
[[ "$ledger_lines" == "6" ]] \
  || fail "skip path must not append to ledger; got $ledger_lines lines: $(cat "$ATOMIZE_LEDGER")"

# Scenario 3c: shipped_suspect rows present → step must skip with the
# conditions-unmet reason so Phase A can clear them first.
rm -f "$AUDIT_CAPTURE" "$INVOC_LOG" "$ATOMIZE_LEDGER"
cat > "$PLAN_FILE" <<'JSON'
[
  {"issue":501,"status":"atomize","priority":"P1"},
  {"issue":502,"status":"shipped_suspect","priority":"P2"}
]
JSON
ORCH_AUTO_ATOMIZE_MAX_PER_HOUR=6 ORCH_AUTO_ATOMIZE_MAX_PER_CYCLE=2 \
  run_step 9 "$ATOMIZE_LEDGER" "$PLAN_FILE" "$SUMMARY_FILE" \
  "$AUDIT_CAPTURE" "$INVOC_LOG"

if grep -q -- "--atomize" "$INVOC_LOG"; then
  fail "shipped_suspect present: must not call --atomize; log=$(cat "$INVOC_LOG")"
fi
grep -q '^AUDIT AUTO_ATOMIZE skip cycle=9 project=auto-atomize-test reason=conditions-unmet ready=0 atomize=1 shipped_suspect=1$' \
  "$AUDIT_CAPTURE" \
  || fail "expected conditions-unmet skip audit row; capture=$(cat "$AUDIT_CAPTURE")"

# Scenario 3d: ready queue not empty → step skips with conditions-unmet
# and reports the non-zero ready count.
rm -f "$AUDIT_CAPTURE" "$INVOC_LOG" "$ATOMIZE_LEDGER"
cat > "$PLAN_FILE" <<'JSON'
[
  {"issue":501,"status":"atomize","priority":"P1"},
  {"issue":701,"status":"ready","priority":"P3"}
]
JSON
ORCH_AUTO_ATOMIZE_MAX_PER_HOUR=6 ORCH_AUTO_ATOMIZE_MAX_PER_CYCLE=2 \
  run_step 11 "$ATOMIZE_LEDGER" "$PLAN_FILE" "$SUMMARY_FILE" \
  "$AUDIT_CAPTURE" "$INVOC_LOG"

if grep -q -- "--atomize" "$INVOC_LOG"; then
  fail "ready row present: must not call --atomize; log=$(cat "$INVOC_LOG")"
fi
grep -q '^AUDIT AUTO_ATOMIZE skip cycle=11 project=auto-atomize-test reason=conditions-unmet ready=1 atomize=1 shipped_suspect=0$' \
  "$AUDIT_CAPTURE" \
  || fail "expected ready-present conditions-unmet audit row; capture=$(cat "$AUDIT_CAPTURE")"

# Scenario 3e: partial hourly budget → step asks for the smaller of
# (cycle-cap, hourly-remaining). With cap=6 and 5 recent entries, only
# 1 child is allowed despite cycle-cap=2.
rm -f "$AUDIT_CAPTURE" "$INVOC_LOG" "$ATOMIZE_LEDGER"
mkdir -p "$(dirname "$ATOMIZE_LEDGER")"
for i in 1 2 3 4 5; do
  printf '%s 800 %s 1\n' "$(date +%s)" "$((900 + i))" >> "$ATOMIZE_LEDGER"
done
cat > "$PLAN_FILE" <<'JSON'
[{"issue":501,"status":"atomize","priority":"P1"}]
JSON
cat > "$SUMMARY_FILE" <<'EOS'
AUTO_ATOMIZE_SUMMARY parent=501 children=999 project=auto-atomize-test max_per_cycle=1
EOS
ORCH_AUTO_ATOMIZE_MAX_PER_HOUR=6 ORCH_AUTO_ATOMIZE_MAX_PER_CYCLE=2 \
  run_step 13 "$ATOMIZE_LEDGER" "$PLAN_FILE" "$SUMMARY_FILE" \
  "$AUDIT_CAPTURE" "$INVOC_LOG"

grep -q -- "--atomize --apply --max-children-per-cycle 1" "$INVOC_LOG" \
  || fail "partial budget run must clamp to remaining=1; log=$(cat "$INVOC_LOG")"
grep -q '^AUDIT AUTO_ATOMIZE parent=#501 children=\[#999\] cycle=13 project=auto-atomize-test mode=apply max_per_cycle=1 hourly_cap=6$' \
  "$AUDIT_CAPTURE" \
  || fail "expected clamped-budget AUTO_ATOMIZE audit row; capture=$(cat "$AUDIT_CAPTURE")"

# --- 4. Boot wiring sanity ------------------------------------------------
# The helpers exist; confirm the boot path actually calls them inside the
# main loop body so a future refactor cannot silently disconnect Phase B.
grep -q 'orch_auto_atomize_step "\$cycle"' "$ROOT/scripts/orch_loop.sh" \
  || fail "orch_loop.sh main loop must invoke orch_auto_atomize_step \"\$cycle\""
grep -q 'ORCH_AUTO_ATOMIZE_DISABLED' "$ROOT/scripts/orch_loop.sh" \
  || fail "orch_loop.sh must honour ORCH_AUTO_ATOMIZE_DISABLED opt-out"

printf 'ok - orch_loop auto-atomize step gates on continuation_guard signals and respects ORCH_AUTO_ATOMIZE_MAX_PER_HOUR ledger (#763)\n'
