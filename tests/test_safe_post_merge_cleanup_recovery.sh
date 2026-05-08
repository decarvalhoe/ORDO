#!/usr/bin/env bash
# tests/test_safe_post_merge_cleanup_recovery.sh — regression coverage
# for ORDO #374 (safe post-merge cleanup recovery before readiness
# escalation).
#
# Required scenarios from issue #374 acceptance:
#   1. clean merged-branch workdir becomes ready after cleanup +
#      portfolio session_start --apply (decision = applied);
#   2. dirty worktree is refused with operator_intervention_required;
#   3. PR not merged → no candidate, decision = no_candidates;
#   4. JSON output distinguishes safe_post_merge_cleanup_attempted,
#      safe_post_merge_cleanup_applied, and operator_intervention_required;
#   5. dry-run mode never mutates and never invokes session_start --apply.
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

mkdir -p "$SANITIZED_ROOT/scripts" "$SANITIZED_ROOT/lib" \
  "$TEST_TMP/bin" "$TEST_TMP/repos" "$TEST_TMP/logs" "$TEST_TMP/configs"

for rel in \
  scripts/safe_post_merge_cleanup_recovery.sh \
  scripts/post_merge_cleanup.sh \
  lib/agent_inventory.sh \
  lib/audit_log.sh \
  lib/config_check.sh \
  lib/config_resolver.sh \
  lib/dry_run.sh \
  lib/log_bounds.sh \
  lib/portfolio_config.sh \
  lib/process_safety.sh \
  lib/state_persist.sh
do
  tr -d '\r' < "$ROOT/$rel" > "$SANITIZED_ROOT/$rel"
done
chmod +x "$SANITIZED_ROOT/scripts/safe_post_merge_cleanup_recovery.sh" \
         "$SANITIZED_ROOT/scripts/post_merge_cleanup.sh"

configure_git() {
  local repo=$1
  git -C "$repo" config user.email test@example.invalid
  git -C "$repo" config user.name "Safe PMC Recovery Test"
}

# ---------------------------------------------------------------------------
# Build a tiny remote + three local clones representing three agents:
#   - clean-agent:  on a merged feature branch, clean worktree
#   - dirty-agent:  on a merged feature branch, with uncommitted changes
#   - open-agent:   on a feature branch whose PR is still OPEN
# ---------------------------------------------------------------------------
remote_repo="$TEST_TMP/remote.git"
seed_repo="$TEST_TMP/seed"
git init -q --bare "$remote_repo"
git init -q "$seed_repo"
configure_git "$seed_repo"
printf 'v1\n' > "$seed_repo/file.txt"
git -C "$seed_repo" add file.txt
git -C "$seed_repo" commit -q -m 'initial'
git -C "$seed_repo" branch -M main
git -C "$seed_repo" remote add origin "$remote_repo"
git -C "$seed_repo" push -q -u origin main
git -C "$remote_repo" symbolic-ref HEAD refs/heads/main

clean_clone="$TEST_TMP/repos/clean"
dirty_clone="$TEST_TMP/repos/dirty"
open_clone="$TEST_TMP/repos/open"
git clone -q "$remote_repo" "$clean_clone"
git clone -q "$remote_repo" "$dirty_clone"
git clone -q "$remote_repo" "$open_clone"
configure_git "$clean_clone"
configure_git "$dirty_clone"
configure_git "$open_clone"

git -C "$clean_clone" checkout -q -b feat/issue-42
printf 'feature\n' > "$clean_clone/feature.txt"
git -C "$clean_clone" add feature.txt
git -C "$clean_clone" commit -q -m 'feature work'

git -C "$dirty_clone" checkout -q -b feat/issue-43
printf 'pending\n' > "$dirty_clone/dirty.txt"
# leave dirty.txt UNTRACKED so `git status --porcelain` reports it.

git -C "$open_clone" checkout -q -b feat/issue-44
printf 'open\n' > "$open_clone/open.txt"
git -C "$open_clone" add open.txt
git -C "$open_clone" commit -q -m 'open work'

# Advance default branch on the remote so post_merge_cleanup has
# something to fast-forward into when it pulls.
printf 'v2\n' > "$seed_repo/file.txt"
git -C "$seed_repo" add file.txt
git -C "$seed_repo" commit -q -m 'default update'
git -C "$seed_repo" push -q origin main

# ---------------------------------------------------------------------------
# Project + portfolio config
# ---------------------------------------------------------------------------
cat > "$TEST_TMP/configs/alpha.config.sh" <<EOF
PROJECT="alpha-pmc-test"
GH_REPO="example/alpha"
GH_CONFIG_DIR="$TEST_TMP/gh"
DEFAULT_BRANCH="main"
REPO_URL="$remote_repo"
AGENT_WORKDIR_TEMPLATE="$TEST_TMP/repos/%s"
AGENT_PANES=(
  "clean-agent|clean-agent:0.0|$clean_clone"
  "dirty-agent|dirty-agent:0.0|$dirty_clone"
  "open-agent|open-agent:0.0|$open_clone"
)
EOF

cat > "$TEST_TMP/configs/portfolio.config.sh" <<EOF
PORTFOLIO_PROJECTS=(
  "alpha|$TEST_TMP/configs/alpha.config.sh"
)
PORTFOLIO_PRIORITIES=(
  "alpha=100"
)
EOF

# ---------------------------------------------------------------------------
# Stub gh (PR view + auth status). Pass-through every other call as {}.
# ---------------------------------------------------------------------------
cat > "$TEST_TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"pr view 42"* )
    printf '%s\n' '{"number":42,"state":"MERGED","headRefName":"feat/issue-42","headRefOid":"abc","baseRefName":"main","mergedAt":"2026-05-08T10:00:00Z"}'
    ;;
  *"pr view 43"* )
    printf '%s\n' '{"number":43,"state":"MERGED","headRefName":"feat/issue-43","headRefOid":"def","baseRefName":"main","mergedAt":"2026-05-08T10:00:00Z"}'
    ;;
  *"pr view 44"* )
    printf '%s\n' '{"number":44,"state":"OPEN","headRefName":"feat/issue-44","headRefOid":"ghi","baseRefName":"main","mergedAt":""}'
    ;;
  * )
    printf '%s\n' '{}'
    ;;
esac
EOF
chmod +x "$TEST_TMP/bin/gh"

# Stub portfolio_session_start so we can detect when the recovery
# script invoked it (apply phase) without depending on the real heavy
# session-start machinery.
cat > "$SANITIZED_ROOT/scripts/portfolio_session_start.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TEST_TMP/logs/session_start.log"
printf '%s\n' '{"applied":true,"stub":true}'
EOF
chmod +x "$SANITIZED_ROOT/scripts/portfolio_session_start.sh"

mkdir -p "$TEST_TMP/state/alpha-pmc-test"
cat > "$TEST_TMP/state/alpha-pmc-test/assignments.json" <<JSON
{
  "clean-agent": {
    "ticket": "42", "issue": 42,
    "branch": "feat/issue-42", "workdir": "$clean_clone",
    "repo_root": "$clean_clone",
    "prompt_file": "/tmp/dispatch-clean-agent-42.md",
    "dispatched_at": "2026-05-08T08:00:00Z"
  },
  "dirty-agent": {
    "ticket": "43", "issue": 43,
    "branch": "feat/issue-43", "workdir": "$dirty_clone",
    "repo_root": "$dirty_clone",
    "prompt_file": "/tmp/dispatch-dirty-agent-43.md",
    "dispatched_at": "2026-05-08T08:00:00Z"
  },
  "open-agent": {
    "ticket": "44", "issue": 44,
    "branch": "feat/issue-44", "workdir": "$open_clone",
    "repo_root": "$open_clone",
    "prompt_file": "/tmp/dispatch-open-agent-44.md",
    "dispatched_at": "2026-05-08T08:00:00Z"
  }
}
JSON

# ---------------------------------------------------------------------------
# Run 1 — dry-run mode (default).
# ---------------------------------------------------------------------------
set +e
dry_run_output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  bash "$SANITIZED_ROOT/scripts/safe_post_merge_cleanup_recovery.sh" \
    "$TEST_TMP/configs/portfolio.config.sh" --json --dry-run 2>&1
)
dry_run_status=$?
set -e

# Dry-run must NOT call session_start.
[[ ! -s "$TEST_TMP/logs/session_start.log" ]] \
  || fail "dry-run must not invoke portfolio_session_start: $(cat "$TEST_TMP/logs/session_start.log")"

# Dry-run with operator-intervention candidate (dirty-agent) returns
# exit 10. The clean-agent records as safe_post_merge_cleanup_attempted
# (no live cleanup yet); open-agent records as skip (pr_not_merged).
[[ "$dry_run_status" -eq 10 ]] \
  || fail "dry-run with one operator-intervention candidate should exit 10, got $dry_run_status: $dry_run_output"

# Extract the JSON line (audit lines also stream to stderr; output mixes them).
dry_json=$(printf '%s' "$dry_run_output" | grep -E '^\{' | tail -1)
[ -n "$dry_json" ] || fail "no JSON line in dry-run output: $dry_run_output"

jq -e '.decision == "operator_intervention_required" and .apply == false' \
  <<< "$dry_json" >/dev/null \
  || fail "dry-run decision mismatch: $dry_json"

# Per-candidate assertions.
jq -e '
  (.candidates[] | select(.agent == "clean-agent" and .action == "safe_post_merge_cleanup_attempted" and .applied == false))
  and (.candidates[] | select(.agent == "dirty-agent" and .action == "operator_intervention_required" and .block_reason == "dirty_worktree"))
  and (.candidates[] | select(.agent == "open-agent" and .action == "skip" and .block_reason == "pr_not_merged"))
' <<< "$dry_json" >/dev/null \
  || fail "dry-run candidate breakdown mismatch: $dry_json"

# Counts.
jq -e '.counts.attempted == 3 and .counts.applied == 0 and .counts.operator_intervention_required == 1' \
  <<< "$dry_json" >/dev/null \
  || fail "dry-run counts mismatch: $dry_json"

# Audit lines must distinguish the three states the issue requires.
[[ "$dry_run_output" == *"AUDIT LOG"*"SAFE_POST_MERGE_CLEANUP_ATTEMPTED"*"agent=clean-agent"* ]] \
  || fail "missing SAFE_POST_MERGE_CLEANUP_ATTEMPTED audit line for clean-agent: $dry_run_output"
[[ "$dry_run_output" == *"AUDIT LOG"*"OPERATOR_INTERVENTION_REQUIRED"*"agent=dirty-agent"*"reason=dirty_worktree"* ]] \
  || fail "missing OPERATOR_INTERVENTION_REQUIRED audit for dirty-agent: $dry_run_output"
[[ "$dry_run_output" == *"AUDIT LOG"*"SAFE_POST_MERGE_CLEANUP_DRY_RUN_OK"*"agent=clean-agent"* ]] \
  || fail "missing dry-run-OK audit for clean-agent: $dry_run_output"

# ---------------------------------------------------------------------------
# Run 2 — --apply: clean-agent's workdir becomes ready after cleanup
# AND portfolio_session_start --apply is invoked.
# ---------------------------------------------------------------------------
: > "$TEST_TMP/logs/session_start.log"

# Pre-apply assertion: clean-agent is on the merged feature branch.
pre_branch=$(git -C "$clean_clone" branch --show-current)
[[ "$pre_branch" == "feat/issue-42" ]] \
  || fail "pre-apply: clean-agent should be on feat/issue-42, got $pre_branch"

set +e
apply_output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  bash "$SANITIZED_ROOT/scripts/safe_post_merge_cleanup_recovery.sh" \
    "$TEST_TMP/configs/portfolio.config.sh" --json --apply 2>&1
)
apply_status=$?
set -e

# Apply mode still exits 10 because dirty-agent remains
# operator_intervention_required (the issue explicitly says the
# sequence "still refuses dirty worktrees and never touches
# business/out-of-scope projects").
[[ "$apply_status" -eq 10 ]] \
  || fail "--apply with one operator-intervention candidate should exit 10, got $apply_status: $apply_output"

apply_json=$(printf '%s' "$apply_output" | grep -E '^\{' | tail -1)
[ -n "$apply_json" ] || fail "no JSON line in apply output: $apply_output"

# Decision is operator_intervention_required because dirty-agent
# remains a blocker, even though clean-agent applied successfully.
# This matches the issue's "audit output distinguishes... applied vs
# operator_intervention_required" requirement.
jq -e '.decision == "operator_intervention_required" and .apply == true' \
  <<< "$apply_json" >/dev/null \
  || fail "apply decision mismatch: $apply_json"

# clean-agent's record MUST now read safe_post_merge_cleanup_applied
# with applied=true (the AC's main success path).
jq -e '
  (.candidates[] | select(.agent == "clean-agent"
    and .action == "safe_post_merge_cleanup_applied"
    and .applied == true))
  and (.candidates[] | select(.agent == "dirty-agent"
    and .action == "operator_intervention_required"
    and .block_reason == "dirty_worktree"))
  and (.candidates[] | select(.agent == "open-agent"
    and .action == "skip"
    and .block_reason == "pr_not_merged"))
' <<< "$apply_json" >/dev/null \
  || fail "apply candidate breakdown mismatch: $apply_json"

jq -e '.counts.applied == 1 and .counts.operator_intervention_required == 1' \
  <<< "$apply_json" >/dev/null \
  || fail "apply counts mismatch: $apply_json"

# Workdir state: clean-agent must now be on default branch and the
# remote's v2 update must be present (post_merge_cleanup pulled).
post_branch=$(git -C "$clean_clone" branch --show-current)
[[ "$post_branch" == "main" ]] \
  || fail "after apply, clean-agent should be on main, got $post_branch"
post_file=$(cat "$clean_clone/file.txt")
[[ "$post_file" == "v2" ]] \
  || fail "after apply, clean-agent should have remote v2 content, got $post_file"

# Assignment for clean-agent must have been cleared by the live
# post_merge_cleanup; dirty-agent + open-agent records must remain.
remaining=$(jq -r 'keys | sort | join(",")' < "$TEST_TMP/state/alpha-pmc-test/assignments.json")
[[ "$remaining" == "dirty-agent,open-agent" ]] \
  || fail "after apply, only dirty-agent and open-agent assignments should remain, got: $remaining"

# Apply mode MUST have invoked session_start --apply once.
[[ -s "$TEST_TMP/logs/session_start.log" ]] \
  || fail "--apply should invoke portfolio_session_start"
grep -q -- "--apply" "$TEST_TMP/logs/session_start.log" \
  || fail "session_start invocation should include --apply: $(cat "$TEST_TMP/logs/session_start.log")"

# Audit lines for the three required states must all be present.
[[ "$apply_output" == *"AUDIT LOG"*"SAFE_POST_MERGE_CLEANUP_ATTEMPTED"*"agent=clean-agent"* ]] \
  || fail "apply: missing SAFE_POST_MERGE_CLEANUP_ATTEMPTED audit for clean-agent"
[[ "$apply_output" == *"AUDIT LOG"*"SAFE_POST_MERGE_CLEANUP_APPLIED"*"agent=clean-agent"* ]] \
  || fail "apply: missing SAFE_POST_MERGE_CLEANUP_APPLIED audit for clean-agent"
[[ "$apply_output" == *"AUDIT LOG"*"OPERATOR_INTERVENTION_REQUIRED"*"agent=dirty-agent"* ]] \
  || fail "apply: missing OPERATOR_INTERVENTION_REQUIRED audit for dirty-agent"
[[ "$apply_output" == *"AUDIT LOG"*"SAFE_POST_MERGE_CLEANUP_SESSION_START_APPLIED"* ]] \
  || fail "apply: missing SAFE_POST_MERGE_CLEANUP_SESSION_START_APPLIED audit"

# ---------------------------------------------------------------------------
# Run 3 — empty assignments → decision=no_candidates, exit 0, no
# session_start.
# ---------------------------------------------------------------------------
printf '%s\n' '{}' > "$TEST_TMP/state/alpha-pmc-test/assignments.json"
: > "$TEST_TMP/logs/session_start.log"

set +e
empty_output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  bash "$SANITIZED_ROOT/scripts/safe_post_merge_cleanup_recovery.sh" \
    "$TEST_TMP/configs/portfolio.config.sh" --json --apply 2>&1
)
empty_status=$?
set -e

[[ "$empty_status" -eq 0 ]] \
  || fail "empty assignments should exit 0, got $empty_status: $empty_output"

empty_json=$(printf '%s' "$empty_output" | grep -E '^\{' | tail -1)
jq -e '.decision == "no_candidates" and .counts.attempted == 0' <<< "$empty_json" >/dev/null \
  || fail "empty assignments decision mismatch: $empty_json"

[[ ! -s "$TEST_TMP/logs/session_start.log" ]] \
  || fail "no_candidates path must not invoke session_start: $(cat "$TEST_TMP/logs/session_start.log")"

printf 'ok - safe_post_merge_cleanup_recovery applies clean merged-branch cleanup, refuses dirty worktrees, and audits the three required states (#374)\n'
