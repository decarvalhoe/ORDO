#!/usr/bin/env bash
# test_capacity_busy_claim_gate.sh — runtime enforcement coverage for
# the capacity busy-claim gate (#283).
#
# PR #299 derived `capacity_report.busy_claim_valid` from structured
# state. This suite covers the runtime gate that PR #299 deliberately
# left for a follow-up: the orchestrator narrative must be able to
# CALL a refusal path that exits non-zero when the busy claim would be
# false. The fixture replays the 2026-05-08 incident shape — three
# free ORDO agents + two stale RBOK assignment records pointing at
# parkable PR owners — and asserts the gate refuses with code 87 and
# names the offending aliases in the audit line.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP=$(mktemp -d)
SANITIZED_ROOT="$TEST_TMP/toolkit"

cleanup() { rm -rf "$TEST_TMP"; }
trap cleanup EXIT

fail() { printf 'not ok - %s\n' "$*" >&2; exit 1; }

mkdir -p "$TEST_TMP/logs" "$TEST_TMP/state" "$TEST_TMP/fixtures"

# shellcheck source=../lib/test_sanitize.sh
source "$ROOT/lib/test_sanitize.sh"
sanitize_toolkit_copy "$SANITIZED_ROOT" \
  scripts/capacity_busy_claim_gate.sh

chmod +x "$SANITIZED_ROOT/scripts/capacity_busy_claim_gate.sh"

# Stub portfolio_config — capacity_busy_claim_gate sources it but our
# fixture path skips the portfolio_status.sh fork, so we just need an
# empty placeholder that won't error on source.
cat > "$TEST_TMP/portfolio.config.sh" <<'EOF'
PORTFOLIO_NAME="capacity-busy-claim-gate-test"
PORTFOLIO_PROJECTS=()
EOF

# Reusable invocation — the fixture flag bypasses portfolio_status.sh
# so the test pins the gate's own logic against synthetic inputs.
gate_run() {
  local fixture=$1
  shift
  PROJECT="capacity-busy-claim-test" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  AGENT_WORKDIR_TEMPLATE="$TEST_TMP/agents/%s" \
  bash "$SANITIZED_ROOT/scripts/capacity_busy_claim_gate.sh" \
    "$TEST_TMP/portfolio.config.sh" \
    --portfolio-json "$fixture" \
    "$@"
}

# --- fixture 1: 2026-05-08 incident shape (false-busy claim) -------------

cat > "$TEST_TMP/fixtures/incident.json" <<'JSON'
[
  {
    "alias": "ordo",
    "capacity_report": {
      "alias": "ordo",
      "configured_slots": 11,
      "free_pane_ready": ["copilot","cursor","orch"],
      "free_pane_ready_count": 3,
      "dispatch_parkable": [],
      "switchable": [],
      "switchable_count": 0,
      "panes_with_work_count": 8,
      "parkable_pr_owners": [],
      "supervisor_sessions_count": 0,
      "busy_claim_valid": false,
      "evidence_sources": {
        "assignments_path": "/state/ordo/assignments.json",
        "portfolio_status": "scripts/portfolio_status.sh",
        "agent_inventory": "lib/agent_inventory.sh"
      }
    }
  },
  {
    "alias": "rbok",
    "capacity_report": {
      "alias": "rbok",
      "configured_slots": 9,
      "free_pane_ready": ["claude","gemini","ops","ux"],
      "free_pane_ready_count": 4,
      "dispatch_parkable": [],
      "switchable": [
        {"agent":"cursor","issue":3173,"source":"parkable-pr"},
        {"agent":"copilot","issue":3174,"source":"parkable-pr"}
      ],
      "switchable_count": 2,
      "panes_with_work_count": 1,
      "parkable_pr_owners": ["cursor","copilot"],
      "supervisor_sessions_count": 1,
      "busy_claim_valid": false,
      "evidence_sources": {
        "assignments_path": "/state/rbok/assignments.json",
        "portfolio_status": "scripts/portfolio_status.sh",
        "agent_inventory": "lib/agent_inventory.sh"
      }
    }
  }
]
JSON

# Default mode: prints the rollup, exit 0 (inspect-only, no enforcement).
out=$(gate_run "$TEST_TMP/fixtures/incident.json" 2>&1)
[[ "$out" == *"capacity_busy_claim verdict=false"* ]] \
  || fail "default rollup must surface verdict=false (got: $out)"
[[ "$out" == *"alias=ordo"* ]] || fail "rollup must include ordo line"
[[ "$out" == *"alias=rbok"* ]] || fail "rollup must include rbok line"

# Strict mode: exit 87, structured audit emitted.
log_file="$TEST_TMP/logs/capacity-busy-claim-test.log"
: > "$log_file"
set +e
out=$(gate_run "$TEST_TMP/fixtures/incident.json" --require-busy-claim-valid --context wave_dispatch 2>&1)
status=$?
set -e
[[ "$status" -eq 87 ]] \
  || fail "strict mode must exit 87 on incident fixture (got: $status, output: $out)"
grep -q "CAPACITY_BUSY_CLAIM action=refuse verdict=false" "$log_file" \
  || fail "audit must record action=refuse verdict=false"
grep -q "context=wave_dispatch" "$log_file" \
  || fail "audit must propagate context tag"
grep -q "free_total=7" "$log_file" \
  || fail "audit must total free_pane_ready across projects (got: $(cat "$log_file"))"
grep -q "switchable_total=2" "$log_file" \
  || fail "audit must total switchable across projects"
grep -q "refusing_aliases=ordo,rbok" "$log_file" \
  || fail "audit must name refusing aliases"

# JSON mode: exit 87 + JSON document on stdout carrying refusal punch list.
set +e
json_out=$(gate_run "$TEST_TMP/fixtures/incident.json" --require-busy-claim-valid --json 2>/dev/null)
status=$?
set -e
[[ "$status" -eq 87 ]] || fail "json mode must keep the strict exit code"
echo "$json_out" | jq -e '.busy_claim_valid == false' >/dev/null \
  || fail "json rollup must expose busy_claim_valid=false"
echo "$json_out" | jq -e '.refusals | length == 2' >/dev/null \
  || fail "json rollup must expose 2 refusals"
echo "$json_out" | jq -e '.refusals[] | select(.alias == "rbok") | .switchable | length == 2' >/dev/null \
  || fail "rbok refusal entry must include the 2 switchable agents"
echo "$json_out" | jq -e '.refusals[] | select(.alias == "ordo") | .free_pane_ready == ["copilot","cursor","orch"]' >/dev/null \
  || fail "ordo refusal entry must list the 3 free panes"

# --- fixture 2: portfolio fully busy (gate must accept) -------------------

cat > "$TEST_TMP/fixtures/all_busy.json" <<'JSON'
[
  {
    "alias": "ordo",
    "capacity_report": {
      "alias": "ordo",
      "configured_slots": 11,
      "free_pane_ready": [],
      "free_pane_ready_count": 0,
      "dispatch_parkable": [],
      "switchable": [],
      "switchable_count": 0,
      "panes_with_work_count": 11,
      "parkable_pr_owners": [],
      "supervisor_sessions_count": 1,
      "busy_claim_valid": true,
      "evidence_sources": {"assignments_path":"/state/ordo/assignments.json","portfolio_status":"scripts/portfolio_status.sh","agent_inventory":"lib/agent_inventory.sh"}
    }
  },
  {
    "alias": "rbok",
    "capacity_report": {
      "alias": "rbok",
      "configured_slots": 9,
      "free_pane_ready": [],
      "free_pane_ready_count": 0,
      "dispatch_parkable": [],
      "switchable": [],
      "switchable_count": 0,
      "panes_with_work_count": 9,
      "parkable_pr_owners": [],
      "supervisor_sessions_count": 0,
      "busy_claim_valid": true,
      "evidence_sources": {"assignments_path":"/state/rbok/assignments.json","portfolio_status":"scripts/portfolio_status.sh","agent_inventory":"lib/agent_inventory.sh"}
    }
  }
]
JSON

: > "$log_file"
out=$(gate_run "$TEST_TMP/fixtures/all_busy.json" --require-busy-claim-valid --context wave_dispatch 2>&1)
[[ "$out" == *"capacity_busy_claim verdict=true"* ]] \
  || fail "all-busy rollup must surface verdict=true (got: $out)"
grep -q "CAPACITY_BUSY_CLAIM action=assert verdict=true" "$log_file" \
  || fail "all-busy fixture must emit action=assert verdict=true"

# --- fixture 3: only one project flips (refusal points at that alias) ----

cat > "$TEST_TMP/fixtures/partial_busy.json" <<'JSON'
[
  {
    "alias": "ordo",
    "capacity_report": {
      "alias": "ordo",
      "configured_slots": 11,
      "free_pane_ready": ["copilot"],
      "free_pane_ready_count": 1,
      "dispatch_parkable": [],
      "switchable": [],
      "switchable_count": 0,
      "panes_with_work_count": 10,
      "parkable_pr_owners": [],
      "supervisor_sessions_count": 0,
      "busy_claim_valid": false,
      "evidence_sources": {"assignments_path":"/state/ordo/assignments.json","portfolio_status":"scripts/portfolio_status.sh","agent_inventory":"lib/agent_inventory.sh"}
    }
  },
  {
    "alias": "rbok",
    "capacity_report": {
      "alias": "rbok",
      "configured_slots": 9,
      "free_pane_ready": [],
      "free_pane_ready_count": 0,
      "dispatch_parkable": [],
      "switchable": [],
      "switchable_count": 0,
      "panes_with_work_count": 9,
      "parkable_pr_owners": [],
      "supervisor_sessions_count": 0,
      "busy_claim_valid": true,
      "evidence_sources": {"assignments_path":"/state/rbok/assignments.json","portfolio_status":"scripts/portfolio_status.sh","agent_inventory":"lib/agent_inventory.sh"}
    }
  }
]
JSON

: > "$log_file"
set +e
gate_run "$TEST_TMP/fixtures/partial_busy.json" --require-busy-claim-valid --context wave_dispatch >/dev/null 2>&1
status=$?
set -e
[[ "$status" -eq 87 ]] || fail "single-project flip must still refuse (got: $status)"
grep -q "refusing_aliases=ordo$" "$log_file" \
  || fail "audit must name only the refusing alias (got: $(cat "$log_file"))"

# --- fixture 4: empty portfolio (no projects → no claim → refuse) --------
# Defensive contract: an empty rollup cannot validate "all agents busy"
# because there are no projects to evaluate. Refuse so the orchestrator
# does not narrate from a degenerate state.

printf '[]\n' > "$TEST_TMP/fixtures/empty.json"
set +e
gate_run "$TEST_TMP/fixtures/empty.json" --require-busy-claim-valid >/dev/null 2>&1
status=$?
set -e
[[ "$status" -eq 87 ]] || fail "empty portfolio must refuse the busy claim (got: $status)"

# --- fixture 5: --json mode on accept path (rollup keys present) ---------

set +e
json_out=$(gate_run "$TEST_TMP/fixtures/all_busy.json" --json --require-busy-claim-valid 2>/dev/null)
status=$?
set -e
[[ "$status" -eq 0 ]] || fail "all-busy fixture must exit 0 in json mode (got: $status)"
echo "$json_out" | jq -e '.schema_version == "ordo.capacity_busy_claim.v1"' >/dev/null \
  || fail "rollup must declare schema_version"
echo "$json_out" | jq -e '.busy_claim_valid == true and .free_pane_ready_total == 0' >/dev/null \
  || fail "all-busy rollup totals incorrect (got: $json_out)"

# --- unknown arg rejected -------------------------------------------------

set +e
gate_run "$TEST_TMP/fixtures/all_busy.json" --bogus >/dev/null 2>&1
status=$?
set -e
[[ "$status" -eq 2 ]] || fail "unknown arg should exit 2 (got: $status)"

printf 'ok - capacity_busy_claim_gate refuses incident shape and surfaces structured evidence\n'
