#!/usr/bin/env bash
# tests/test_orch_loop_softblock_rebalance.sh — cycle-level coverage for the
# Issue #757 soft-block detection + rebalance step wired into
# scripts/orch_loop.sh.
#
# The unit-level classifier is covered by tests/test_agent_softblock.sh.
# This test focuses on the orch_loop integration:
#   1. orch_loop.sh sources lib/agent_softblock.sh and invokes the
#      rebalance step inside the cycle body.
#   2. agent_softblock_run_rebalance_step emits exactly one
#      REBALANCE_REQUIRED audit row when at least one soft-blocked agent
#      and at least one idle agent are visible.
#   3. The same step appends exactly one row per soft-blocked agent to
#      `<state_dir>/intervention_queue.md`.
#   4. With only idle agents (no soft-block), no REBALANCE_REQUIRED row
#      is emitted but a structured SOFTBLOCK_SCAN row records the
#      decision.
#   5. With only soft-blocked agents (no idle capacity), the rebalance is
#      withheld and the structured SOFTBLOCK_SCAN row records
#      `decision=no_idle_capacity`.
#   6. ORCH_SOFTBLOCK_DISABLED=1 short-circuits the step entirely.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP=$(mktemp -d)
SANITIZED_ROOT="$TEST_TMP/toolkit"

cleanup() {
  rm -rf "$TEST_TMP"
}
trap cleanup EXIT

fail() {
  printf 'not ok - %s\n' "$*" >&2
  exit 1
}

# shellcheck source=../lib/test_sanitize.sh
source "$ROOT/lib/test_sanitize.sh"
sanitize_toolkit_copy "$SANITIZED_ROOT" \
  scripts/orch_loop.sh

# --- 1. orch_loop sources lib/agent_softblock.sh + invokes the step --------
loop_sh="$SANITIZED_ROOT/scripts/orch_loop.sh"
[ -s "$loop_sh" ] || fail "sanitized orch_loop.sh missing"
# shellcheck disable=SC2016  # we grep for the literal "$TK" and "$PROJECT" tokens inside orch_loop.sh; single quotes are required.
grep -q 'source "\$TK/lib/agent_softblock.sh"' "$loop_sh" \
  || fail "orch_loop.sh must source lib/agent_softblock.sh"
# shellcheck disable=SC2016  # we grep for the literal "$PROJECT" token inside orch_loop.sh; single quotes are required.
grep -q 'agent_softblock_run_rebalance_step "\$PROJECT"' "$loop_sh" \
  || fail "orch_loop.sh must invoke agent_softblock_run_rebalance_step in the cycle"

# --- 2/3. soft-blocked + idle → REBALANCE_REQUIRED + queue row -------------
STATE_DIR="$TEST_TMP/state/orch-loop-test"
mkdir -p "$STATE_DIR"

# fake assignments.json: one soft-blocked agent (agent-004 on #240) and the
# idle agents carry no assignment row, which is exactly the rebalance
# target.
cat > "$STATE_DIR/assignments.json" <<'JSON'
{
  "agent-004": {
    "issue": 240,
    "branch": "feat/issue-240",
    "workdir": "/work/agent-004"
  }
}
JSON

PANE_DIR="$TEST_TMP/panes"
mkdir -p "$PANE_DIR"
cat > "$PANE_DIR/agent-004.pane" <<'PANE'
$ git status
On branch feat/issue-240
Current worktree state: clean tree on feat/issue-240 at 578fd2e plus the uncommitted SC2034 fix in lib/sixsigma_config.sh. Nothing pushed. No PR opened. Recommendation for the dispatcher: the docs/sixsigma/README.md neutrality breach needs to be resolved on main...
$
PANE
cat > "$PANE_DIR/agent-001.pane" <<'PANE'
$
$
$ pwd
/work/agent-001
$
PANE
cat > "$PANE_DIR/agent-002.pane" <<'PANE'
$
$
$ pwd
/work/agent-002
$
PANE

run_rebalance_in_subshell() {
  local audit_log=$1
  local state_dir=$2
  local extra_env=${3:-}
  (
    set -euo pipefail
    : > "$audit_log"
    # shellcheck disable=SC1090
    source "$SANITIZED_ROOT/lib/agent_softblock.sh"
    audit() {
      printf 'AUDIT %s\n' "$*" >> "$audit_log"
    }
    audit_action() {
      local action=$1; shift
      audit "$action $*"
    }
    # Fake fleet roster — the function reads agent_inventory_entries by line.
    agent_inventory_entries() {
      printf 'agent-004|%s|/work/agent-004\n' "$PANE_DIR/agent-004.pane"
      printf 'agent-001|%s|/work/agent-001\n' "$PANE_DIR/agent-001.pane"
      printf 'agent-002|%s|/work/agent-002\n' "$PANE_DIR/agent-002.pane"
    }
    if [ -n "$extra_env" ]; then
      eval "$extra_env"
    fi
    agent_softblock_run_rebalance_step orch-loop-test "$state_dir"
  )
}

AUDIT_LOG="$TEST_TMP/audit.log"
run_rebalance_in_subshell "$AUDIT_LOG" "$STATE_DIR"

reb_count=$(grep -c 'ORCH_LOOP_REBALANCE_REQUIRED' "$AUDIT_LOG" || true)
[ "$reb_count" -eq 1 ] || fail "expected exactly one REBALANCE_REQUIRED row, got: $reb_count audit_log:$(cat "$AUDIT_LOG")"

grep -q 'reason=soft_blocked_capacity_waste' "$AUDIT_LOG" \
  || fail "REBALANCE_REQUIRED must encode reason=soft_blocked_capacity_waste"
grep -q 'idle_agents=agent-001,agent-002' "$AUDIT_LOG" \
  || fail "REBALANCE_REQUIRED must list the idle agents, audit_log:$(cat "$AUDIT_LOG")"
grep -q 'soft_blocked=agent-004#240' "$AUDIT_LOG" \
  || fail "REBALANCE_REQUIRED must list soft_blocked agent#ticket, audit_log:$(cat "$AUDIT_LOG")"

queue="$STATE_DIR/intervention_queue.md"
[ -s "$queue" ] || fail "intervention_queue.md must exist after a soft-block+idle cycle"
grep -q '^# ORDO intervention queue$' "$queue" \
  || fail "intervention_queue.md must declare the canonical header"
queue_rows=$(grep -cE '^\| 20[0-9][0-9]-' "$queue")
[ "$queue_rows" -eq 1 ] || fail "exactly one data row expected, got: $queue_rows"
grep -E '^\| 20' "$queue" | grep -q 'agent-004' \
  || fail "queue row must reference the soft-blocked agent label"
grep -E '^\| 20' "$queue" | grep -q '| 240 |' \
  || fail "queue row must carry the ticket number"
grep -E '^\| 20' "$queue" | grep -q 'Recommendation for the dispatcher' \
  || fail "queue row must carry the blocker excerpt"
grep -E '^\| 20' "$queue" | grep -q 'agent-001,agent-002' \
  || fail "queue recommendation must reference the idle pool"

# A second invocation must append another row (operator drain semantics).
run_rebalance_in_subshell "$AUDIT_LOG" "$STATE_DIR"
queue_rows=$(grep -cE '^\| 20[0-9][0-9]-' "$queue")
[ "$queue_rows" -eq 2 ] || fail "soft-block persistence must accumulate rows, got: $queue_rows"

# --- 4. idle-only fleet → SOFTBLOCK_SCAN no_softblock, no REBALANCE --------
STATE_DIR2="$TEST_TMP/state/idle-only"
mkdir -p "$STATE_DIR2"
PANE_DIR2="$TEST_TMP/panes_idle"
mkdir -p "$PANE_DIR2"
cat > "$PANE_DIR2/agent-001.pane" <<'PANE'
$
$ pwd
/work/agent-001
$
PANE
cat > "$PANE_DIR2/agent-002.pane" <<'PANE'
$
PANE

(
  set -euo pipefail
  : > "$TEST_TMP/audit_idle.log"
  # shellcheck disable=SC1090
  source "$SANITIZED_ROOT/lib/agent_softblock.sh"
  audit() {
    printf 'AUDIT %s\n' "$*" >> "$TEST_TMP/audit_idle.log"
  }
  audit_action() {
    local action=$1; shift
    audit "$action $*"
  }
  agent_inventory_entries() {
    printf 'agent-001|%s|/work/agent-001\n' "$PANE_DIR2/agent-001.pane"
    printf 'agent-002|%s|/work/agent-002\n' "$PANE_DIR2/agent-002.pane"
  }
  agent_softblock_run_rebalance_step orch-loop-test "$STATE_DIR2"
)

if grep -q 'ORCH_LOOP_REBALANCE_REQUIRED' "$TEST_TMP/audit_idle.log"; then
  fail "REBALANCE_REQUIRED must NOT fire when no agent is soft-blocked"
fi
grep -q 'ORCH_LOOP_SOFTBLOCK_SCAN' "$TEST_TMP/audit_idle.log" \
  || fail "SOFTBLOCK_SCAN audit row missing for idle-only fleet"
grep -q 'decision=no_softblock' "$TEST_TMP/audit_idle.log" \
  || fail "idle-only fleet must record decision=no_softblock"
if [ -f "$STATE_DIR2/intervention_queue.md" ]; then
  fail "intervention_queue.md must NOT be created when no agent is soft-blocked"
fi

# --- 5. soft-block only, no idle capacity → SOFTBLOCK_SCAN no_idle_capacity
STATE_DIR3="$TEST_TMP/state/no-idle"
mkdir -p "$STATE_DIR3"
cat > "$STATE_DIR3/assignments.json" <<'JSON'
{
  "agent-004": {"issue": 240, "branch": "feat/issue-240", "workdir": "/work/agent-004"},
  "agent-005": {"issue": 250, "branch": "feat/issue-250", "workdir": "/work/agent-005"}
}
JSON
PANE_DIR3="$TEST_TMP/panes_no_idle"
mkdir -p "$PANE_DIR3"
cat > "$PANE_DIR3/agent-004.pane" <<'PANE'
Recommendation for the dispatcher: fix README on main first.
$
PANE
cat > "$PANE_DIR3/agent-005.pane" <<'PANE'
[feat/issue-250 abc1234] feat(250): wip
 1 file changed, 1 insertion(+)
$ git push origin HEAD
To https://github.com/example/repo.git
   abc1234..def5678  feat/issue-250 -> feat/issue-250
$
PANE

(
  set -euo pipefail
  : > "$TEST_TMP/audit_no_idle.log"
  # shellcheck disable=SC1090
  source "$SANITIZED_ROOT/lib/agent_softblock.sh"
  audit() {
    printf 'AUDIT %s\n' "$*" >> "$TEST_TMP/audit_no_idle.log"
  }
  audit_action() {
    local action=$1; shift
    audit "$action $*"
  }
  agent_inventory_entries() {
    printf 'agent-004|%s|/work/agent-004\n' "$PANE_DIR3/agent-004.pane"
    printf 'agent-005|%s|/work/agent-005\n' "$PANE_DIR3/agent-005.pane"
  }
  agent_softblock_run_rebalance_step orch-loop-test "$STATE_DIR3"
)

if grep -q 'ORCH_LOOP_REBALANCE_REQUIRED' "$TEST_TMP/audit_no_idle.log"; then
  fail "REBALANCE_REQUIRED must NOT fire when no idle agent is available"
fi
grep -q 'decision=no_idle_capacity' "$TEST_TMP/audit_no_idle.log" \
  || fail "soft-block-without-idle must record decision=no_idle_capacity"
if [ -f "$STATE_DIR3/intervention_queue.md" ]; then
  fail "intervention_queue.md must NOT be created when no idle capacity exists"
fi

# --- 6. ORCH_SOFTBLOCK_DISABLED=1 short-circuits the step ------------------
STATE_DIR4="$TEST_TMP/state/disabled"
mkdir -p "$STATE_DIR4"
cp "$STATE_DIR/assignments.json" "$STATE_DIR4/assignments.json"
(
  set -euo pipefail
  : > "$TEST_TMP/audit_disabled.log"
  # shellcheck disable=SC1090
  source "$SANITIZED_ROOT/lib/agent_softblock.sh"
  audit() {
    printf 'AUDIT %s\n' "$*" >> "$TEST_TMP/audit_disabled.log"
  }
  audit_action() {
    local action=$1; shift
    audit "$action $*"
  }
  agent_inventory_entries() {
    printf 'agent-004|%s|/work/agent-004\n' "$PANE_DIR/agent-004.pane"
    printf 'agent-001|%s|/work/agent-001\n' "$PANE_DIR/agent-001.pane"
  }
  ORCH_SOFTBLOCK_DISABLED=1 \
    agent_softblock_run_rebalance_step orch-loop-test "$STATE_DIR4"
)
if [ -s "$TEST_TMP/audit_disabled.log" ]; then
  fail "ORCH_SOFTBLOCK_DISABLED=1 must produce no audit rows, got: $(cat "$TEST_TMP/audit_disabled.log")"
fi
if [ -f "$STATE_DIR4/intervention_queue.md" ]; then
  fail "ORCH_SOFTBLOCK_DISABLED=1 must not create the intervention queue"
fi

printf 'ok - orch_loop soft-block detection + rebalance integration\n'
