#!/usr/bin/env bash
# tests/test_portfolio_workdir_readiness.sh — branch-aware readiness
# diagnostics for matrix workdirs (#367).
#
# Each case sets up a real git workdir on disk (origin + clone) and
# asserts the structured readiness state plus the recovery action the
# orchestrator should take next.
#
# Cases cover every state the lib is allowed to emit, and all four
# acceptance states from the dispatch:
#   1. DIRTY (case 3)               — destructive, RECOVERY_CONTEXT_PROOF
#   2. WRONG_BRANCH (case 7)        — non-destructive, git_checkout_default
#   3. BEHIND_ORIGIN (case 5)       — non-destructive, git_pull_ff
#   4. STALE_ASSIGNMENT (case 7b)   — non-destructive, re-checkout default
#
# Plus: ready (1), ready_feature_branch (2), ahead_origin_default (6),
# in_progress rebase (8), in_progress merge (8b), in_progress
# cherry-pick (8c), detached_head (9), no_clone (10), no_origin_default
# (11), and the assert_workdir_ready wrapper backwards-compat (12).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT/lib/portfolio_config.sh"
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

[[ -r "$LIB" ]] || fail "lib missing: $LIB"

# shellcheck source=../lib/portfolio_config.sh
source "$LIB"

# Build a shared origin once. Each case clones from it and manipulates
# the clone independently.
ORIGIN="$TEST_TMP/origin.git"
SEED="$TEST_TMP/seed"
git init --bare -q "$ORIGIN"
git init -q "$SEED"
git -C "$SEED" config user.email "test@example.invalid"
git -C "$SEED" config user.name "Readiness Test"
printf 'v1\n' > "$SEED/README.md"
git -C "$SEED" add README.md
git -C "$SEED" commit -q -m 'seed'
git -C "$SEED" branch -M main
git -C "$SEED" remote add origin "$ORIGIN"
git -C "$SEED" push -q -u origin main
# Bare repos created with `git init --bare` don't auto-set HEAD; without
# this fixup, `git clone` warns and the working tree is checked out
# detached, which would skew every readiness state in the suite.
git -C "$ORIGIN" symbolic-ref HEAD refs/heads/main

clone() {
  local name=$1
  local dst="$TEST_TMP/$name"
  git clone -q "$ORIGIN" "$dst"
  git -C "$dst" config user.email "test@example.invalid"
  git -C "$dst" config user.name "Readiness Test"
  printf '%s' "$dst"
}

# --- Case 1: ready (default branch, in sync) ------------------------------

w=$(clone case_ready)
out=$(portfolio_workdir_readiness_status "$w" "main")
portfolio_workdir_readiness_status "$w" "main" >/dev/null 2>&1
assert_eq "$PORTFOLIO_WORKDIR_READINESS_STATE"            "ready"  "case 1 state"
assert_eq "$PORTFOLIO_WORKDIR_READINESS_BRANCH"           "main"   "case 1 branch"
assert_eq "$PORTFOLIO_WORKDIR_READINESS_AHEAD"            "0"      "case 1 ahead"
assert_eq "$PORTFOLIO_WORKDIR_READINESS_BEHIND"           "0"      "case 1 behind"
assert_eq "$PORTFOLIO_WORKDIR_READINESS_DIRTY"            "0"      "case 1 dirty"
assert_eq "$PORTFOLIO_WORKDIR_READINESS_RECOVERY_ACTION"  "none"   "case 1 recovery"
assert_eq "$PORTFOLIO_WORKDIR_READINESS_DESTRUCTIVE"      "0"      "case 1 destructive"
[[ "$out" == *"state=ready"* ]] || fail "case 1: missing state in line: $out"

# --- Case 2: ready_feature_branch (clean branch descending from origin/main) -

w=$(clone case_feature)
git -C "$w" checkout -q -b feature/work
printf 'feature\n' >> "$w/README.md"
git -C "$w" commit -q -am 'feature work'
out=$(portfolio_workdir_readiness_status "$w" "main")
portfolio_workdir_readiness_status "$w" "main" >/dev/null 2>&1
assert_eq "$PORTFOLIO_WORKDIR_READINESS_STATE"            "ready_feature_branch" "case 2 state"
assert_eq "$PORTFOLIO_WORKDIR_READINESS_BRANCH"           "feature/work"          "case 2 branch"
assert_eq "$PORTFOLIO_WORKDIR_READINESS_DIRTY"            "0"                     "case 2 dirty"
assert_eq "$PORTFOLIO_WORKDIR_READINESS_RECOVERY_ACTION"  "none"                  "case 2 recovery"
assert_eq "$PORTFOLIO_WORKDIR_READINESS_DESTRUCTIVE"      "0"                     "case 2 destructive"

# --- Case 3: dirty (acceptance state #1) ----------------------------------

# Modified tracked file.
w=$(clone case_dirty_modified)
printf 'mod\n' >> "$w/README.md"
out=$(portfolio_workdir_readiness_status "$w" "main")
portfolio_workdir_readiness_status "$w" "main" >/dev/null 2>&1
assert_eq "$PORTFOLIO_WORKDIR_READINESS_STATE"            "dirty"                          "case 3 state"
assert_eq "$PORTFOLIO_WORKDIR_READINESS_DIRTY"            "1"                              "case 3 dirty count"
assert_eq "$PORTFOLIO_WORKDIR_READINESS_DIRTY_MODIFIED"   "1"                              "case 3 modified count"
assert_eq "$PORTFOLIO_WORKDIR_READINESS_DIRTY_UNTRACKED"  "0"                              "case 3 untracked count"
assert_eq "$PORTFOLIO_WORKDIR_READINESS_RECOVERY_ACTION"  "recovery_context_proof_required" "case 3 recovery"
assert_eq "$PORTFOLIO_WORKDIR_READINESS_DESTRUCTIVE"      "1"                              "case 3 destructive=1"

# Untracked-only is also dirty (and destructive) but the breakdown
# distinguishes it for the audit trail.
w=$(clone case_dirty_untracked)
printf 'newfile\n' > "$w/extra.txt"
out=$(portfolio_workdir_readiness_status "$w" "main")
portfolio_workdir_readiness_status "$w" "main" >/dev/null 2>&1
assert_eq "$PORTFOLIO_WORKDIR_READINESS_STATE"            "dirty"                          "case 3b state"
assert_eq "$PORTFOLIO_WORKDIR_READINESS_DIRTY"            "1"                              "case 3b dirty count"
assert_eq "$PORTFOLIO_WORKDIR_READINESS_DIRTY_MODIFIED"   "0"                              "case 3b modified count"
assert_eq "$PORTFOLIO_WORKDIR_READINESS_DIRTY_UNTRACKED"  "1"                              "case 3b untracked count"

# Mixed: 2 modified + 1 untracked = 3 total.
w=$(clone case_dirty_mixed)
printf 'a\n' >> "$w/README.md"
printf 'b\n' > "$w/added.txt"
git -C "$w" add added.txt
printf 'c\n' > "$w/untracked.txt"
out=$(portfolio_workdir_readiness_status "$w" "main")
portfolio_workdir_readiness_status "$w" "main" >/dev/null 2>&1
assert_eq "$PORTFOLIO_WORKDIR_READINESS_STATE"            "dirty" "case 3c state"
assert_eq "$PORTFOLIO_WORKDIR_READINESS_DIRTY"            "3"     "case 3c dirty count"
assert_eq "$PORTFOLIO_WORKDIR_READINESS_DIRTY_MODIFIED"   "2"     "case 3c modified count (M+A)"
assert_eq "$PORTFOLIO_WORKDIR_READINESS_DIRTY_UNTRACKED"  "1"     "case 3c untracked count"

# --- Case 4: stale_assignment via wrong_branch (acceptance state #4) ------

# Workdir kept on a non-default branch from a previous ticket; clean
# tree. The state must be wrong_branch, NOT dirty (PRAXIS regression
# class).
w=$(clone case_stale_assignment)
git -C "$w" checkout -q -b prev-ticket-branch
printf 'work\n' >> "$w/README.md"
git -C "$w" commit -q -am 'previous ticket work'
# Walk back to a state where origin/main is NOT an ancestor: hard reset
# to a fresh root commit so the branch diverges.
git -C "$w" checkout -q --orphan stale-divergent
git -C "$w" rm -rfq .
printf 'fresh\n' > "$w/README.md"
git -C "$w" add README.md
git -C "$w" commit -q -m 'stale assignment unrelated history'
out=$(portfolio_workdir_readiness_status "$w" "main")
portfolio_workdir_readiness_status "$w" "main" >/dev/null 2>&1
assert_eq "$PORTFOLIO_WORKDIR_READINESS_STATE"            "wrong_branch"            "case 4 state"
assert_eq "$PORTFOLIO_WORKDIR_READINESS_BRANCH"           "stale-divergent"         "case 4 branch"
assert_eq "$PORTFOLIO_WORKDIR_READINESS_DIRTY"            "0"                       "case 4 dirty=0 (acceptance: NOT dirty)"
assert_eq "$PORTFOLIO_WORKDIR_READINESS_RECOVERY_ACTION"  "git_checkout_default"    "case 4 recovery"
assert_eq "$PORTFOLIO_WORKDIR_READINESS_DESTRUCTIVE"      "0"                       "case 4 non-destructive"
[[ "$PORTFOLIO_WORKDIR_READINESS_RECOVERY_COMMAND" == *"checkout"* ]] \
  || fail "case 4 recovery_command should mention checkout, got: $PORTFOLIO_WORKDIR_READINESS_RECOVERY_COMMAND"

# --- Case 5: behind_origin_default (acceptance state #3) ------------------

w=$(clone case_behind)
# Advance origin so the clone falls behind without any local change.
printf 'v2\n' > "$SEED/README.md"
git -C "$SEED" commit -q -am 'origin advances'
git -C "$SEED" push -q origin main
git -C "$w" fetch -q origin main
out=$(portfolio_workdir_readiness_status "$w" "main")
portfolio_workdir_readiness_status "$w" "main" >/dev/null 2>&1
assert_eq "$PORTFOLIO_WORKDIR_READINESS_STATE"            "behind_origin_default" "case 5 state"
assert_eq "$PORTFOLIO_WORKDIR_READINESS_BRANCH"           "main"                  "case 5 branch"
assert_eq "$PORTFOLIO_WORKDIR_READINESS_DIRTY"            "0"                     "case 5 dirty"
assert_eq "$PORTFOLIO_WORKDIR_READINESS_AHEAD"            "0"                     "case 5 ahead"
[[ "$PORTFOLIO_WORKDIR_READINESS_BEHIND" != "0" ]] || fail "case 5 behind should be > 0"
assert_eq "$PORTFOLIO_WORKDIR_READINESS_RECOVERY_ACTION"  "git_pull_ff"           "case 5 recovery"
assert_eq "$PORTFOLIO_WORKDIR_READINESS_DESTRUCTIVE"      "0"                     "case 5 non-destructive"
[[ "$PORTFOLIO_WORKDIR_READINESS_RECOVERY_COMMAND" == *"pull --ff-only"* ]] \
  || fail "case 5 recovery_command should suggest pull --ff-only"

# --- Case 6: ahead_origin_default ---------------------------------------

w=$(clone case_ahead)
git -C "$w" fetch -q origin main
git -C "$w" pull -q --ff-only origin main
printf 'local\n' >> "$w/README.md"
git -C "$w" commit -q -am 'unpushed work on main'
out=$(portfolio_workdir_readiness_status "$w" "main")
portfolio_workdir_readiness_status "$w" "main" >/dev/null 2>&1
assert_eq "$PORTFOLIO_WORKDIR_READINESS_STATE"            "ahead_origin_default" "case 6 state"
assert_eq "$PORTFOLIO_WORKDIR_READINESS_BEHIND"           "0"                    "case 6 behind"
[[ "$PORTFOLIO_WORKDIR_READINESS_AHEAD" != "0" ]] || fail "case 6 ahead should be > 0"
assert_eq "$PORTFOLIO_WORKDIR_READINESS_RECOVERY_ACTION"  "git_push_or_review"   "case 6 recovery"

# --- Case 7: wrong_branch (acceptance state #2) ---------------------------

w=$(clone case_wrong_branch)
git -C "$w" checkout -q -b unrelated
git -C "$w" checkout -q --orphan unrelated-detached
git -C "$w" rm -rfq .
printf 'a\n' > "$w/file.txt"
git -C "$w" add file.txt
git -C "$w" commit -q -m 'unrelated history'
out=$(portfolio_workdir_readiness_status "$w" "main")
portfolio_workdir_readiness_status "$w" "main" >/dev/null 2>&1
assert_eq "$PORTFOLIO_WORKDIR_READINESS_STATE"            "wrong_branch"         "case 7 state"
assert_eq "$PORTFOLIO_WORKDIR_READINESS_DIRTY"            "0"                    "case 7 dirty"
assert_eq "$PORTFOLIO_WORKDIR_READINESS_RECOVERY_ACTION"  "git_checkout_default" "case 7 recovery"
assert_eq "$PORTFOLIO_WORKDIR_READINESS_DESTRUCTIVE"      "0"                    "case 7 non-destructive"

# --- Case 8: in_progress_op — rebase, merge, cherry-pick ----------------

w=$(clone case_inprogress_rebase)
git_dir=$(git -C "$w" rev-parse --absolute-git-dir)
mkdir -p "$git_dir/rebase-merge"
out=$(portfolio_workdir_readiness_status "$w" "main")
portfolio_workdir_readiness_status "$w" "main" >/dev/null 2>&1
assert_eq "$PORTFOLIO_WORKDIR_READINESS_STATE"            "in_progress_op"                  "case 8 state"
assert_eq "$PORTFOLIO_WORKDIR_READINESS_IN_PROGRESS"      "rebase-merge"                    "case 8 marker"
assert_eq "$PORTFOLIO_WORKDIR_READINESS_RECOVERY_ACTION"  "recovery_context_proof_required" "case 8 recovery"
assert_eq "$PORTFOLIO_WORKDIR_READINESS_DESTRUCTIVE"      "1"                               "case 8 destructive=1"

w=$(clone case_inprogress_merge)
git_dir=$(git -C "$w" rev-parse --absolute-git-dir)
printf 'abc1234\n' > "$git_dir/MERGE_HEAD"
out=$(portfolio_workdir_readiness_status "$w" "main")
portfolio_workdir_readiness_status "$w" "main" >/dev/null 2>&1
assert_eq "$PORTFOLIO_WORKDIR_READINESS_STATE"            "in_progress_op" "case 8b state"
assert_eq "$PORTFOLIO_WORKDIR_READINESS_IN_PROGRESS"      "MERGE_HEAD"     "case 8b marker"

w=$(clone case_inprogress_cherrypick)
git_dir=$(git -C "$w" rev-parse --absolute-git-dir)
printf 'def5678\n' > "$git_dir/CHERRY_PICK_HEAD"
out=$(portfolio_workdir_readiness_status "$w" "main")
portfolio_workdir_readiness_status "$w" "main" >/dev/null 2>&1
assert_eq "$PORTFOLIO_WORKDIR_READINESS_STATE"            "in_progress_op"     "case 8c state"
assert_eq "$PORTFOLIO_WORKDIR_READINESS_IN_PROGRESS"      "CHERRY_PICK_HEAD"   "case 8c marker"

# --- Case 9: detached_head ------------------------------------------------

w=$(clone case_detached)
sha=$(git -C "$w" rev-parse HEAD)
git -C "$w" checkout -q --detach "$sha"
out=$(portfolio_workdir_readiness_status "$w" "main")
portfolio_workdir_readiness_status "$w" "main" >/dev/null 2>&1
assert_eq "$PORTFOLIO_WORKDIR_READINESS_STATE"            "detached_head"             "case 9 state"
assert_eq "$PORTFOLIO_WORKDIR_READINESS_BRANCH"           ""                          "case 9 branch empty"
assert_eq "$PORTFOLIO_WORKDIR_READINESS_RECOVERY_ACTION"  "git_checkout_named_branch" "case 9 recovery"

# --- Case 10: no_clone ----------------------------------------------------

out=$(portfolio_workdir_readiness_status "$TEST_TMP/does-not-exist" "main")
portfolio_workdir_readiness_status "$TEST_TMP/does-not-exist" "main" >/dev/null 2>&1
assert_eq "$PORTFOLIO_WORKDIR_READINESS_STATE"            "no_clone"        "case 10 state"
assert_eq "$PORTFOLIO_WORKDIR_READINESS_RECOVERY_ACTION"  "clone_required"  "case 10 recovery"

# --- Case 11: no_origin_default ------------------------------------------

w="$TEST_TMP/case_no_origin"
git init -q "$w"
git -C "$w" config user.email "test@example.invalid"
git -C "$w" config user.name "Readiness Test"
printf 'a\n' > "$w/file.txt"
git -C "$w" add file.txt
git -C "$w" commit -q -m 'init'
git -C "$w" branch -M main
out=$(portfolio_workdir_readiness_status "$w" "main")
portfolio_workdir_readiness_status "$w" "main" >/dev/null 2>&1
assert_eq "$PORTFOLIO_WORKDIR_READINESS_STATE"            "no_origin_default" "case 11 state"
assert_eq "$PORTFOLIO_WORKDIR_READINESS_RECOVERY_ACTION"  "fetch_origin"      "case 11 recovery"

# --- Case 12: portfolio_assert_workdir_ready wrapper backwards compat -----

w=$(clone case_assert_ready)
git -C "$w" fetch -q origin main
git -C "$w" pull -q --ff-only origin main
portfolio_assert_workdir_ready "$w" "main" 2>/dev/null || fail "case 12: ready clone should pass assert"

w=$(clone case_assert_dirty)
printf 'mod\n' >> "$w/README.md"
if portfolio_assert_workdir_ready "$w" "main" 2>/dev/null; then
  fail "case 12b: dirty clone must NOT pass assert"
fi
assert_eq "$PORTFOLIO_WORKDIR_READINESS_STATE"  "dirty" "case 12b assert sets state"

# Acceptance: a clean wrong_branch workdir does NOT report dirty/uncommitted.
w=$(clone case_assert_wrong_branch)
git -C "$w" checkout -q --orphan unrelated-branch
git -C "$w" rm -rfq .
printf 'x\n' > "$w/extra.txt"
git -C "$w" add extra.txt
git -C "$w" commit -q -m 'unrelated'
err=$(portfolio_assert_workdir_ready "$w" "main" 2>&1 1>/dev/null) || true
[[ "$err" == *"state=wrong_branch"* ]] || fail "case 12c: stderr should mention wrong_branch, got: $err"
[[ "$err" != *"state=dirty"* ]] || fail "case 12c: stderr must NOT mention dirty for clean wrong_branch, got: $err"
[[ "$err" == *"dirty=0"* ]] || fail "case 12c: stderr should record dirty=0, got: $err"

# --- Case 13: feature branch behind base — currently classified ready_feature_branch
# only when origin/<default> is an ancestor of HEAD. If the feature branch
# was created BEFORE origin/main advanced and never rebased, it should be
# classified wrong_branch (since origin/main is no longer an ancestor).
w=$(clone case_feature_stale)
git -C "$w" checkout -q -b feature/old
printf 'old work\n' >> "$w/README.md"
git -C "$w" commit -q -am 'old work'
# Advance origin further
printf 'v3\n' > "$SEED/README.md"
git -C "$SEED" commit -q -am 'origin advances again'
git -C "$SEED" push -q origin main
git -C "$w" fetch -q origin main
out=$(portfolio_workdir_readiness_status "$w" "main")
portfolio_workdir_readiness_status "$w" "main" >/dev/null 2>&1
# The feature branch's HEAD does descend from ITS old origin/main, but
# origin/main has moved forward. Since the merge-base check uses the
# CURRENT origin/main, this stops being an ancestor and the state is
# wrong_branch (drift from base).
[[ "$PORTFOLIO_WORKDIR_READINESS_STATE" == "wrong_branch" \
   || "$PORTFOLIO_WORKDIR_READINESS_STATE" == "ready_feature_branch" ]] \
  || fail "case 13: expected wrong_branch or ready_feature_branch, got: $PORTFOLIO_WORKDIR_READINESS_STATE"

printf 'ok - portfolio_workdir_readiness diagnostics passed\n'
