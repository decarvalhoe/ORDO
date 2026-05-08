#!/usr/bin/env bash
# tests/test_pr_ops_queue.sh — read-only PR operations queue classifier (#358).
#
# Cases:
#   1.  resolve_conflict   — merge-conflict signal wins regardless of CI.
#   2.  fix_ci             — ci-failed signal routes to fix_ci.
#   3.  refresh_branch     — needs-rebase / pr-behind / remote-rebased-local-stale.
#   4.  mark_ready_candidate — draft + ci-pass and no other blockers.
#   5.  review_required    — review-required or changes-requested.
#   6.  merge_candidate    — merge-ready signal.
#   7.  hold_unknown_state — mergeable-unknown / merge-state-unknown / checks-missing.
#   8.  hold_policy_blocked — deploy-gate-external-wait / auto-merge-armed /
#                              merge-blocked / lone ci-pending.
#   9.  Priority precedence — merge-conflict + ci-failed + needs-rebase
#       picks resolve_conflict (highest).
#   10. Multiple PRs sorted by priority then last_update_age_sec.
#   11. Stale snapshot refusal: exits 4 unless --allow-stale.
#   12. --allow-stale lets the queue be produced from an old snapshot.
#   13. Linked issue extracted from PR body ("Closes #N", "Refs: #M").
#   14. Project policy threaded through into the candidate record.
#   15. Universality: identical PR fixture under two different aliases
#       produces identical candidates (no project-name hardcoding).
#   16. Portfolio-grouped snapshot shape walks all bundles.
#   17. CLI rejects missing inputs (exit 2).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT/lib/pr_ops_queue.sh"
SCRIPT="$ROOT/scripts/pr_ops_queue.sh"
TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT

fail() {
  printf 'not ok - %s\n' "$*" >&2
  exit 1
}

assert_eq() {
  local got=$1 want=$2 desc=$3
  [[ "$got" == "$want" ]] || fail "$desc: got='$got' want='$want'"
}

[[ -r "$LIB" ]]    || fail "lib missing: $LIB"
[[ -x "$SCRIPT" ]] || fail "script not executable: $SCRIPT"
command -v jq >/dev/null 2>&1 || fail "jq required for these tests"

# shellcheck source=../lib/pr_ops_queue.sh
source "$LIB"

GENERATED_AT="2026-05-08T13:46:00Z"

# Helper: generic project meta object used by the lib-level tests.
PROJECT_META_DEFAULT='{"alias":"demo","project":"demo-product","repo":"example/demo","default_branch":"main","config":"/tmp/demo.config.sh","policy":"observe"}'

# --- Case 1: resolve_conflict ---------------------------------------------

pr_conflict='{"pr":"101","branch":"feat/a","head":"abcd1234","head_full":"abcd1234deadbeef","base_branch":"main","updated_at":"2026-05-08T12:00:00Z","body_text":"","agent":"alpha","merge_state":"DIRTY","mergeable":"CONFLICTING","review":"REVIEW_REQUIRED","is_draft":false,"ci_fail":0,"ci_pending":0,"ci_total":3,"deploy_gate_pending":0,"base_current":"1","signals":["merge-conflict","review-required"]}'
record=$(pr_ops_queue_classify "$pr_conflict" "$PROJECT_META_DEFAULT" "$GENERATED_AT")
assert_eq "$(jq -r '.candidate' <<< "$record")"   "resolve_conflict" "case 1 candidate"
assert_eq "$(jq -r '.priority' <<< "$record")"     "90"               "case 1 priority"
assert_eq "$(jq -r '.schema' <<< "$record")"       "ordo.pr_ops_queue.v1" "case 1 schema"
assert_eq "$(jq -r '.alias' <<< "$record")"        "demo"             "case 1 alias"
assert_eq "$(jq -r '.repo' <<< "$record")"         "example/demo"     "case 1 repo"
assert_eq "$(jq -r '.pr' <<< "$record")"           "101"              "case 1 pr"
assert_eq "$(jq -r '.base_branch' <<< "$record")"  "main"             "case 1 base_branch"
assert_eq "$(jq -r '.is_draft' <<< "$record")"     "false"            "case 1 is_draft"
assert_eq "$(jq -r '.ci_summary.total' <<< "$record")" "3"            "case 1 ci_summary.total"
assert_eq "$(jq -r '.ci_summary.passed' <<< "$record")" "3"           "case 1 ci_summary.passed"
assert_eq "$(jq -r '.project_policy' <<< "$record")" "observe"        "case 1 policy"

# --- Case 2: fix_ci -------------------------------------------------------

pr_ci_failed='{"pr":"102","branch":"feat/b","head":"bbbb","head_full":"bbbb","base_branch":"main","updated_at":"2026-05-08T11:00:00Z","body_text":"","agent":"beta","merge_state":"BLOCKED","mergeable":"MERGEABLE","review":"","is_draft":false,"ci_fail":2,"ci_pending":0,"ci_total":5,"deploy_gate_pending":0,"base_current":"1","signals":["ci-failed"]}'
record=$(pr_ops_queue_classify "$pr_ci_failed" "$PROJECT_META_DEFAULT" "$GENERATED_AT")
assert_eq "$(jq -r '.candidate' <<< "$record")" "fix_ci" "case 2 candidate"
assert_eq "$(jq -r '.priority' <<< "$record")"  "80"     "case 2 priority"
assert_eq "$(jq -r '.ci_summary.failed' <<< "$record")" "2" "case 2 ci_summary.failed"
assert_eq "$(jq -r '.ci_summary.passed' <<< "$record")" "3" "case 2 ci_summary.passed"

# --- Case 3: refresh_branch -----------------------------------------------

pr_behind='{"pr":"103","branch":"feat/c","head":"cccc","head_full":"cccc","base_branch":"main","updated_at":"2026-05-08T10:00:00Z","body_text":"","agent":"","merge_state":"BEHIND","mergeable":"MERGEABLE","review":"","is_draft":false,"ci_fail":0,"ci_pending":0,"ci_total":3,"deploy_gate_pending":0,"base_current":"0","signals":["pr-behind","needs-rebase"]}'
record=$(pr_ops_queue_classify "$pr_behind" "$PROJECT_META_DEFAULT" "$GENERATED_AT")
assert_eq "$(jq -r '.candidate' <<< "$record")" "refresh_branch" "case 3 candidate"

pr_remote_rebased='{"pr":"203","branch":"feat/c2","head":"dddd","head_full":"dddd","base_branch":"main","updated_at":"2026-05-08T10:00:00Z","body_text":"","agent":"","merge_state":"BLOCKED","mergeable":"MERGEABLE","review":"","is_draft":false,"ci_fail":0,"ci_pending":0,"ci_total":2,"deploy_gate_pending":0,"base_current":"0","signals":["remote-rebased-local-stale"]}'
record=$(pr_ops_queue_classify "$pr_remote_rebased" "$PROJECT_META_DEFAULT" "$GENERATED_AT")
assert_eq "$(jq -r '.candidate' <<< "$record")" "refresh_branch" "case 3b remote-rebased candidate"

# --- Case 4: mark_ready_candidate ----------------------------------------

pr_clean_draft='{"pr":"104","branch":"infra-unblock","head":"eeee","head_full":"eeee","base_branch":"main","updated_at":"2026-05-08T09:00:00Z","body_text":"","agent":"","merge_state":"BLOCKED","mergeable":"MERGEABLE","review":"","is_draft":true,"ci_fail":0,"ci_pending":0,"ci_total":4,"deploy_gate_pending":0,"base_current":"1","signals":["draft","ci-pass"]}'
record=$(pr_ops_queue_classify "$pr_clean_draft" "$PROJECT_META_DEFAULT" "$GENERATED_AT")
assert_eq "$(jq -r '.candidate' <<< "$record")" "mark_ready_candidate" "case 4 candidate"
assert_eq "$(jq -r '.is_draft' <<< "$record")"  "true"                  "case 4 is_draft"

# --- Case 5: review_required ----------------------------------------------

pr_review='{"pr":"105","branch":"feat/d","head":"ffff","head_full":"ffff","base_branch":"main","updated_at":"2026-05-08T08:00:00Z","body_text":"","agent":"","merge_state":"BLOCKED","mergeable":"MERGEABLE","review":"REVIEW_REQUIRED","is_draft":false,"ci_fail":0,"ci_pending":0,"ci_total":3,"deploy_gate_pending":0,"base_current":"1","signals":["review-required","ci-pass"]}'
record=$(pr_ops_queue_classify "$pr_review" "$PROJECT_META_DEFAULT" "$GENERATED_AT")
assert_eq "$(jq -r '.candidate' <<< "$record")" "review_required" "case 5 candidate"

pr_changes='{"pr":"205","branch":"feat/d2","head":"gggg","head_full":"gggg","base_branch":"main","updated_at":"2026-05-08T07:00:00Z","body_text":"","agent":"","merge_state":"BLOCKED","mergeable":"MERGEABLE","review":"CHANGES_REQUESTED","is_draft":false,"ci_fail":0,"ci_pending":0,"ci_total":3,"deploy_gate_pending":0,"base_current":"1","signals":["changes-requested","ci-pass"]}'
record=$(pr_ops_queue_classify "$pr_changes" "$PROJECT_META_DEFAULT" "$GENERATED_AT")
assert_eq "$(jq -r '.candidate' <<< "$record")" "review_required" "case 5b changes-requested candidate"

# --- Case 6: merge_candidate ----------------------------------------------

pr_merge_ready='{"pr":"106","branch":"feat/e","head":"hhhh","head_full":"hhhh","base_branch":"main","updated_at":"2026-05-08T06:00:00Z","body_text":"","agent":"","merge_state":"CLEAN","mergeable":"MERGEABLE","review":"APPROVED","is_draft":false,"ci_fail":0,"ci_pending":0,"ci_total":4,"deploy_gate_pending":0,"base_current":"1","signals":["ci-pass","merge-ready"]}'
record=$(pr_ops_queue_classify "$pr_merge_ready" "$PROJECT_META_DEFAULT" "$GENERATED_AT")
assert_eq "$(jq -r '.candidate' <<< "$record")" "merge_candidate" "case 6 candidate"

# --- Case 7: hold_unknown_state -------------------------------------------

pr_unknown='{"pr":"107","branch":"feat/f","head":"iiii","head_full":"iiii","base_branch":"main","updated_at":"2026-05-08T05:00:00Z","body_text":"","agent":"","merge_state":"UNKNOWN","mergeable":"UNKNOWN","review":"","is_draft":false,"ci_fail":0,"ci_pending":0,"ci_total":0,"deploy_gate_pending":0,"base_current":"1","signals":["mergeable-unknown","merge-state-unknown","checks-missing"]}'
record=$(pr_ops_queue_classify "$pr_unknown" "$PROJECT_META_DEFAULT" "$GENERATED_AT")
assert_eq "$(jq -r '.candidate' <<< "$record")" "hold_unknown_state" "case 7 candidate"

# --- Case 8: hold_policy_blocked ------------------------------------------

pr_deploy='{"pr":"108","branch":"feat/g","head":"jjjj","head_full":"jjjj","base_branch":"main","updated_at":"2026-05-08T04:00:00Z","body_text":"","agent":"","merge_state":"BLOCKED","mergeable":"MERGEABLE","review":"APPROVED","is_draft":false,"ci_fail":0,"ci_pending":0,"ci_total":3,"deploy_gate_pending":1,"base_current":"1","signals":["deploy-gate-external-wait","ci-pass"]}'
record=$(pr_ops_queue_classify "$pr_deploy" "$PROJECT_META_DEFAULT" "$GENERATED_AT")
assert_eq "$(jq -r '.candidate' <<< "$record")" "hold_policy_blocked" "case 8 deploy-gate"

pr_auto_merge='{"pr":"208","branch":"feat/g2","head":"kkkk","head_full":"kkkk","base_branch":"main","updated_at":"2026-05-08T03:00:00Z","body_text":"","agent":"","merge_state":"BLOCKED","mergeable":"MERGEABLE","review":"APPROVED","is_draft":false,"ci_fail":0,"ci_pending":1,"ci_total":4,"deploy_gate_pending":0,"base_current":"1","signals":["auto-merge-armed","ci-pending"]}'
record=$(pr_ops_queue_classify "$pr_auto_merge" "$PROJECT_META_DEFAULT" "$GENERATED_AT")
assert_eq "$(jq -r '.candidate' <<< "$record")" "hold_policy_blocked" "case 8b auto-merge candidate"

pr_pending_only='{"pr":"308","branch":"feat/g3","head":"llll","head_full":"llll","base_branch":"main","updated_at":"2026-05-08T02:00:00Z","body_text":"","agent":"","merge_state":"BLOCKED","mergeable":"MERGEABLE","review":"APPROVED","is_draft":false,"ci_fail":0,"ci_pending":1,"ci_total":3,"deploy_gate_pending":0,"base_current":"1","signals":["ci-pending"]}'
record=$(pr_ops_queue_classify "$pr_pending_only" "$PROJECT_META_DEFAULT" "$GENERATED_AT")
assert_eq "$(jq -r '.candidate' <<< "$record")" "hold_policy_blocked" "case 8c lone ci-pending"

# --- Case 9: priority precedence ------------------------------------------

pr_multi_blockers='{"pr":"109","branch":"feat/h","head":"mmmm","head_full":"mmmm","base_branch":"main","updated_at":"2026-05-08T01:00:00Z","body_text":"","agent":"","merge_state":"DIRTY","mergeable":"CONFLICTING","review":"REVIEW_REQUIRED","is_draft":false,"ci_fail":2,"ci_pending":0,"ci_total":5,"deploy_gate_pending":0,"base_current":"0","signals":["merge-conflict","ci-failed","needs-rebase","review-required"]}'
record=$(pr_ops_queue_classify "$pr_multi_blockers" "$PROJECT_META_DEFAULT" "$GENERATED_AT")
assert_eq "$(jq -r '.candidate' <<< "$record")" "resolve_conflict" "case 9 highest priority wins"

# --- Case 10: portfolio-grouped snapshot via CLI, sorted output ----------

snapshot_file="$TEST_TMP/snapshot_grouped.json"
cat > "$snapshot_file" <<JSON
[
  {
    "alias":"alpha",
    "project_meta":{"alias":"alpha","project":"alpha-product","repo":"example/alpha","default_branch":"main","config":"/tmp/alpha.config.sh","policy":"observe"},
    "prs":[
      $pr_ci_failed,
      $pr_review,
      $pr_merge_ready
    ]
  },
  {
    "alias":"beta",
    "project_meta":{"alias":"beta","project":"beta-product","repo":"example/beta","default_branch":"main","config":"/tmp/beta.config.sh","policy":"centralized"},
    "prs":[
      $pr_conflict
    ]
  }
]
JSON

queue=$("$SCRIPT" --input "$snapshot_file" --json)
queue_count=$(jq -r 'length' <<< "$queue")
assert_eq "$queue_count" "4" "case 10 four candidates emitted"

# Sort: priority desc → resolve_conflict (90), fix_ci (80),
# review_required (50), merge_candidate (40).
ordered=$(jq -r '[.[].candidate] | join(",")' <<< "$queue")
assert_eq "$ordered" "resolve_conflict,fix_ci,review_required,merge_candidate" "case 10 priority order"

# Beta carries its policy through.
beta_policy=$(jq -r '[.[] | select(.alias == "beta")][0].project_policy' <<< "$queue")
assert_eq "$beta_policy" "centralized" "case 10 beta policy threaded"

# --- Case 11: stale snapshot refusal -------------------------------------

# Force the snapshot's mtime back by 2 hours.
touch -d "@$(($(date +%s) - 7200))" "$snapshot_file"
out=$("$SCRIPT" --input "$snapshot_file" 2>&1)
rc=$?
[[ "$rc" -eq 4 ]] || fail "case 11: stale snapshot expected exit 4, got=$rc out=$out"
[[ "$out" == *"pr_ops_queue_stale"* ]] || fail "case 11: expected stale refusal text, got=$out"

# --- Case 12: --allow-stale lets the queue produce ----------------------

queue=$("$SCRIPT" --input "$snapshot_file" --allow-stale 2>/dev/null)
queue_count=$(jq -r 'length' <<< "$queue")
assert_eq "$queue_count" "4" "case 12 allow-stale produces queue"

# --- Case 13: linked issue extraction from PR body ------------------------

pr_with_body='{"pr":"113","branch":"feat/i","head":"oooo","head_full":"oooo","base_branch":"main","updated_at":"2026-05-08T00:00:00Z","body_text":"## Summary\nThis PR fixes a flaky test.\n\nCloses #404\nRefs: #999","agent":"","merge_state":"CLEAN","mergeable":"MERGEABLE","review":"","is_draft":false,"ci_fail":0,"ci_pending":0,"ci_total":3,"deploy_gate_pending":0,"base_current":"1","signals":["ci-pass","merge-ready"]}'
record=$(pr_ops_queue_classify "$pr_with_body" "$PROJECT_META_DEFAULT" "$GENERATED_AT")
assert_eq "$(jq -r '.linked_issue' <<< "$record")" "404" "case 13 linked_issue extracted"

# --- Case 14: project policy threaded into candidate record --------------

PROJECT_META_DELEGATED='{"alias":"omega","project":"omega-product","repo":"example/omega","default_branch":"main","config":"/tmp/omega.config.sh","policy":"delegated"}'
record=$(pr_ops_queue_classify "$pr_ci_failed" "$PROJECT_META_DELEGATED" "$GENERATED_AT")
assert_eq "$(jq -r '.project_policy' <<< "$record")" "delegated" "case 14 policy delegated"
assert_eq "$(jq -r '.alias' <<< "$record")"          "omega"      "case 14 alias"

# --- Case 15: universality — same fixture under different alias ---------

PROJECT_META_FOO='{"alias":"some-other-product","project":"some-other-product","repo":"example/whatever","default_branch":"main","config":"/tmp/foo.config.sh","policy":"observe"}'
record_a=$(pr_ops_queue_classify "$pr_ci_failed" "$PROJECT_META_DEFAULT" "$GENERATED_AT")
record_b=$(pr_ops_queue_classify "$pr_ci_failed" "$PROJECT_META_FOO"     "$GENERATED_AT")
cand_a=$(jq -r '.candidate' <<< "$record_a")
cand_b=$(jq -r '.candidate' <<< "$record_b")
prio_a=$(jq -r '.priority' <<< "$record_a")
prio_b=$(jq -r '.priority' <<< "$record_b")
assert_eq "$cand_a" "$cand_b" "case 15 alias-independent candidate"
assert_eq "$prio_a" "$prio_b" "case 15 alias-independent priority"

# --- Case 16: portfolio-grouped snapshot walks every bundle --------------

# Already exercised by case 10. Add the negative: empty bundle list yields
# an empty queue.
empty_snapshot="$TEST_TMP/empty.json"
printf '[]\n' > "$empty_snapshot"
queue=$("$SCRIPT" --input "$empty_snapshot" --json)
queue_count=$(jq -r 'length' <<< "$queue")
assert_eq "$queue_count" "0" "case 16 empty portfolio yields empty queue"

# --- Case 17: CLI rejects missing inputs ----------------------------------

out=$("$SCRIPT" 2>&1)
rc=$?
[[ "$rc" -eq 2 ]] || fail "case 17 no args: expected exit 2, got=$rc out=$out"

out=$("$SCRIPT" --portfolio /tmp/nope --project /tmp/also-nope 2>&1)
rc=$?
[[ "$rc" -eq 2 ]] || fail "case 17 too-many-modes: expected exit 2, got=$rc out=$out"

# --- Case 18: flat-array shape requires --project-meta -------------------

flat_snapshot="$TEST_TMP/flat.json"
printf '%s\n' "[$pr_ci_failed]" > "$flat_snapshot"
out=$("$SCRIPT" --input "$flat_snapshot" --allow-stale 2>&1)
rc=$?
[[ "$rc" -eq 2 ]] || fail "case 18 flat snapshot needs project-meta: expected exit 2, got=$rc out=$out"

queue=$("$SCRIPT" --input "$flat_snapshot" --allow-stale --project-meta "$PROJECT_META_DEFAULT" --json 2>/dev/null)
queue_count=$(jq -r 'length' <<< "$queue")
assert_eq "$queue_count" "1" "case 18 flat snapshot with --project-meta produces 1 candidate"
assert_eq "$(jq -r '.[0].candidate' <<< "$queue")" "fix_ci" "case 18 flat snapshot candidate"

# --- Case 19: candidate type list (priority-ordered) ---------------------

ids=$(pr_ops_queue_candidate_types | paste -sd, -)
assert_eq "$ids" "resolve_conflict,fix_ci,refresh_branch,mark_ready_candidate,review_required,merge_candidate,hold_unknown_state,hold_policy_blocked" \
  "case 19 candidate types list"

printf 'ok - pr_ops_queue tests passed\n'
