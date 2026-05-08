#!/usr/bin/env bash
# tests/test_recovery_context.sh — coverage for ORDO #362.
#
# `lib/recovery_context.sh` MUST capture a fresh proof of an agent
# workdir's destructive state before the orchestrator authorizes a
# `git rebase --abort` / `git merge --abort` / reset / clean / external
# workdir edit, and MUST refuse the action when the proof is older than
# `ORCH_RECOVERY_PROOF_MAX_AGE_SEC`, when the live workdir state no
# longer matches the proof, when agent ownership has drifted, or when
# the proof was captured against a different workdir.
#
# AC fixtures (from issue #362):
#   1. stale dirty-state — proof captured a dirty workdir, the workdir
#      has since been cleaned. Destructive action must be refused with
#      RECOVERY_PROOF_STALE / state_drift.
#   2. clean workdir + still-conflicting PR — local clone is clean
#      (proof says destructive=false), but the PR still reports
#      CONFLICTING. The proof MUST surface the PR mergeability in a
#      separate field so the operator can tell "no local action needed"
#      from "PR still blocked".
#   3. active unmerged workdir — workdir still has MERGE_HEAD and the
#      proof matches. Destructive action is authorized; the proof
#      remains valid.
#   4. missing/changed agent ownership — between proof capture and
#      validation, assignments.json was rewritten (agent preempted, or
#      assignment cleared). Destructive action must be refused with
#      ownership_drift.
#
# A 5th fixture covers stale-by-age: a proof older than the configured
# max age must be refused even if the live state still matches.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP=$(mktemp -d)

cleanup() { rm -rf "$TEST_TMP"; }
trap cleanup EXIT

fail() {
  printf 'not ok - %s\n' "$*" >&2
  exit 1
}

assert_eq() {
  local actual=$1 expected=$2 label=${3:-equality check}
  if [[ "$actual" != "$expected" ]]; then
    fail "$label: expected=$expected actual=$actual"
  fi
}

# Per-fixture isolation: each `setup_fixture` call wipes the shared
# environment (state dir, log dir, gh stub) so AC scenarios cannot
# accidentally inherit a previous fixture's assignment ledger or
# proof artifacts.
setup_fixture() {
  local agent=${1:?usage: setup_fixture <agent>}
  local issue=${2:?usage: setup_fixture <agent> <issue>}
  local fix_dir="$TEST_TMP/fixtures/${agent}-${issue}"
  rm -rf "$fix_dir"
  mkdir -p "$fix_dir/log" "$fix_dir/state/recovery-test" \
           "$fix_dir/work/$agent" "$fix_dir/bin"

  cat > "$fix_dir/bin/gh" <<'GH'
#!/usr/bin/env bash
# Mock `gh pr view`: emits the canned mergeability JSON written to
# RECOVERY_TEST_GH_PR_JSON for the current fixture, or unknown when the
# var is empty (matches the production `gh pr view --json` schema).
if [[ "${1:-}" == "pr" && "${2:-}" == "view" ]]; then
  if [[ -n "${RECOVERY_TEST_GH_PR_JSON:-}" ]]; then
    printf '%s\n' "$RECOVERY_TEST_GH_PR_JSON"
  else
    printf '{"mergeable":"UNKNOWN","mergeStateStatus":"UNKNOWN","state":"OPEN","updatedAt":""}\n'
  fi
  exit 0
fi
exit 0
GH
  chmod +x "$fix_dir/bin/gh"

  printf '%s' "$fix_dir"
}

# Source the recovery_context library inside a per-fixture environment.
# Functions and side-channel state are exported into the calling shell
# so the test can assert against them directly.
load_recovery_context_for() {
  local fix_dir=$1
  PROJECT="recovery-test"
  ORCH_LOG_DIR="$fix_dir/log"
  ORCH_STATE_BASE="$fix_dir/state"
  GH_REPO="example/recovery"
  GH_CONFIG_DIR="$fix_dir/gh"
  AGENT_WORKDIR_TEMPLATE="$fix_dir/work/%s"
  AGENT_REPO_PREFIX="$fix_dir/work/"
  AGENT_SESSION_PREFIX=""
  DEFAULT_BRANCH="main"
  PATH="$fix_dir/bin:$PATH"
  export PROJECT ORCH_LOG_DIR ORCH_STATE_BASE GH_REPO GH_CONFIG_DIR \
    AGENT_WORKDIR_TEMPLATE AGENT_REPO_PREFIX AGENT_SESSION_PREFIX \
    DEFAULT_BRANCH PATH
  mkdir -p "$GH_CONFIG_DIR"

  # Re-source so each fixture starts with a clean cache of side-channel
  # state and a clean ORCH_LOG_DIR.
  # shellcheck disable=SC1090,SC1091
  source "$ROOT/lib/audit_log.sh"
  # shellcheck disable=SC1090,SC1091
  source "$ROOT/lib/state_persist.sh"
  # shellcheck disable=SC1090,SC1091
  source "$ROOT/lib/recovery_context.sh"
}

write_assignment() {
  # write_assignment <agent> <issue> <workdir>
  local agent=$1 issue=$2 workdir=$3
  state_update assignments \
    ". + {\"$agent\": {\"issue\": $issue, \"workdir\": \"$workdir\"}}"
}

# ---------------------------------------------------------------------------
# AC#362-1 — stale dirty-state.
#
# Capture a proof while the workdir has uncommitted work, then `git
# checkout -- .` to clean it. Validation must refuse with
# state_drift / drifted=porcelain_hash because the live porcelain hash
# no longer matches the proof.
# ---------------------------------------------------------------------------
fix_dir=$(setup_fixture "stale-dirty" 100)
load_recovery_context_for "$fix_dir"
agent="stale-dirty"
workdir="$fix_dir/work/$agent"
git -C "$workdir" init -q
git -C "$workdir" config user.email "stale-dirty@test.local"
git -C "$workdir" config user.name "RBOKCLIstale-dirty"
git -C "$workdir" checkout -b main >/dev/null 2>&1
printf 'seed\n' > "$workdir/seed.txt"
git -C "$workdir" add seed.txt
git -C "$workdir" commit -q -m "seed"

# Make the workdir dirty BEFORE capturing the proof.
printf 'in-flight\n' >> "$workdir/seed.txt"
write_assignment "$agent" 100 "$workdir"

recovery_context_capture "$workdir" --agent "$agent" --ticket 100 \
  --reason "matrix_workdir_not_ready:dirty" >/dev/null
proof="$RECOVERY_CONTEXT_PROOF_PATH"
[[ -f "$proof" ]] || fail "AC1: proof file not created"
assert_eq "$RECOVERY_CONTEXT_PROOF_DESTRUCTIVE" "1" "AC1: proof must mark destructive=1"

# Operator/agent has since cleaned the workdir.
git -C "$workdir" checkout -- seed.txt
porcelain=$(git -C "$workdir" status --porcelain | wc -l | tr -d ' ')
assert_eq "$porcelain" "0" "AC1: workdir should be clean after checkout"

set +e
recovery_context_assert_fresh "$proof" "$workdir"
rc=$?
set -e
assert_eq "$rc" "88" "AC1: stale dirty-state must exit ORCH_RECOVERY_PROOF_STALE_EXIT_CODE (88)"
[[ "$RECOVERY_CONTEXT_VALIDATE_REASON" == "state_drift" ]] \
  || fail "AC1: expected reason=state_drift, got $RECOVERY_CONTEXT_VALIDATE_REASON"
[[ "$RECOVERY_CONTEXT_VALIDATE_DETAIL" == *"porcelain_hash"* ]] \
  || fail "AC1: expected drifted=porcelain_hash in detail, got $RECOVERY_CONTEXT_VALIDATE_DETAIL"
grep -q 'RECOVERY_PROOF_STALE' "$ORCH_LOG_DIR/recovery-test.log" \
  || fail "AC1: refusal must be audit-logged"

# ---------------------------------------------------------------------------
# AC#362-2 — clean workdir with still-conflicting PR.
#
# The local clone is clean: the proof must record destructive=false so
# downstream code does not authorize a destructive recovery on a clean
# tree. The PR mergeability is captured as a SEPARATE field so an
# operator can still see the PR is conflicting and route the work to
# PR-state monitoring instead of a local destructive action.
# ---------------------------------------------------------------------------
fix_dir=$(setup_fixture "clean-conflict-pr" 200)
load_recovery_context_for "$fix_dir"
agent="clean-conflict-pr"
workdir="$fix_dir/work/$agent"
git -C "$workdir" init -q
git -C "$workdir" config user.email "clean-conflict@test.local"
git -C "$workdir" config user.name "RBOKCLIclean-conflict"
git -C "$workdir" checkout -b main >/dev/null 2>&1
printf 'seed\n' > "$workdir/seed.txt"
git -C "$workdir" add seed.txt
git -C "$workdir" commit -q -m "seed"
write_assignment "$agent" 200 "$workdir"

# Mock `gh pr view` to report the PR is still CONFLICTING. The JSON
# string is read literally — shellcheck SC2089/SC2090 about quote
# handling do not apply here because the value is exported as-is and
# the gh stub re-emits it via `printf '%s\n' "$VAR"`.
# shellcheck disable=SC2089,SC2090
RECOVERY_TEST_GH_PR_JSON='{"mergeable":"CONFLICTING","mergeStateStatus":"DIRTY","state":"OPEN","updatedAt":"2026-05-08T13:38:00Z"}'
# shellcheck disable=SC2090
export RECOVERY_TEST_GH_PR_JSON

recovery_context_capture "$workdir" --agent "$agent" --ticket 200 \
  --pr 200 --reason "matrix_workdir_check" >/dev/null
proof="$RECOVERY_CONTEXT_PROOF_PATH"
assert_eq "$RECOVERY_CONTEXT_PROOF_DESTRUCTIVE" "0" \
  "AC2: clean workdir must record destructive=0 (no local destructive recovery needed)"

# AC: "Local clone state and GitHub PR mergeability are reported
# separately." Read both fields from the proof and assert the local
# state says "no destructive needed" while the PR mergeability still
# says CONFLICTING — proving the proof keeps the two signals separate.
local_dirty=$(jq -r '.local_state.porcelain_count' "$proof")
pr_merge=$(jq -r '.pr_status.mergeable' "$proof")
pr_status=$(jq -r '.pr_status.mergeStateStatus' "$proof")
assert_eq "$local_dirty" "0" "AC2: local_state.porcelain_count must be 0"
assert_eq "$pr_merge" "CONFLICTING" "AC2: pr_status.mergeable must surface PR conflict"
assert_eq "$pr_status" "DIRTY" "AC2: pr_status.mergeStateStatus must be reported separately"

# Validate the proof: still-clean workdir → fresh proof, no destructive
# action would be authorized regardless of PR state.
set +e
recovery_context_assert_fresh "$proof" "$workdir"
rc=$?
set -e
assert_eq "$rc" "0" "AC2: clean-state proof must validate while local stays clean"
unset RECOVERY_TEST_GH_PR_JSON

# ---------------------------------------------------------------------------
# AC#362-3 — active unmerged workdir.
#
# The workdir genuinely has MERGE_HEAD and unmerged files. The proof
# captures the destructive state. Validation against the same state
# returns 0, authorizing the destructive recovery (e.g. merge --abort).
# ---------------------------------------------------------------------------
fix_dir=$(setup_fixture "active-unmerged" 300)
load_recovery_context_for "$fix_dir"
agent="active-unmerged"
workdir="$fix_dir/work/$agent"
git -C "$workdir" init -q
git -C "$workdir" config user.email "active-unmerged@test.local"
git -C "$workdir" config user.name "RBOKCLIactive-unmerged"
git -C "$workdir" checkout -b main >/dev/null 2>&1
printf 'base\n' > "$workdir/conflict.txt"
git -C "$workdir" add conflict.txt
git -C "$workdir" commit -q -m "base"
git -C "$workdir" checkout -b branch-a >/dev/null 2>&1
printf 'branch-a\n' > "$workdir/conflict.txt"
git -C "$workdir" commit -aq -m "branch-a"
git -C "$workdir" checkout main >/dev/null 2>&1
printf 'main-edit\n' > "$workdir/conflict.txt"
git -C "$workdir" commit -aq -m "main-edit"
# Force a merge that conflicts to leave MERGE_HEAD + unmerged file.
git -C "$workdir" merge branch-a >/dev/null 2>&1 || true
test -e "$workdir/.git/MERGE_HEAD" || fail "AC3: MERGE_HEAD must exist after conflicting merge"
unmerged=$(git -C "$workdir" diff --name-only --diff-filter=U | wc -l | tr -d ' ')
[[ "$unmerged" -gt 0 ]] || fail "AC3: workdir must have unmerged files"

write_assignment "$agent" 300 "$workdir"
recovery_context_capture "$workdir" --agent "$agent" --ticket 300 \
  --reason "matrix_workdir_not_ready:in_progress_op" >/dev/null
proof="$RECOVERY_CONTEXT_PROOF_PATH"
assert_eq "$RECOVERY_CONTEXT_PROOF_DESTRUCTIVE" "1" \
  "AC3: unmerged workdir must record destructive=1"
assert_eq "$RECOVERY_CONTEXT_PROOF_IN_PROGRESS" "MERGE_HEAD" \
  "AC3: in_progress marker must be MERGE_HEAD"

# Validate the proof against the same unmerged state.
set +e
recovery_context_assert_fresh "$proof" "$workdir"
rc=$?
set -e
assert_eq "$rc" "0" "AC3: fresh proof on still-unmerged workdir must validate"

# ---------------------------------------------------------------------------
# AC#362-4 — missing/changed agent ownership.
#
# Capture a proof while agent X owns issue #400 with workdir W. Between
# proof and validation, an operator preempts agent X and re-assigns the
# workdir to agent Y on issue #401. The validator must refuse with
# ownership_drift so the orchestrator does not authorize a destructive
# action against a workdir whose owning agent has changed.
# ---------------------------------------------------------------------------
fix_dir=$(setup_fixture "ownership-drift" 400)
load_recovery_context_for "$fix_dir"
agent="ownership-drift"
workdir="$fix_dir/work/$agent"
git -C "$workdir" init -q
git -C "$workdir" config user.email "owner@test.local"
git -C "$workdir" config user.name "RBOKCLIownership-drift"
git -C "$workdir" checkout -b main >/dev/null 2>&1
printf 'seed\n' > "$workdir/seed.txt"
git -C "$workdir" add seed.txt
git -C "$workdir" commit -q -m "seed"
# Leave the workdir dirty so destructive=1 — the entire reason we
# would consider authorizing a recovery in the first place.
printf 'still-in-flight\n' >> "$workdir/seed.txt"

write_assignment "$agent" 400 "$workdir"
recovery_context_capture "$workdir" --agent "$agent" --ticket 400 \
  --reason "matrix_workdir_not_ready:dirty" >/dev/null
proof="$RECOVERY_CONTEXT_PROOF_PATH"
assert_eq "$RECOVERY_CONTEXT_PROOF_DESTRUCTIVE" "1" \
  "AC4: dirty workdir must record destructive=1"

# Operator preempts the agent — assignments.json is rewritten so the
# agent now owns a different issue (or none). Use the strongest signal:
# clear the assignment entirely.
state_update assignments ". | del(.\"$agent\")"

set +e
recovery_context_assert_fresh "$proof" "$workdir"
rc=$?
set -e
assert_eq "$rc" "88" \
  "AC4: ownership drift must exit ORCH_RECOVERY_PROOF_STALE_EXIT_CODE (88)"
assert_eq "$RECOVERY_CONTEXT_VALIDATE_REASON" "ownership_drift" \
  "AC4: reason must be ownership_drift"
[[ "$RECOVERY_CONTEXT_VALIDATE_DETAIL" == *"proof_issue=400"* ]] \
  || fail "AC4: detail must surface the proof's recorded issue, got $RECOVERY_CONTEXT_VALIDATE_DETAIL"
[[ "$RECOVERY_CONTEXT_VALIDATE_DETAIL" == *"live_issue=none"* ]] \
  || fail "AC4: detail must surface the live (cleared) issue, got $RECOVERY_CONTEXT_VALIDATE_DETAIL"

# ---------------------------------------------------------------------------
# AC mirror — stale-by-age.
#
# Even if the local state still matches, a proof older than
# ORCH_RECOVERY_PROOF_MAX_AGE_SEC must be refused. The issue's
# expected behavior includes "If the refreshed state no longer proves
# the local destructive action is needed, ORDO must withdraw the
# request" — and a stale-age proof IS one whose freshness can no
# longer be vouched for.
# ---------------------------------------------------------------------------
fix_dir=$(setup_fixture "stale-age" 500)
load_recovery_context_for "$fix_dir"
agent="stale-age"
workdir="$fix_dir/work/$agent"
git -C "$workdir" init -q
git -C "$workdir" config user.email "age@test.local"
git -C "$workdir" config user.name "RBOKCLIstale-age"
git -C "$workdir" checkout -b main >/dev/null 2>&1
printf 'seed\n' > "$workdir/seed.txt"
git -C "$workdir" add seed.txt
git -C "$workdir" commit -q -m "seed"
printf 'in-flight\n' >> "$workdir/seed.txt"
write_assignment "$agent" 500 "$workdir"

ORCH_RECOVERY_PROOF_MAX_AGE_SEC=2 \
  recovery_context_capture "$workdir" --agent "$agent" --ticket 500 \
    --reason "matrix_workdir_not_ready:dirty" >/dev/null
proof="$RECOVERY_CONTEXT_PROOF_PATH"
sleep 3

set +e
ORCH_RECOVERY_PROOF_MAX_AGE_SEC=2 \
  recovery_context_assert_fresh "$proof" "$workdir"
rc=$?
set -e
assert_eq "$rc" "88" "AC age: stale-by-age must exit 88"
assert_eq "$RECOVERY_CONTEXT_VALIDATE_REASON" "stale_age" \
  "AC age: reason must be stale_age"

# ---------------------------------------------------------------------------
# AC mirror — workdir mismatch.
#
# A proof for /repos/copilot must NOT validate against /repos/cursor.
# Same Wave-23 leak pattern (#376) refused on the recovery surface —
# the proof's workdir field is part of the freshness contract.
# ---------------------------------------------------------------------------
fix_dir=$(setup_fixture "workdir-mismatch" 600)
load_recovery_context_for "$fix_dir"
agent="workdir-mismatch"
workdir_a="$fix_dir/work/$agent"
workdir_b="$fix_dir/work/${agent}-other"
mkdir -p "$workdir_b"
git -C "$workdir_a" init -q
git -C "$workdir_a" config user.email "wmis@test.local"
git -C "$workdir_a" config user.name "RBOKCLIworkdir-mismatch"
git -C "$workdir_a" checkout -b main >/dev/null 2>&1
printf 'seed\n' > "$workdir_a/seed.txt"
git -C "$workdir_a" add seed.txt
git -C "$workdir_a" commit -q -m "seed"
printf 'in-flight\n' >> "$workdir_a/seed.txt"
git -C "$workdir_b" init -q
git -C "$workdir_b" config user.email "wmis-other@test.local"
git -C "$workdir_b" config user.name "RBOKCLIworkdir-mismatch-other"
git -C "$workdir_b" checkout -b main >/dev/null 2>&1
printf 'other\n' > "$workdir_b/seed.txt"
git -C "$workdir_b" add seed.txt
git -C "$workdir_b" commit -q -m "other"

write_assignment "$agent" 600 "$workdir_a"
recovery_context_capture "$workdir_a" --agent "$agent" --ticket 600 >/dev/null
proof="$RECOVERY_CONTEXT_PROOF_PATH"

set +e
recovery_context_assert_fresh "$proof" "$workdir_b"
rc=$?
set -e
assert_eq "$rc" "88" "workdir mismatch must exit 88"
assert_eq "$RECOVERY_CONTEXT_VALIDATE_REASON" "workdir_mismatch" \
  "workdir mismatch reason must be workdir_mismatch"

printf 'ok - test_recovery_context\n'
