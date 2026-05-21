#!/usr/bin/env bash
# tests/test_reclaim_orphan_assignments.sh - issue #764
#
# Verifies scripts/reclaim_orphan_assignments.sh:
#   - --dry-run lists every orphan assignee (assignee NOT in
#     AGENT_GH_LOGINS) without mutating GitHub
#   - --apply unassigns idle orphans and emits the structured
#     RECLAIM_ORPHAN_ASSIGNMENT audit event
#   - active-login assignees and recently-touched orphans are left alone
#   - ORCH_RECLAIM_RECENT_THRESHOLD_HOURS gates the recent-activity guard
#   - the reclaimed row falls back to ready status on the next plan run
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP=$(mktemp -d)
SANITIZED_ROOT="$TEST_TMP/toolkit"
GH_LOG="$TEST_TMP/gh.log"
PLAN_FILE="$TEST_TMP/plan.json"

cleanup() {
  rm -rf "$TEST_TMP"
}
trap cleanup EXIT

fail() {
  printf 'not ok - %s\n' "$*" >&2
  exit 1
}

mkdir -p "$SANITIZED_ROOT/scripts" "$SANITIZED_ROOT/lib" \
         "$TEST_TMP/configs" "$TEST_TMP/state" "$TEST_TMP/logs" \
         "$TEST_TMP/bin"

for rel in \
  scripts/reclaim_orphan_assignments.sh \
  lib/config_resolver.sh \
  lib/process_safety.sh \
  lib/audit_log.sh \
  lib/config_check.sh \
  lib/log_bounds.sh
do
  tr -d '\r' < "$ROOT/$rel" > "$SANITIZED_ROOT/$rel"
done
chmod +x "$SANITIZED_ROOT/scripts/reclaim_orphan_assignments.sh"

# Stub dispatch_plan.sh — reads the current plan JSON from $PLAN_FILE so
# each scenario can swap the dataset without touching the script.
cat > "$SANITIZED_ROOT/scripts/dispatch_plan.sh" <<'PLAN'
#!/usr/bin/env bash
# Stub: emit the plan recorded at $PLAN_FILE regardless of CLI args.
cat "${PLAN_FILE:?PLAN_FILE must be set in the test harness}"
PLAN
chmod +x "$SANITIZED_ROOT/scripts/dispatch_plan.sh"

# Stub gh — records every invocation to $GH_LOG and answers per-subcommand:
#   issue view <n> --json updatedAt -q .updatedAt
#       -> prints a timestamp keyed by the issue number via
#          GH_UPDATED_AT_<n> env vars (default = $GH_DEFAULT_UPDATED_AT
#          which the test sets to "long ago" so orphans look idle).
#   issue edit <n> --remove-assignee <login>
#       -> succeeds unless GH_EDIT_FAIL_<n>=1; logs the edit.
cat > "$TEST_TMP/bin/gh" <<'GH'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >> "${GH_LOG:?GH_LOG required}"
cmd=${1:-}
sub=${2:-}
case "$cmd:$sub" in
  issue:view)
    issue=${3:-}
    updated_var="GH_UPDATED_AT_${issue}"
    value=${!updated_var:-${GH_DEFAULT_UPDATED_AT:-1970-01-01T00:00:00Z}}
    printf '%s' "$value"
    ;;
  issue:edit)
    issue=${3:-}
    fail_var="GH_EDIT_FAIL_${issue}"
    if [[ "${!fail_var:-0}" == "1" ]]; then
      printf 'gh edit refused for %s\n' "$issue" >&2
      exit 1
    fi
    ;;
  *)
    printf 'unsupported gh stub command: %s\n' "$*" >&2
    exit 64
    ;;
esac
GH
chmod +x "$TEST_TMP/bin/gh"
export PATH="$TEST_TMP/bin:$PATH"
export GH_LOG

# Minimal project config the script can source.
cat > "$TEST_TMP/configs/orphan.config.sh" <<EOF
#!/usr/bin/env bash
PROJECT="orphan-test"
GH_REPO="example/orphan"
GH_CONFIG_DIR="$TEST_TMP/gh-config"
DEFAULT_BRANCH="main"
AGENT_WORKDIR_TEMPLATE="$TEST_TMP/workdirs/%s"
AGENT_GH_LOGINS=(
  "agent-001=RBOKCLIactive"
  "agent-002=ActiveLogin2"
)
EOF

# Helper: write the dispatch_plan dataset for the next invocation.
write_plan() {
  printf '%s\n' "$1" > "$PLAN_FILE"
}

# Helper: invoke the script with shared env wiring.
run_reclaim() {
  ORCH_STATE_BASE="$TEST_TMP/state" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  PLAN_FILE="$PLAN_FILE" \
  bash "$SANITIZED_ROOT/scripts/reclaim_orphan_assignments.sh" "$@"
}

reset_gh_log() {
  : > "$GH_LOG"
}

# ---------------------------------------------------------------------------
# Scenario 1: --dry-run lists every orphan without running gh issue edit.
# ---------------------------------------------------------------------------
write_plan '[
  {"issue":454,"status":"assigned","assignees":["RBOKCLIclaude"],"title":"orphan 1"},
  {"issue":449,"status":"assigned","assignees":["RBOKCLIgemini"],"title":"orphan 2"},
  {"issue":500,"status":"assigned","assignees":["RBOKCLIactive"],"title":"active assignee"},
  {"issue":600,"status":"ready","assignees":[],"title":"already ready"}
]'
reset_gh_log
export GH_DEFAULT_UPDATED_AT="2020-01-01T00:00:00Z"

set +e
dry_output=$(run_reclaim "$TEST_TMP/configs/orphan.config.sh" --json 2>/dev/null)
dry_status=$?
set -e
[[ "$dry_status" -eq 0 ]] || fail "dry-run should exit 0, got $dry_status: $dry_output"

jq -e '
  .mode == "dry-run"
  and .threshold_hours == 24
  and (.records | length == 2)
  and ([.records[] | select(.issue == "454" and .status == "dry-run-orphan" and .assignee == "RBOKCLIclaude")] | length == 1)
  and ([.records[] | select(.issue == "449" and .status == "dry-run-orphan" and .assignee == "RBOKCLIgemini")] | length == 1)
  and ([.records[] | .assignee] | index("RBOKCLIactive") == null)
' <<< "$dry_output" >/dev/null \
  || fail "dry-run JSON should list both orphans and skip the active assignee: $dry_output"

if grep -qE 'issue edit ' "$GH_LOG"; then
  fail "dry-run must NOT call gh issue edit, log:\n$(cat "$GH_LOG")"
fi

# ---------------------------------------------------------------------------
# Scenario 2: --apply unassigns idle orphans, records audit row, leaves
# active assignees untouched. After apply, the next plan run drops the
# assignees so the row falls back to status=ready.
# ---------------------------------------------------------------------------
reset_gh_log
audit_log_path="$TEST_TMP/logs/orphan-test.log"
: > "$audit_log_path"

set +e
apply_output=$(run_reclaim "$TEST_TMP/configs/orphan.config.sh" --apply --json 2>/dev/null)
apply_status=$?
set -e
[[ "$apply_status" -eq 0 ]] || fail "apply should exit 0, got $apply_status: $apply_output"

jq -e '
  .mode == "apply"
  and (.records | length == 2)
  and ([.records[] | select(.status == "reclaimed" and .reason == "not_in_active_logins")] | length == 2)
  and ([.records[] | select(.issue == "454" and .assignee == "RBOKCLIclaude")] | length == 1)
  and ([.records[] | select(.issue == "449" and .assignee == "RBOKCLIgemini")] | length == 1)
' <<< "$apply_output" >/dev/null \
  || fail "apply JSON should report both orphans as reclaimed: $apply_output"

grep -q 'issue edit 454 --repo example/orphan --remove-assignee RBOKCLIclaude' "$GH_LOG" \
  || fail "apply must call gh issue edit for #454, log:\n$(cat "$GH_LOG")"
grep -q 'issue edit 449 --repo example/orphan --remove-assignee RBOKCLIgemini' "$GH_LOG" \
  || fail "apply must call gh issue edit for #449, log:\n$(cat "$GH_LOG")"
grep -qv 'issue edit 500' "$GH_LOG" \
  || fail "apply must NOT touch the active-assignee row #500, log:\n$(cat "$GH_LOG")"

grep -q 'RECLAIM_ORPHAN_ASSIGNMENT issue=#454 removed_assignee=RBOKCLIclaude reason=not_in_active_logins' "$audit_log_path" \
  || fail "missing RECLAIM_ORPHAN_ASSIGNMENT audit entry for #454, log:\n$(cat "$audit_log_path")"
grep -q 'RECLAIM_ORPHAN_ASSIGNMENT issue=#449 removed_assignee=RBOKCLIgemini reason=not_in_active_logins' "$audit_log_path" \
  || fail "missing RECLAIM_ORPHAN_ASSIGNMENT audit entry for #449, log:\n$(cat "$audit_log_path")"

# After apply, simulate the next plan run (without those assignees) and
# confirm the row would now classify as ready instead of assigned.
write_plan '[
  {"issue":454,"status":"ready","assignees":[],"title":"orphan 1"},
  {"issue":449,"status":"ready","assignees":[],"title":"orphan 2"},
  {"issue":500,"status":"assigned","assignees":["RBOKCLIactive"],"title":"active assignee"}
]'
followup=$(run_reclaim "$TEST_TMP/configs/orphan.config.sh" --json 2>/dev/null)
jq -e '.records | length == 0' <<< "$followup" >/dev/null \
  || fail "after reclaim the next plan run must report no orphan records: $followup"

# ---------------------------------------------------------------------------
# Scenario 3: ORCH_RECLAIM_RECENT_THRESHOLD_HOURS gates the recent-activity
# guard — when the orphan's issue was touched inside the window, --apply
# leaves it alone and reports status=skipped/recent-activity.
# ---------------------------------------------------------------------------
recent_ts=$(date -u -d '-1 hour' +'%Y-%m-%dT%H:%M:%SZ')
export GH_UPDATED_AT_454="$recent_ts"
export GH_DEFAULT_UPDATED_AT="2020-01-01T00:00:00Z"

write_plan '[
  {"issue":454,"status":"assigned","assignees":["RBOKCLIclaude"],"title":"orphan recent"},
  {"issue":449,"status":"assigned","assignees":["RBOKCLIgemini"],"title":"orphan idle"}
]'
reset_gh_log

set +e
recent_output=$(ORCH_RECLAIM_RECENT_THRESHOLD_HOURS=24 \
  run_reclaim "$TEST_TMP/configs/orphan.config.sh" --apply --json 2>/dev/null)
recent_status=$?
set -e
[[ "$recent_status" -eq 0 ]] || fail "recent-activity scenario should exit 0, got $recent_status"

jq -e '
  .records
  | (length == 2)
  and (any(.status == "skipped" and .reason == "recent-activity" and .issue == "454"))
  and (any(.status == "reclaimed" and .issue == "449"))
' <<< "$recent_output" >/dev/null \
  || fail "recent-activity gate should skip #454 and reclaim #449: $recent_output"

if grep -qE 'issue edit 454 ' "$GH_LOG"; then
  fail "recent-activity guard must NOT issue edit #454, log:\n$(cat "$GH_LOG")"
fi
grep -q 'issue edit 449 --repo example/orphan --remove-assignee RBOKCLIgemini' "$GH_LOG" \
  || fail "recent-activity scenario must still reclaim the idle orphan #449"

# Lowering the threshold to 0 reclaims #454 too — the env override flows
# end-to-end.
reset_gh_log
zero_output=$(ORCH_RECLAIM_RECENT_THRESHOLD_HOURS=0 \
  run_reclaim "$TEST_TMP/configs/orphan.config.sh" --apply --json 2>/dev/null)
jq -e '
  (.threshold_hours == 0)
  and ([.records[] | select(.status == "reclaimed")] | length == 2)
' <<< "$zero_output" >/dev/null \
  || fail "threshold=0 should reclaim every orphan: $zero_output"

# ---------------------------------------------------------------------------
# Scenario 4: no orphans -> empty records and zero gh edits.
# ---------------------------------------------------------------------------
write_plan '[
  {"issue":500,"status":"assigned","assignees":["RBOKCLIactive"],"title":"active assignee"},
  {"issue":600,"status":"ready","assignees":[],"title":"already ready"}
]'
unset GH_UPDATED_AT_454
reset_gh_log
empty_output=$(run_reclaim "$TEST_TMP/configs/orphan.config.sh" --json 2>/dev/null)
jq -e '.records == []' <<< "$empty_output" >/dev/null \
  || fail "no-orphans scenario must return an empty records array: $empty_output"
if grep -qE 'issue edit ' "$GH_LOG"; then
  fail "no-orphans scenario must NOT call gh issue edit, log:\n$(cat "$GH_LOG")"
fi

printf 'ok - reclaim_orphan_assignments releases orphan GitHub assignees\n'
