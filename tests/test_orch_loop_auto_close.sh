#!/usr/bin/env bash
# Issue #770: queue resolver phase A — orch_loop auto-close wire-in.
#
# Validates the auto-close helpers wired into scripts/orch_loop.sh:
#
#   * orch_auto_close_budget_remaining counts ledger rows within the
#     rolling hour and clamps to ORCH_AUTO_CLOSE_MAX_PER_HOUR.
#   * orch_auto_close_should_run returns success iff the dispatch plan
#     carries at least one shipped_suspect row.
#   * orch_auto_close_step:
#       - skips with reason=mode-off when ORCH_AUTO_CLOSE_MODE=off,
#       - skips with reason=no-shipped-suspect when the plan is clean,
#       - in dry-run mode emits ONE `ORCH_LOOP AUTO_CLOSE_RAN ... mode=dry-run`
#         audit row when the plan carries shipped_suspect rows,
#       - in apply mode surfaces OPERATOR_AUTHORIZATION_REQUIRED + one
#         intervention_queue.md row per close_failed record (rc=80 from
#         the closed-issue mutation hook),
#       - honours the per-rolling-hour cap from the on-disk ledger.
#   * The boot path wires ORCH_AUTO_CLOSE_DISABLED opt-out + the step
#     invocation; without this the lib alone (operator-only) would never
#     fire autonomously.
#
# Mirrors test_orch_loop_atomize.sh: extract the helpers from
# orch_loop.sh into a sourceable file so the daemon boot guard is
# bypassed (no Codex/Claude CLI required, no library sourcing chain).
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

mkdir -p "$TEST_TMP/logs" "$TEST_TMP/state/auto-close-test" \
  "$TEST_TMP/toolkit/scripts" "$TEST_TMP/bin"

# Extract the auto-close helpers from orch_loop.sh. The boot guard
# (require_daemon_confirmation + require_single_orchestrator) sits well
# above these functions; loading them in isolation lets us assert their
# behaviour without paying the boot cost.
HELPERS_SH="$TEST_TMP/orch_auto_close_helpers.sh"
awk '
  /^orch_auto_close_budget_remaining\(\) \{/    { in_fn = 1 }
  /^orch_auto_close_should_run\(\) \{/          { in_fn = 1 }
  /^orch_auto_close_append_intervention\(\) \{/ { in_fn = 1 }
  /^orch_auto_close_step\(\) \{/                { in_fn = 1 }
  in_fn { print }
  in_fn && /^\}$/                                { in_fn = 0 }
' "$ROOT/scripts/orch_loop.sh" > "$HELPERS_SH"
[[ -s "$HELPERS_SH" ]] \
  || fail "failed to extract orch_auto_close_* helpers from orch_loop.sh"

for fn in \
  orch_auto_close_budget_remaining \
  orch_auto_close_should_run \
  orch_auto_close_append_intervention \
  orch_auto_close_step
do
  grep -q "^${fn}() {" "$HELPERS_SH" \
    || fail "extracted helpers missing ${fn}"
done

# Fake dispatch_plan.sh + auto_close_shipped_suspect.sh. Both record
# every invocation so the test can assert the CLI shape the step builds,
# and both read fixture files for their JSON output so we can drive
# specific scenarios.
FAKE_TK="$TEST_TMP/toolkit"
cat > "$FAKE_TK/scripts/dispatch_plan.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${FAKE_DISPATCH_PLAN_LOG:?FAKE_DISPATCH_PLAN_LOG required}"
if [[ "$*" == *"--json"* && -n "${FAKE_PLAN_FILE:-}" && -f "$FAKE_PLAN_FILE" ]]; then
  cat "$FAKE_PLAN_FILE"
  exit 0
fi
printf '[]\n'
EOF
chmod +x "$FAKE_TK/scripts/dispatch_plan.sh"

cat > "$FAKE_TK/scripts/auto_close_shipped_suspect.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${FAKE_AUTO_CLOSE_LOG:?FAKE_AUTO_CLOSE_LOG required}"
if [[ -n "${FAKE_AUTO_CLOSE_OUTPUT:-}" && -f "$FAKE_AUTO_CLOSE_OUTPUT" ]]; then
  cat "$FAKE_AUTO_CLOSE_OUTPUT"
  exit 0
fi
printf '[]\n'
EOF
chmod +x "$FAKE_TK/scripts/auto_close_shipped_suspect.sh"

# --- 1. orch_auto_close_budget_remaining ----------------------------------
run_budget() {
  bash -c '
    set -euo pipefail
    source "$1"
    orch_auto_close_budget_remaining "$2"
  ' _ "$HELPERS_SH" "$1"
}

ledger="$TEST_TMP/budget.ledger"
rm -f "$ledger"

got=$(ORCH_AUTO_CLOSE_MAX_PER_HOUR=1 run_budget "$ledger")
[[ "$got" == "1" ]] \
  || fail "empty ledger should expose full cap=1 budget; got '$got'"

now=$(date +%s)
printf '%s 5 dry-run 3\n' "$((now - 60))" >> "$ledger"
got=$(ORCH_AUTO_CLOSE_MAX_PER_HOUR=1 run_budget "$ledger")
[[ "$got" == "0" ]] \
  || fail "single recent run should exhaust cap=1; got '$got'"

got=$(ORCH_AUTO_CLOSE_MAX_PER_HOUR=4 run_budget "$ledger")
[[ "$got" == "3" ]] \
  || fail "cap=4 with 1 recent run should leave 3; got '$got'"

# Aged entry (>3600s) must not count toward the rolling-hour cap.
rm -f "$ledger"
printf '%s 9 apply 12\n' "$((now - 7200))" >> "$ledger"
got=$(ORCH_AUTO_CLOSE_MAX_PER_HOUR=1 run_budget "$ledger")
[[ "$got" == "1" ]] \
  || fail "stale entry past the 1h cutoff must not reduce the budget; got '$got'"

# --- 2. orch_auto_close_should_run ---------------------------------------
run_should() {
  local plan_json=$1
  bash -c '
    set -euo pipefail
    source "$1"
    if orch_auto_close_should_run "$2"; then
      printf "RUN\n"
    else
      printf "SKIP\n"
    fi
  ' _ "$HELPERS_SH" "$plan_json"
}

plan_clean='[{"issue":1,"status":"ready","priority":"P1"}]'
[[ "$(run_should "$plan_clean")" == "SKIP" ]] \
  || fail "should_run must SKIP when no shipped_suspect rows are present"

plan_one='[{"issue":1,"status":"shipped_suspect","priority":"P1"}]'
[[ "$(run_should "$plan_one")" == "RUN" ]] \
  || fail "should_run must RUN when at least one shipped_suspect row is present"

plan_mixed='[{"issue":1,"status":"ready","priority":"P1"},{"issue":2,"status":"shipped_suspect","priority":"P2"}]'
[[ "$(run_should "$plan_mixed")" == "RUN" ]] \
  || fail "should_run must RUN when shipped_suspect rows are present even alongside ready rows"

# --- 3. orch_auto_close_step ---------------------------------------------
# Drive the full step with controlled plan + auto-close output fixtures.
# state_dir + audit are stubbed so we can inspect events without booting
# the daemon.

run_step() {
  local cycle=$1
  local ledger_file=$2
  local plan_file=$3
  local auto_close_output=$4
  local audit_capture=$5
  local plan_invoc_log=$6
  local auto_close_invoc_log=$7
  local queue_path=$8
  local mode=$9
  local hourly_cap=${10}
  bash -c '
    set -euo pipefail
    HELPERS_SH=$1
    LEDGER=$2
    PLAN_FILE=$3
    AUTO_CLOSE_OUTPUT=$4
    AUDIT_CAPTURE=$5
    PLAN_INVOC_LOG=$6
    AUTO_CLOSE_INVOC_LOG=$7
    QUEUE_PATH=$8
    MODE=$9
    HOURLY_CAP=${10}
    CYCLE=${11}
    FAKE_TK=${12}
    LEDGER_DIR=$(dirname "$LEDGER")
    mkdir -p "$LEDGER_DIR"
    state_dir() { printf "%s\n" "$LEDGER_DIR"; }
    audit() { printf "AUDIT %s\n" "$*" >> "$AUDIT_CAPTURE"; }
    TK="$FAKE_TK"
    PROJECT_ARG="auto-close-test"
    PROJECT="auto-close-test"
    export FAKE_PLAN_FILE="$PLAN_FILE"
    export FAKE_AUTO_CLOSE_OUTPUT="$AUTO_CLOSE_OUTPUT"
    export FAKE_DISPATCH_PLAN_LOG="$PLAN_INVOC_LOG"
    export FAKE_AUTO_CLOSE_LOG="$AUTO_CLOSE_INVOC_LOG"
    export ORCH_AUTO_CLOSE_LEDGER="$LEDGER"
    export ORCH_AUTO_CLOSE_QUEUE="$QUEUE_PATH"
    export ORCH_AUTO_CLOSE_MODE="$MODE"
    export ORCH_AUTO_CLOSE_MAX_PER_HOUR="$HOURLY_CAP"
    source "$HELPERS_SH"
    orch_auto_close_step "$CYCLE"
  ' _ "$HELPERS_SH" "$ledger_file" "$plan_file" "$auto_close_output" \
      "$audit_capture" "$plan_invoc_log" "$auto_close_invoc_log" \
      "$queue_path" "$mode" "$hourly_cap" "$cycle" "$FAKE_TK"
}

CLOSE_LEDGER="$TEST_TMP/state/auto-close-test/auto_close.ledger"
QUEUE_PATH="$TEST_TMP/state/auto-close-test/intervention_queue.md"
AUDIT_CAPTURE="$TEST_TMP/logs/audit.log"
PLAN_INVOC_LOG="$TEST_TMP/logs/dispatch_plan.invocations"
AUTO_CLOSE_INVOC_LOG="$TEST_TMP/logs/auto_close.invocations"
PLAN_FILE="$TEST_TMP/plan.json"
AUTO_CLOSE_OUTPUT="$TEST_TMP/auto_close.json"

# Scenario 3a: AC fixture — shipped_suspect_count>0 + dry-run mode emits
# ONE ORCH_LOOP AUTO_CLOSE_RAN audit row.
rm -f "$CLOSE_LEDGER" "$AUDIT_CAPTURE" "$PLAN_INVOC_LOG" \
  "$AUTO_CLOSE_INVOC_LOG" "$QUEUE_PATH"
cat > "$PLAN_FILE" <<'JSON'
[
  {"issue":501,"status":"shipped_suspect","priority":"P1"},
  {"issue":502,"status":"shipped_suspect","priority":"P2"},
  {"issue":503,"status":"ready","priority":"P3"}
]
JSON
cat > "$AUTO_CLOSE_OUTPUT" <<'JSON'
[
  {"project":"auto-close-test","issue":501,"pr":601,"outcome":"pass","action":"would_close","reason":"","detail":"","mode":"dry-run"},
  {"project":"auto-close-test","issue":502,"pr":602,"outcome":"missing-acceptance-proof","action":"audit_only","reason":"missing-acceptance-proof","detail":"","mode":"dry-run"}
]
JSON

run_step 7 "$CLOSE_LEDGER" "$PLAN_FILE" "$AUTO_CLOSE_OUTPUT" \
  "$AUDIT_CAPTURE" "$PLAN_INVOC_LOG" "$AUTO_CLOSE_INVOC_LOG" \
  "$QUEUE_PATH" "dry-run" 1

grep -q -- "--include-shipped-suspect --json" "$PLAN_INVOC_LOG" \
  || fail "step must read the plan with --include-shipped-suspect --json; log=$(cat "$PLAN_INVOC_LOG")"
grep -q -- "--dry-run --json" "$AUTO_CLOSE_INVOC_LOG" \
  || fail "step must invoke auto_close_shipped_suspect.sh with --dry-run --json; log=$(cat "$AUTO_CLOSE_INVOC_LOG")"

run_rows=$(grep -c '^AUDIT ORCH_LOOP AUTO_CLOSE_RAN ' "$AUDIT_CAPTURE" || true)
[[ "$run_rows" == "1" ]] \
  || fail "expected exactly one AUTO_CLOSE_RAN audit row; got=$run_rows capture=$(cat "$AUDIT_CAPTURE")"
grep -q '^AUDIT ORCH_LOOP AUTO_CLOSE_RAN cycle=7 project=auto-close-test mode=dry-run candidates=2 closed=0 would_close=1 refused=1 close_failed=0 hourly_cap=1$' \
  "$AUDIT_CAPTURE" \
  || fail "expected dry-run AUTO_CLOSE_RAN row with counts; capture=$(cat "$AUDIT_CAPTURE")"

# Dry-run path must never surface OPERATOR_AUTHORIZATION_REQUIRED or
# write to the intervention queue — those are reserved for apply-mode
# close_failed records.
if grep -q 'OPERATOR_AUTHORIZATION_REQUIRED' "$AUDIT_CAPTURE"; then
  fail "dry-run must not surface OPERATOR_AUTHORIZATION_REQUIRED; capture=$(cat "$AUDIT_CAPTURE")"
fi
[[ ! -e "$QUEUE_PATH" ]] \
  || fail "dry-run must not write to intervention_queue.md; queue=$(cat "$QUEUE_PATH")"

# Ledger must carry one row per run (one entry, not one-per-candidate).
[[ -f "$CLOSE_LEDGER" ]] || fail "ledger must be created by the step"
ledger_lines=$(wc -l < "$CLOSE_LEDGER" | tr -d ' ')
[[ "$ledger_lines" == "1" ]] \
  || fail "ledger must record one row per run (expected 1, got $ledger_lines): $(cat "$CLOSE_LEDGER")"

# Scenario 3b: apply mode + close_failed rc=80 surfaces
# OPERATOR_AUTHORIZATION_REQUIRED + one intervention_queue row per
# affected issue.
rm -f "$CLOSE_LEDGER" "$AUDIT_CAPTURE" "$PLAN_INVOC_LOG" \
  "$AUTO_CLOSE_INVOC_LOG" "$QUEUE_PATH"
cat > "$PLAN_FILE" <<'JSON'
[
  {"issue":601,"status":"shipped_suspect","priority":"P1"},
  {"issue":602,"status":"shipped_suspect","priority":"P2"}
]
JSON
cat > "$AUTO_CLOSE_OUTPUT" <<'JSON'
[
  {"project":"auto-close-test","issue":601,"pr":701,"outcome":"pass","action":"closed","reason":"","detail":"","mode":"apply"},
  {"project":"auto-close-test","issue":602,"pr":702,"outcome":"pass","action":"close_failed","reason":"issue_close_rc=80","detail":"","mode":"apply"}
]
JSON

run_step 9 "$CLOSE_LEDGER" "$PLAN_FILE" "$AUTO_CLOSE_OUTPUT" \
  "$AUDIT_CAPTURE" "$PLAN_INVOC_LOG" "$AUTO_CLOSE_INVOC_LOG" \
  "$QUEUE_PATH" "apply" 4

grep -q -- "--apply --json" "$AUTO_CLOSE_INVOC_LOG" \
  || fail "apply-mode step must invoke auto_close_shipped_suspect.sh with --apply --json; log=$(cat "$AUTO_CLOSE_INVOC_LOG")"
grep -q '^AUDIT ORCH_LOOP AUTO_CLOSE_RAN cycle=9 project=auto-close-test mode=apply candidates=2 closed=1 would_close=0 refused=0 close_failed=1 hourly_cap=4$' \
  "$AUDIT_CAPTURE" \
  || fail "expected apply-mode AUTO_CLOSE_RAN row with close_failed=1; capture=$(cat "$AUDIT_CAPTURE")"
grep -q '^AUDIT ORCH_LOOP OPERATOR_AUTHORIZATION_REQUIRED cycle=9 project=auto-close-test reason=close-failed-hook issues=#602' \
  "$AUDIT_CAPTURE" \
  || fail "expected OPERATOR_AUTHORIZATION_REQUIRED audit row listing #602; capture=$(cat "$AUDIT_CAPTURE")"

[[ -f "$QUEUE_PATH" ]] \
  || fail "apply-mode close_failed must append to intervention_queue.md; missing $QUEUE_PATH"
grep -q '| #602 |' "$QUEUE_PATH" \
  || fail "intervention_queue.md must contain a row for #602; queue=$(cat "$QUEUE_PATH")"
grep -q 'issue_close_rc=80' "$QUEUE_PATH" \
  || fail "intervention_queue.md row must surface the rc=80 hook reason; queue=$(cat "$QUEUE_PATH")"

# Scenario 3c: ORCH_AUTO_CLOSE_MODE=off → step skips, never calls the
# lib, never writes the ledger.
rm -f "$CLOSE_LEDGER" "$AUDIT_CAPTURE" "$PLAN_INVOC_LOG" \
  "$AUTO_CLOSE_INVOC_LOG" "$QUEUE_PATH"
run_step 11 "$CLOSE_LEDGER" "$PLAN_FILE" "$AUTO_CLOSE_OUTPUT" \
  "$AUDIT_CAPTURE" "$PLAN_INVOC_LOG" "$AUTO_CLOSE_INVOC_LOG" \
  "$QUEUE_PATH" "off" 1

if [[ -s "$AUTO_CLOSE_INVOC_LOG" ]]; then
  fail "mode=off must not invoke auto_close_shipped_suspect.sh; log=$(cat "$AUTO_CLOSE_INVOC_LOG")"
fi
if [[ -s "$PLAN_INVOC_LOG" ]]; then
  fail "mode=off must short-circuit before reading the plan; log=$(cat "$PLAN_INVOC_LOG")"
fi
grep -q '^AUDIT AUTO_CLOSE skip cycle=11 project=auto-close-test reason=mode-off$' \
  "$AUDIT_CAPTURE" \
  || fail "expected mode-off skip audit row; capture=$(cat "$AUDIT_CAPTURE")"
[[ ! -e "$CLOSE_LEDGER" ]] \
  || fail "mode=off must not append to the ledger; ledger=$(cat "$CLOSE_LEDGER")"

# Scenario 3d: clean plan (no shipped_suspect rows) → step skips with
# reason=no-shipped-suspect and never invokes the auto-close lib.
rm -f "$CLOSE_LEDGER" "$AUDIT_CAPTURE" "$PLAN_INVOC_LOG" \
  "$AUTO_CLOSE_INVOC_LOG" "$QUEUE_PATH"
cat > "$PLAN_FILE" <<'JSON'
[
  {"issue":801,"status":"ready","priority":"P1"},
  {"issue":802,"status":"atomize","priority":"P2"}
]
JSON
run_step 13 "$CLOSE_LEDGER" "$PLAN_FILE" "$AUTO_CLOSE_OUTPUT" \
  "$AUDIT_CAPTURE" "$PLAN_INVOC_LOG" "$AUTO_CLOSE_INVOC_LOG" \
  "$QUEUE_PATH" "dry-run" 1

if [[ -s "$AUTO_CLOSE_INVOC_LOG" ]]; then
  fail "clean plan must not invoke auto_close_shipped_suspect.sh; log=$(cat "$AUTO_CLOSE_INVOC_LOG")"
fi
grep -q '^AUDIT AUTO_CLOSE skip cycle=13 project=auto-close-test reason=no-shipped-suspect shipped_suspect=0$' \
  "$AUDIT_CAPTURE" \
  || fail "expected no-shipped-suspect skip audit row; capture=$(cat "$AUDIT_CAPTURE")"

# Scenario 3e: hourly cap exhausted → step skips and reports the cap
# without re-invoking the auto-close lib.
rm -f "$CLOSE_LEDGER" "$AUDIT_CAPTURE" "$PLAN_INVOC_LOG" \
  "$AUTO_CLOSE_INVOC_LOG" "$QUEUE_PATH"
cat > "$PLAN_FILE" <<'JSON'
[{"issue":901,"status":"shipped_suspect","priority":"P1"}]
JSON
mkdir -p "$(dirname "$CLOSE_LEDGER")"
printf '%s 1 dry-run 1\n' "$(date +%s)" >> "$CLOSE_LEDGER"

run_step 15 "$CLOSE_LEDGER" "$PLAN_FILE" "$AUTO_CLOSE_OUTPUT" \
  "$AUDIT_CAPTURE" "$PLAN_INVOC_LOG" "$AUTO_CLOSE_INVOC_LOG" \
  "$QUEUE_PATH" "dry-run" 1

if [[ -s "$AUTO_CLOSE_INVOC_LOG" ]]; then
  fail "hourly-cap-exhausted must not invoke auto_close_shipped_suspect.sh; log=$(cat "$AUTO_CLOSE_INVOC_LOG")"
fi
grep -q '^AUDIT AUTO_CLOSE skip cycle=15 project=auto-close-test reason=hourly-cap-exhausted cap=1$' \
  "$AUDIT_CAPTURE" \
  || fail "expected hourly-cap-exhausted skip audit row; capture=$(cat "$AUDIT_CAPTURE")"
ledger_lines=$(wc -l < "$CLOSE_LEDGER" | tr -d ' ')
[[ "$ledger_lines" == "1" ]] \
  || fail "skip path must not append to the ledger; got $ledger_lines lines: $(cat "$CLOSE_LEDGER")"

# --- 4. Boot wiring sanity ------------------------------------------------
# The helpers exist; confirm the boot path actually calls the step
# inside the main loop body so a future refactor cannot silently
# disconnect Phase A — and that the opt-out gate is honoured.
# shellcheck disable=SC2016 # patterns match literal `"$cycle"` tokens inside orch_loop.sh, not shell expansions here.
grep -q 'orch_auto_close_step "\$cycle"' "$ROOT/scripts/orch_loop.sh" \
  || fail "orch_loop.sh main loop must invoke orch_auto_close_step \"\$cycle\""
grep -q 'ORCH_AUTO_CLOSE_DISABLED' "$ROOT/scripts/orch_loop.sh" \
  || fail "orch_loop.sh must honour ORCH_AUTO_CLOSE_DISABLED opt-out"
# shellcheck disable=SC2016  # literal ${...} pattern grep, expansion intentionally suppressed
grep -q ': "${ORCH_AUTO_CLOSE_MODE:=dry-run}"' "$ROOT/scripts/orch_loop.sh" \
  || fail "orch_loop.sh must default ORCH_AUTO_CLOSE_MODE to dry-run for safe rollout"
# shellcheck disable=SC2016  # literal ${...} pattern grep, expansion intentionally suppressed
grep -q ': "${ORCH_AUTO_CLOSE_MAX_PER_HOUR:=1}"' "$ROOT/scripts/orch_loop.sh" \
  || fail "orch_loop.sh must default ORCH_AUTO_CLOSE_MAX_PER_HOUR to 1"

printf 'ok - orch_loop auto-close step wires shipped_suspect drain with ORCH_AUTO_CLOSE_MAX_PER_HOUR cap and OPERATOR_AUTHORIZATION_REQUIRED escape hatch (#770)\n'
