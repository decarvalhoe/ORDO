#!/usr/bin/env bash
# tests/test_orch_loop_single_orchestrator.sh — regression coverage for #669.
# shellcheck disable=SC2034,SC2178,SC2317
#
# Validates the single-orchestrator-per-portfolio enforcement wired into
# scripts/orch_loop.sh and lib/portfolio_config.sh.
#
#   1. portfolio_orchestrator_slot_from_path derives fleet-NNN / agent-NNN
#      labels from absolute paths, returning non-zero for unrelated paths.
#   2. portfolio_orchestrator_canonical_slot / _allowed_slots / _slot_allowed
#      honour PORTFOLIO_ORCHESTRATOR_SLOT and PORTFOLIO_OPERATOR_SLOTS_EXTRA.
#   3. portfolio_orchestrator_processes scans a synthetic /proc via
#      ORCH_PROC_DIR and only returns matches for the requested project,
#      ignoring unrelated processes and orchestrators for other projects.
#   4. portfolio_orchestrator_drift_report classifies allowed vs disallowed
#      slots, returns non-zero when drift exists, and surfaces pid, slot,
#      cwd, command line, and a recommended cleanup action that explicitly
#      preserves uncommitted work and avoids killing worker tasks.
#   5. orch_loop.sh's require_single_orchestrator + orch_loop_self_slot
#      helpers (extracted in-place so the test does not pay the cost of a
#      full daemon boot) refuse on a disallowed slot AND on a competing
#      peer orchestrator on a disallowed slot, while allowing the canonical
#      operator slot when no peer is present.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP=$(mktemp -d)
PROC_DIR="$TEST_TMP/proc"

cleanup() {
  rm -rf "$TEST_TMP"
}
trap cleanup EXIT

fail() {
  printf 'not ok - %s\n' "$*" >&2
  exit 1
}

mkdir -p "$PROC_DIR" "$TEST_TMP/logs" "$TEST_TMP/state"

# Source the portfolio helpers once in the main shell and reuse across all
# helper-unit sections to avoid one subshell + bash startup per assertion.
# shellcheck source=../lib/portfolio_config.sh
source "$ROOT/lib/portfolio_config.sh"

ORCH_PROC_DIR="$PROC_DIR"
export ORCH_PROC_DIR

# --- 1. portfolio_orchestrator_slot_from_path -----------------------------
got=$(portfolio_orchestrator_slot_from_path '/root/repos/fleet-000') \
  || fail 'slot_from_path /root/repos/fleet-000 returned non-zero'
[[ "$got" == "fleet-000" ]] \
  || fail "expected fleet-000, got '$got'"

got=$(portfolio_orchestrator_slot_from_path '/root/repos/fleet-011/work/sub') \
  || fail 'slot_from_path /root/repos/fleet-011/... returned non-zero'
[[ "$got" == "fleet-011" ]] \
  || fail "expected deepest fleet-011, got '$got'"

got=$(portfolio_orchestrator_slot_from_path '/workspace/agent-007') \
  || fail 'slot_from_path /workspace/agent-007 returned non-zero'
[[ "$got" == "agent-007" ]] \
  || fail "expected agent-007, got '$got'"

if portfolio_orchestrator_slot_from_path '/tmp/nowhere/here' 2>/dev/null; then
  fail 'slot_from_path should fail on unrelated paths'
fi

# --- 2. canonical + allowed slots + allowed predicate ---------------------
got=$(portfolio_orchestrator_canonical_slot)
[[ "$got" == "fleet-000" ]] \
  || fail "default canonical slot expected fleet-000, got '$got'"

got=$(PORTFOLIO_ORCHESTRATOR_SLOT='ops-prime' portfolio_orchestrator_canonical_slot)
[[ "$got" == "ops-prime" ]] \
  || fail "PORTFOLIO_ORCHESTRATOR_SLOT override failed, got '$got'"

declare -a PORTFOLIO_OPERATOR_SLOTS_EXTRA=("fleet-099" "fleet-000" "ops-aux" "")
got=$(portfolio_orchestrator_allowed_slots | sort | paste -sd ',' -)
[[ "$got" == "fleet-000,fleet-099,ops-aux" ]] \
  || fail "array extras: expected fleet-000,fleet-099,ops-aux got '$got'"
unset PORTFOLIO_OPERATOR_SLOTS_EXTRA

PORTFOLIO_OPERATOR_SLOTS_EXTRA='fleet-099 ops-aux'
got=$(portfolio_orchestrator_allowed_slots | sort | paste -sd ',' -)
[[ "$got" == "fleet-000,fleet-099,ops-aux" ]] \
  || fail "string extras: expected fleet-000,fleet-099,ops-aux got '$got'"
unset PORTFOLIO_OPERATOR_SLOTS_EXTRA

portfolio_orchestrator_slot_allowed fleet-000 \
  || fail 'fleet-000 must be allowed by default'
if portfolio_orchestrator_slot_allowed fleet-011; then
  fail 'fleet-011 must NOT be allowed by default'
fi

declare -a PORTFOLIO_OPERATOR_SLOTS_EXTRA=("fleet-011")
portfolio_orchestrator_slot_allowed fleet-011 \
  || fail 'fleet-011 must be allowed after PORTFOLIO_OPERATOR_SLOTS_EXTRA opt-in'
unset PORTFOLIO_OPERATOR_SLOTS_EXTRA

# --- 3. /proc scan returns only matching orchestrators --------------------
make_fake_proc_entry() {
  local pid=$1 cwd=$2
  shift 2
  local pid_dir="$PROC_DIR/$pid"
  mkdir -p "$pid_dir" "$cwd"
  local arg
  : > "$pid_dir/cmdline"
  for arg in "$@"; do
    printf '%s\0' "$arg" >> "$pid_dir/cmdline"
  done
  ln -sfn "$cwd" "$pid_dir/cwd"
}

mkdir -p "$TEST_TMP/fleet-000" "$TEST_TMP/fleet-011" "$TEST_TMP/random"

make_fake_proc_entry 1001 "$TEST_TMP/fleet-000" \
  /bin/bash "$ROOT/scripts/orch_loop.sh" testproj --daemon-confirm op
make_fake_proc_entry 2001 "$TEST_TMP/fleet-011" \
  /bin/bash scripts/orch_loop.sh testproj
make_fake_proc_entry 3001 "$TEST_TMP/fleet-000" \
  /bin/bash scripts/orch_loop.sh otherproj
make_fake_proc_entry 4001 "$TEST_TMP/random" \
  /usr/bin/sleep 999

mapfile -t rows < <(portfolio_orchestrator_processes testproj)
pid_list=$(printf '%s\n' "${rows[@]}" | cut -d'|' -f1 | sort | tr '\n' ',')
[[ "$pid_list" == "1001,2001," ]] \
  || fail "expected pids 1001+2001 only, got: $pid_list"

mapfile -t rows < <(portfolio_orchestrator_processes testproj 1001)
pid_list=$(printf '%s\n' "${rows[@]}" | cut -d'|' -f1 | sort | tr '\n' ',')
[[ "$pid_list" == "2001," ]] \
  || fail "expected exclude-pid filter to drop 1001, got: $pid_list"

# --- 4. drift report classifies, returns non-zero, surfaces evidence ------
set +e
report=$(portfolio_orchestrator_drift_report testproj)
drift_rc=$?
set -e

[[ "$drift_rc" -ne 0 ]] \
  || fail "drift_report should return non-zero when drift exists; report=$report"
[[ "$report" == *"orchestrator_drift project=testproj"* ]] \
  || fail "report should include header line: $report"
[[ "$report" == *"allowed_slots=fleet-000"* ]] \
  || fail "report should declare allowed_slots: $report"
[[ "$report" == *"ok pid=1001"* ]] \
  || fail "report should mark pid 1001 as ok: $report"
[[ "$report" == *"slot=fleet-000"* ]] \
  || fail "report should record slot fleet-000 for pid 1001: $report"
[[ "$report" == *"drift pid=2001"* ]] \
  || fail "report should mark pid 2001 as drift: $report"
[[ "$report" == *"slot=fleet-011"* ]] \
  || fail "report should record slot fleet-011 for pid 2001: $report"
[[ "$report" == *"cwd=$TEST_TMP/fleet-011"* ]] \
  || fail "report should record cwd for the stray pid: $report"
[[ "$report" == *"orch_loop.sh testproj"* ]] \
  || fail "report should record the cmdline: $report"
[[ "$report" == *"recommended="* ]] \
  || fail "report must include a recommended cleanup action: $report"
[[ "$report" == *"do NOT kill worker implementation tasks"* ]] \
  || fail "recommended cleanup must explicitly preserve worker tasks: $report"

# Grant fleet-011 explicitly: drift should disappear in the same snapshot.
declare -a PORTFOLIO_OPERATOR_SLOTS_EXTRA=("fleet-011")
set +e
portfolio_orchestrator_drift_report testproj >/dev/null
drift_rc=$?
set -e
unset PORTFOLIO_OPERATOR_SLOTS_EXTRA
[[ "$drift_rc" -eq 0 ]] \
  || fail "drift_report must accept explicitly-granted extra operator slot"

# Remove the drift entry and confirm the report goes clean.
rm -rf "$PROC_DIR/2001"
set +e
portfolio_orchestrator_drift_report testproj >/dev/null
clean_rc=$?
set -e
[[ "$clean_rc" -eq 0 ]] \
  || fail "drift_report should succeed when only the canonical orchestrator runs"

# Restore the drift entry for section 5.
make_fake_proc_entry 2001 "$TEST_TMP/fleet-011" \
  /bin/bash scripts/orch_loop.sh single-orch-test

# --- 5. orch_loop.sh boot guard (extracted helpers) -----------------------
# Booting the full orch_loop.sh daemon would source ~10 libs and pay ~20s
# of subprocess startup cost on busy hosts, which can push the 120s
# validation budget over. Mirror the test_orch_loop_clean_stop.sh pattern:
# extract require_single_orchestrator + orch_loop_self_slot from
# scripts/orch_loop.sh into a helper file and exercise them directly. The
# boot guard is one call site away from the helper so the extracted check
# proves the dispatch surface.

HELPERS_SH="$TEST_TMP/orch_loop_helpers.sh"
awk '
  /^orch_loop_self_slot\(\) \{/        { in_fn = 1 }
  /^require_single_orchestrator\(\) \{/ { in_fn = 1 }
  in_fn { print }
  in_fn && /^\}$/                       { in_fn = 0 }
' "$ROOT/scripts/orch_loop.sh" > "$HELPERS_SH"
[[ -s "$HELPERS_SH" ]] \
  || fail "failed to extract require_single_orchestrator/orch_loop_self_slot from orch_loop.sh"

# Stub audit() so we can inspect the audit line in a string instead of
# tee-ing into ORCH_LOG_DIR/PROJECT.log, which keeps the test free of
# state_dir / config-load preconditions.
run_guard() {
  local self_dir=$1
  shift
  local audit_capture rc
  audit_capture=$(mktemp)
  set +e
  out=$( {
    set -e
    export ORCH_PROC_DIR="$PROC_DIR"
    # shellcheck disable=SC1090
    source "$ROOT/lib/portfolio_config.sh"
    # audit() must exist before sourcing the helpers because
    # require_single_orchestrator references it.
    audit() { printf 'AUDIT %s\n' "$*" >> "$audit_capture"; }
    PROJECT="single-orch-test"
    TK="$ROOT"
    cd "$self_dir"
    # shellcheck disable=SC1090
    source "$HELPERS_SH"
    require_single_orchestrator
    printf 'OK\n'
  } 2>&1 )
  rc=$?
  set -e
  printf '%s\n' "$out"
  printf -- '--AUDIT--\n%s\n' "$(cat "$audit_capture")"
  rm -f "$audit_capture"
  return "$rc"
}

# Case A — booted from a disallowed slot (fleet-011) with no peers.
rm -rf "$PROC_DIR/2001"
set +e
caseA=$(run_guard "$TEST_TMP/fleet-011")
caseA_rc=$?
set -e
[[ "$caseA_rc" -eq 14 ]] \
  || fail "case A: expected rc=14 for disallowed self slot, got $caseA_rc; out=$caseA"
[[ "$caseA" == *"refused to start"* ]] \
  || fail "case A: refusal text missing: $caseA"
[[ "$caseA" == *"#669"* ]] \
  || fail "case A: refusal should cite #669: $caseA"
[[ "$caseA" == *"self_slot     = fleet-011"* ]] \
  || fail "case A: self_slot field missing: $caseA"
[[ "$caseA" == *"reason=disallowed-orchestrator-slot"* ]] \
  || fail "case A: audit must include reason=disallowed-orchestrator-slot: $caseA"

# Case B — booted from the canonical slot, but a competing orchestrator is
# present on a disallowed slot. The guard must still refuse and embed the
# drift report (pid + slot + cmd + recommended cleanup).
make_fake_proc_entry 2001 "$TEST_TMP/fleet-011" \
  /bin/bash scripts/orch_loop.sh single-orch-test
set +e
caseB=$(run_guard "$TEST_TMP/fleet-000")
caseB_rc=$?
set -e
[[ "$caseB_rc" -eq 14 ]] \
  || fail "case B: expected rc=14 for competing peer, got $caseB_rc; out=$caseB"
[[ "$caseB" == *"competing orchestrator"* ]] \
  || fail "case B: refusal must name the competing orchestrator: $caseB"
[[ "$caseB" == *"drift pid=2001"* ]] \
  || fail "case B: drift report must embed pid=2001: $caseB"
[[ "$caseB" == *"slot=fleet-011"* ]] \
  || fail "case B: drift report must record peer slot: $caseB"
[[ "$caseB" == *"recommended="* ]] \
  || fail "case B: drift report must surface a cleanup recommendation: $caseB"
[[ "$caseB" == *"do NOT kill worker implementation tasks"* ]] \
  || fail "case B: cleanup recommendation must preserve worker tasks: $caseB"
[[ "$caseB" == *"reason=competing-orchestrator"* ]] \
  || fail "case B: audit must include reason=competing-orchestrator: $caseB"

# Case C — canonical slot, no competing peers: guard accepts and OK fires.
rm -rf "$PROC_DIR/2001"
set +e
caseC=$(run_guard "$TEST_TMP/fleet-000")
caseC_rc=$?
set -e
[[ "$caseC_rc" -eq 0 ]] \
  || fail "case C: expected rc=0 when alone on the canonical slot, got $caseC_rc; out=$caseC"
[[ "$caseC" == *"OK"* ]] \
  || fail "case C: guard should fall through to OK marker: $caseC"
[[ "$caseC" == *"single orchestrator ok"* ]] \
  || fail "case C: audit must record the OK path: $caseC"

# Case D — ORCH_FLEET_SLOT override is honoured.
set +e
caseD=$(ORCH_FLEET_SLOT="fleet-000" run_guard "$TEST_TMP/random")
caseD_rc=$?
set -e
[[ "$caseD_rc" -eq 0 ]] \
  || fail "case D: ORCH_FLEET_SLOT override should grant boot, got $caseD_rc; out=$caseD"

printf 'ok - orch_loop enforces single orchestrator per portfolio (#669)\n'
