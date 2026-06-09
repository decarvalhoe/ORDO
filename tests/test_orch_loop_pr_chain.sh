#!/usr/bin/env bash
# Issue #791: deterministic merge-ready -> cleanup -> refreshed ready plan
# chain in orch_loop.sh.
#
# The test extracts only the PR-chain helpers from orch_loop.sh so the
# daemon boot guard is bypassed. Fake child commands record invocations,
# which lets the assertions prove the loop drains exactly the merge-ready
# PRs, leaves checks-missing alone, refreshes portfolio state, and records
# refused controller decisions once with a next_action.
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

mkdir -p "$TEST_TMP/logs" "$TEST_TMP/state/pr-chain-test" \
  "$TEST_TMP/toolkit/scripts" "$TEST_TMP/toolkit/lib"

HELPERS_SH="$TEST_TMP/orch_pr_chain_helpers.sh"
awk '
  /^orch_pr_chain_detail\(\) \{/              { in_fn = 1 }
  /^orch_pr_chain_blocker_ledger\(\) \{/      { in_fn = 1 }
  /^orch_pr_chain_decision_ledger\(\) \{/     { in_fn = 1 }
  /^orch_pr_chain_next_action\(\) \{/         { in_fn = 1 }
  /^orch_pr_chain_record_blocker\(\) \{/      { in_fn = 1 }
  /^orch_pr_chain_gates_for_record\(\) \{/    { in_fn = 1 }
  /^orch_pr_chain_refresh_after_merges\(\) \{/ { in_fn = 1 }
  /^orch_pr_chain_step\(\) \{/                { in_fn = 1 }
  in_fn { print }
  in_fn && /^\}$/                              { in_fn = 0 }
' "$ROOT/scripts/orch_loop.sh" > "$HELPERS_SH"
[[ -s "$HELPERS_SH" ]] \
  || fail "failed to extract orch_pr_chain_* helpers from orch_loop.sh"

for fn in \
  orch_pr_chain_detail \
  orch_pr_chain_blocker_ledger \
  orch_pr_chain_decision_ledger \
  orch_pr_chain_next_action \
  orch_pr_chain_record_blocker \
  orch_pr_chain_gates_for_record \
  orch_pr_chain_refresh_after_merges \
  orch_pr_chain_step
do
  grep -q "^${fn}() {" "$HELPERS_SH" \
    || fail "extracted helpers missing ${fn}"
done

FAKE_TK="$TEST_TMP/toolkit"

cat > "$FAKE_TK/scripts/pr_block_signals.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cat "${FAKE_PR_SIGNALS:?FAKE_PR_SIGNALS required}"
EOF
chmod +x "$FAKE_TK/scripts/pr_block_signals.sh"

cat > "$FAKE_TK/scripts/pr_ops_controller.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${FAKE_CONTROLLER_LOG:?FAKE_CONTROLLER_LOG required}"
pr=$3
case "${FAKE_CONTROLLER_MODE:-allowed}" in
  allowed)
    jq -nc --arg pr "$pr" \
      '{action:"merge",mode:"centralized",actor:"operator",required_gates:["ci","review"],passed_gates:["ci","review","merge-ready"],decision:"allowed",reason:"operator_authorized",pr:$pr,project:"pr-chain-test"}'
    ;;
  refused)
    jq -nc --arg pr "$pr" \
      '{action:"merge",mode:"centralized",actor:"operator",required_gates:["ci","review"],passed_gates:["ci"],decision:"refused",reason:"missing_required_gate",pr:$pr,project:"pr-chain-test"}'
    exit 91
    ;;
esac
EOF
chmod +x "$FAKE_TK/scripts/pr_ops_controller.sh"

cat > "$FAKE_TK/lib/pr_merge.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s PR_MERGE_POST_CLEANUP=%s\n' "$*" "${PR_MERGE_POST_CLEANUP:-unset}" >> "${FAKE_MERGE_LOG:?FAKE_MERGE_LOG required}"
EOF
chmod +x "$FAKE_TK/lib/pr_merge.sh"

cat > "$FAKE_TK/scripts/post_merge_cleanup.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${FAKE_CLEANUP_LOG:?FAKE_CLEANUP_LOG required}"
EOF
chmod +x "$FAKE_TK/scripts/post_merge_cleanup.sh"

cat > "$FAKE_TK/scripts/portfolio_session_start.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${FAKE_SESSION_LOG:?FAKE_SESSION_LOG required}"
printf '[]\n'
EOF
chmod +x "$FAKE_TK/scripts/portfolio_session_start.sh"

cat > "$FAKE_TK/scripts/portfolio_status.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${FAKE_STATUS_LOG:?FAKE_STATUS_LOG required}"
printf '[]\n'
EOF
chmod +x "$FAKE_TK/scripts/portfolio_status.sh"

cat > "$FAKE_TK/scripts/dispatch_plan.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${FAKE_PLAN_LOG:?FAKE_PLAN_LOG required}"
cat "${FAKE_READY_PLAN:?FAKE_READY_PLAN required}"
EOF
chmod +x "$FAKE_TK/scripts/dispatch_plan.sh"

run_chain_step() {
  local cycle=$1
  bash -c '
    set -euo pipefail
    HELPERS_SH=$1
    FAKE_TK=$2
    STATE_DIR=$3
    RUN_NOW=$4
    CYCLE=$5
    state_dir() { printf "%s\n" "$STATE_DIR"; }
    audit() { printf "AUDIT %s\n" "$*" >> "${FAKE_AUDIT_LOG:?FAKE_AUDIT_LOG required}"; }
    orch_run_timeout() { local _seconds=$1; shift; "$@"; }
    TK="$FAKE_TK"
    PROJECT_ARG="pr-chain-test"
    PROJECT="pr-chain-test"
    RUN_NOW_FLAG="$RUN_NOW"
    source "$HELPERS_SH"
    orch_pr_chain_step "$CYCLE"
  ' _ "$HELPERS_SH" "$FAKE_TK" "$TEST_TMP/state/pr-chain-test" \
      "$TEST_TMP/state/pr-chain-test/run_now" "$cycle"
}

PR_SIGNALS="$TEST_TMP/pr-signals.json"
READY_PLAN="$TEST_TMP/ready-plan.json"
AUDIT_LOG="$TEST_TMP/logs/audit.log"
CONTROLLER_LOG="$TEST_TMP/logs/controller.log"
MERGE_LOG="$TEST_TMP/logs/merge.log"
CLEANUP_LOG="$TEST_TMP/logs/cleanup.log"
SESSION_LOG="$TEST_TMP/logs/session.log"
STATUS_LOG="$TEST_TMP/logs/status.log"
PLAN_LOG="$TEST_TMP/logs/plan.log"
RUN_NOW="$TEST_TMP/state/pr-chain-test/run_now"

cat > "$READY_PLAN" <<'JSON'
[
  {"issue":801,"status":"ready","conflict_with":[]},
  {"issue":802,"status":"blocked","conflict_with":[700]}
]
JSON

cat > "$PR_SIGNALS" <<'JSON'
[
  {"pr":"101","branch":"feat/one","signals":["ci-pass","merge-ready"]},
  {"pr":"102","branch":"feat/two","signals":["ci-pass","merge-ready"]},
  {"pr":"103","branch":"feat/three","signals":["ci-pass","merge-ready"]},
  {"pr":"104","branch":"feat/no-checks","signals":["checks-missing"]}
]
JSON

export FAKE_PR_SIGNALS="$PR_SIGNALS"
export FAKE_READY_PLAN="$READY_PLAN"
export FAKE_AUDIT_LOG="$AUDIT_LOG"
export FAKE_CONTROLLER_LOG="$CONTROLLER_LOG"
export FAKE_MERGE_LOG="$MERGE_LOG"
export FAKE_CLEANUP_LOG="$CLEANUP_LOG"
export FAKE_SESSION_LOG="$SESSION_LOG"
export FAKE_STATUS_LOG="$STATUS_LOG"
export FAKE_PLAN_LOG="$PLAN_LOG"

rm -f "$AUDIT_LOG" "$CONTROLLER_LOG" "$MERGE_LOG" "$CLEANUP_LOG" \
  "$SESSION_LOG" "$STATUS_LOG" "$PLAN_LOG" "$RUN_NOW"

FAKE_CONTROLLER_MODE=allowed ORCH_PR_CHAIN_MAX_PER_CYCLE=10 run_chain_step 9

[[ "$(wc -l < "$CONTROLLER_LOG" | tr -d ' ')" == "3" ]] \
  || fail "controller should be consulted for exactly 3 merge-ready PRs: $(cat "$CONTROLLER_LOG")"
[[ "$(wc -l < "$MERGE_LOG" | tr -d ' ')" == "3" ]] \
  || fail "merge should run for exactly 3 merge-ready PRs: $(cat "$MERGE_LOG")"
[[ "$(wc -l < "$CLEANUP_LOG" | tr -d ' ')" == "3" ]] \
  || fail "cleanup should run for exactly 3 merged PRs: $(cat "$CLEANUP_LOG")"

grep -q '^pr-chain-test 101 PR_MERGE_POST_CLEANUP=0$' "$MERGE_LOG" \
  || fail "merge helper must disable internal cleanup so chain cleanup is explicit: $(cat "$MERGE_LOG")"
grep -q '^pr-chain-test 101 --tsv --assume-merged --merged-branch feat/one$' "$CLEANUP_LOG" \
  || fail "cleanup must receive the merged branch for PR 101: $(cat "$CLEANUP_LOG")"
if grep -q '104' "$CONTROLLER_LOG" "$MERGE_LOG" "$CLEANUP_LOG"; then
  fail "checks-missing PR 104 must not enter controller/merge/cleanup"
fi

grep -q '^pr-chain-test --apply --json$' "$SESSION_LOG" \
  || fail "portfolio_session_start must refresh after merge cleanup: $(cat "$SESSION_LOG")"
grep -q '^pr-chain-test --json$' "$STATUS_LOG" \
  || fail "portfolio_status must rerun after merge cleanup: $(cat "$STATUS_LOG")"
grep -q '^pr-chain-test --ready-only --json$' "$PLAN_LOG" \
  || fail "dispatch_plan --ready-only must rerun after merge cleanup: $(cat "$PLAN_LOG")"
[[ -f "$RUN_NOW" ]] \
  || fail "run-now flag should be set when refreshed ready plan has dispatchable rows"
grep -q 'ORCH_LOOP PR_CHAIN_REFRESHED cycle=9 project=pr-chain-test merged_count=3 ready_count=1 action=run_next_cycle' "$AUDIT_LOG" \
  || fail "missing refreshed ready-count audit row: $(cat "$AUDIT_LOG")"

# Refusal scenario: the controller returns a durable policy refusal. The
# helper must not merge, must append one blocker with next_action, and must
# not append duplicate blocker rows for the same PR/reason on the next cycle.
cat > "$PR_SIGNALS" <<'JSON'
[
  {"pr":"201","branch":"feat/refused","signals":["ci-pass","merge-ready"]}
]
JSON
rm -f "$CONTROLLER_LOG" "$MERGE_LOG" "$CLEANUP_LOG" "$RUN_NOW" \
  "$TEST_TMP/state/pr-chain-test/pr_chain_blockers.jsonl"

FAKE_CONTROLLER_MODE=refused run_chain_step 10
FAKE_CONTROLLER_MODE=refused run_chain_step 11

[[ ! -s "$MERGE_LOG" ]] \
  || fail "refused controller decision must not invoke merge: $(cat "$MERGE_LOG")"
blocker_ledger="$TEST_TMP/state/pr-chain-test/pr_chain_blockers.jsonl"
[[ -s "$blocker_ledger" ]] \
  || fail "refused decision should create a blocker ledger"
[[ "$(wc -l < "$blocker_ledger" | tr -d ' ')" == "1" ]] \
  || fail "duplicate refusal should not append another blocker row: $(cat "$blocker_ledger")"
jq -e '
  .pr == "201"
  and .reason == "missing_required_gate"
  and (.next_action | test("Satisfy PR ops gates"))
' "$blocker_ledger" >/dev/null \
  || fail "blocker ledger must include next_action: $(cat "$blocker_ledger")"

printf 'ok - orch_loop drains merge-ready PR chain and records durable refusals\n'
