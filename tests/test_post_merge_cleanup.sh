#!/usr/bin/env bash
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

mkdir -p "$SANITIZED_ROOT/scripts" "$SANITIZED_ROOT/lib" "$TEST_TMP/bin" "$TEST_TMP/repos" "$TEST_TMP/logs"

for rel in \
  scripts/post_merge_cleanup.sh \
  lib/agent_inventory.sh \
  lib/audit_log.sh \
  lib/closure_acceptance.sh \
  lib/config_check.sh \
  lib/config_resolver.sh \
  lib/dry_run.sh \
  lib/external_mutation_gate.sh \
  lib/log_bounds.sh \
  lib/process_safety.sh \
  lib/state_persist.sh \
  lib/tmux_helpers.sh \
  lib/ordo_contracts.sh \
  lib/ordo_provider_adapter.sh \
  lib/ordo_provider_adapter_github.sh \
  lib/ordo_provider_adapter_fake.sh
do
  tr -d '\r' < "$ROOT/$rel" > "$SANITIZED_ROOT/$rel"
done
chmod +x "$SANITIZED_ROOT/scripts/post_merge_cleanup.sh"

configure_git() {
  local repo=$1
  git -C "$repo" config user.email test@example.invalid
  git -C "$repo" config user.name "Post Merge Cleanup Test"
}

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
linked_parent="$TEST_TMP/repos/linked-parent"
linked_worktree="$TEST_TMP/state/post-merge-test/worktrees/linked-agent/feat-issue-44"
stale_main_parent="$TEST_TMP/repos/stale-main-parent"
stale_main_default_holder="$TEST_TMP/state/post-merge-test/default-holders/stale-main-agent/main"
stale_dirty_holder_parent="$TEST_TMP/repos/stale-dirty-holder-parent"
stale_dirty_default_holder="$TEST_TMP/state/post-merge-test/default-holders/stale-dirty-holder-agent/main"
git clone -q "$remote_repo" "$clean_clone"
git clone -q "$remote_repo" "$dirty_clone"
git clone -q "$remote_repo" "$linked_parent"
git clone -q "$remote_repo" "$stale_main_parent"
git clone -q "$remote_repo" "$stale_dirty_holder_parent"
configure_git "$clean_clone"
configure_git "$dirty_clone"
configure_git "$linked_parent"
configure_git "$stale_main_parent"
configure_git "$stale_dirty_holder_parent"

git -C "$clean_clone" checkout -q -b feat/issue-42
printf 'feature\n' > "$clean_clone/feature.txt"
git -C "$clean_clone" add feature.txt
git -C "$clean_clone" commit -q -m 'feature work'

git -C "$dirty_clone" checkout -q -b feat/dirty
printf 'dirty\n' > "$dirty_clone/dirty.txt"

mkdir -p "$(dirname "$linked_worktree")"
git -C "$linked_parent" worktree add -q -b feat/issue-44 "$linked_worktree" origin/main
configure_git "$linked_worktree"
[[ -f "$linked_worktree/.git" ]] \
  || fail "linked worktree fixture should use a .git file"
[[ "$(git -C "$linked_parent" branch --show-current)" == "main" ]] \
  || fail "linked parent should keep main checked out to reserve the default branch"

git -C "$stale_main_parent" checkout -q -b feat/issue-45
printf 'feature 45\n' > "$stale_main_parent/feature-45.txt"
git -C "$stale_main_parent" add feature-45.txt
git -C "$stale_main_parent" commit -q -m 'feature 45'
mkdir -p "$(dirname "$stale_main_default_holder")"
git -C "$stale_main_parent" worktree add -q "$stale_main_default_holder" main
configure_git "$stale_main_default_holder"
[[ "$(git -C "$stale_main_parent" branch --show-current)" == "feat/issue-45" ]] \
  || fail "stale main cleanup repo should stay on its merged branch"
[[ "$(git -C "$stale_main_default_holder" branch --show-current)" == "main" ]] \
  || fail "stale main holder should keep main checked out"
[[ -f "$stale_main_default_holder/.git" ]] \
  || fail "stale main holder fixture should use a .git file"

git -C "$stale_dirty_holder_parent" checkout -q -b feat/issue-46
printf 'feature 46\n' > "$stale_dirty_holder_parent/feature-46.txt"
git -C "$stale_dirty_holder_parent" add feature-46.txt
git -C "$stale_dirty_holder_parent" commit -q -m 'feature 46'
mkdir -p "$(dirname "$stale_dirty_default_holder")"
git -C "$stale_dirty_holder_parent" worktree add -q "$stale_dirty_default_holder" main
configure_git "$stale_dirty_default_holder"
[[ "$(git -C "$stale_dirty_holder_parent" branch --show-current)" == "feat/issue-46" ]] \
  || fail "stale dirty cleanup repo should stay on its merged branch"
[[ "$(git -C "$stale_dirty_default_holder" branch --show-current)" == "main" ]] \
  || fail "stale dirty holder should keep main checked out"
[[ -f "$stale_dirty_default_holder/.git" ]] \
  || fail "stale dirty holder fixture should use a .git file"
printf 'operator notes\n' > "$stale_dirty_default_holder/operator-notes.txt"

printf 'v2\n' > "$seed_repo/file.txt"
git -C "$seed_repo" add file.txt
git -C "$seed_repo" commit -q -m 'default update'
git -C "$seed_repo" push -q origin main

cat > "$TEST_TMP/config.sh" <<EOF
PROJECT="post-merge-test"
GH_REPO="example/repo"
GH_CONFIG_DIR="$TEST_TMP/gh"
DEFAULT_BRANCH="main"
REPO_URL="$remote_repo"
AGENT_WORKDIR_TEMPLATE="$TEST_TMP/repos/%s"
AGENT_PANES=(
  "clean-agent|clean-agent:0.0|$clean_clone"
  "dirty-agent|dirty-agent:0.0|$dirty_clone"
)
EOF

cat > "$TEST_TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"pr view 42"* )
    printf '%s\n' '{"number":42,"state":"MERGED","headRefName":"feat/issue-42","headRefOid":"abc","baseRefName":"main","mergedAt":"2026-01-01T00:00:00Z"}'
    ;;
  *"pr view 43"* )
    printf '%s\n' '{"number":43,"state":"MERGED","headRefName":"feat/dirty","headRefOid":"def","baseRefName":"main","mergedAt":"2026-01-01T00:00:00Z"}'
    ;;
  *"pr view 44"* )
    printf '%s\n' '{"number":44,"state":"MERGED","headRefName":"feat/issue-44","headRefOid":"ghi","baseRefName":"main","mergedAt":"2026-01-01T00:00:00Z"}'
    ;;
  *"pr view 45"* )
    printf '%s\n' '{"number":45,"state":"MERGED","headRefName":"feat/issue-45","headRefOid":"jkl","baseRefName":"main","mergedAt":"2026-01-01T00:00:00Z"}'
    ;;
  *"pr view 46"* )
    printf '%s\n' '{"number":46,"state":"MERGED","headRefName":"feat/issue-46","headRefOid":"mno","baseRefName":"main","mergedAt":"2026-01-01T00:00:00Z"}'
    ;;
  *"repo view RBOKproject/realisons-wordpress"*defaultBranchRef* )
    printf '%s\n' '{"defaultBranchRef":{"name":"main"}}'
    ;;
  *"repo view example/repo"*defaultBranchRef* )
    printf '%s\n' '{"defaultBranchRef":{"name":"main"}}'
    ;;
  *"pr view 47"* )
    # PR body carries a closure_acceptance_gate proof block so the WordPress
    # auto-close path stays green under both ORCH_CLOSURE_GATE_ENFORCE=0
    # (default, gate skipped) and ORCH_CLOSURE_GATE_ENFORCE=1 (gate must
    # pass). Issue #754: fixtures must cover both modes.
    printf '%s\n' '{"number":47,"title":"Ship WordPress work","body":"Closes #646\n\n```acceptance\n- Hard-gate test passes against merged commit — artifact: run-id:hg-2026-05-19-z\n- Widget renders on every V2 surface — evidence: https://audit.test/v2/r.html\n```","url":"https://example.test/pull/47","state":"MERGED","headRefName":"feat/issue-646","headRefOid":"pqr","baseRefName":"develop","mergedAt":"2026-01-01T00:00:00Z","mergeCommit":{"oid":"merge47"},"closingIssuesReferences":[]}'
    ;;
  *"pr view 48"* )
    printf '%s\n' '{"number":48,"title":"Ship other repo work","body":"Closes #648\n\n```acceptance\n- Hard-gate test passes against merged commit — artifact: run-id:hg-2026-05-19-z\n- Widget renders on every V2 surface — evidence: https://audit.test/v2/r.html\n```","url":"https://example.test/pull/48","state":"MERGED","headRefName":"feat/issue-648","headRefOid":"stu","baseRefName":"develop","mergedAt":"2026-01-01T00:00:00Z","mergeCommit":{"oid":"merge48"},"closingIssuesReferences":[]}'
    ;;
  *"issue view 646"* )
    printf '%s\n' '{"body":"## Acceptance Criteria\n\n- [ ] Hard-gate test re-runs clean against the merged commit.\n- [ ] Widget renders on every V2 surface listed in the audit.\n"}'
    ;;
  *"issue view 648"* )
    printf '%s\n' '{"body":"## Acceptance Criteria\n\n- [ ] Hard-gate test re-runs clean against the merged commit.\n- [ ] Widget renders on every V2 surface listed in the audit.\n"}'
    ;;
  *"issue close 646"* )
    printf '%s\n' "$*" >> "$ORCH_LOG_DIR/gh-wordpress-close.log"
    comment=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --comment)
          comment=${2:-}
          shift 2
          ;;
        *)
          shift
          ;;
      esac
    done
    printf '%s\n' "$comment" > "$ORCH_LOG_DIR/wordpress-close-comment.txt"
    printf '%s\n' '{"state":"CLOSED"}'
    ;;
  *"issue close 648"* )
    printf '%s\n' "$*" >> "$ORCH_LOG_DIR/non-wordpress-close.log"
    exit 99
    ;;
  * )
    printf '%s\n' '{}'
    ;;
esac
EOF
chmod +x "$TEST_TMP/bin/gh"

mkdir -p "$TEST_TMP/state/post-merge-test"
cat > "$TEST_TMP/state/post-merge-test/assignments.json" <<JSON
{
  "clean-agent": {
    "ticket": "42",
    "issue": 42,
    "branch": "feat/issue-42",
    "workdir": "$clean_clone",
    "repo_root": "$clean_clone",
    "prompt_file": "/tmp/dispatch-clean-agent-42.md",
    "dispatched_at": "2026-01-01T00:00:00Z"
  },
  "dirty-agent": {
    "ticket": "43",
    "issue": 43,
    "branch": "feat/dirty",
    "workdir": "$dirty_clone",
    "repo_root": "$dirty_clone",
    "prompt_file": "/tmp/dispatch-dirty-agent-43.md",
    "dispatched_at": "2026-01-01T00:00:00Z"
  },
  "linked-agent": {
    "ticket": "44",
    "issue": 44,
    "branch": "feat/issue-44",
    "workdir": "$linked_worktree",
    "repo_root": "$linked_worktree",
    "prompt_file": "/tmp/dispatch-linked-agent-44.md",
    "dispatched_at": "2026-01-01T00:00:00Z"
  },
  "stale-main-agent": {
    "ticket": "45",
    "issue": 45,
    "branch": "feat/issue-45",
    "workdir": "$stale_main_parent",
    "repo_root": "$stale_main_parent",
    "prompt_file": "/tmp/dispatch-stale-main-agent-45.md",
    "dispatched_at": "2026-01-01T00:00:00Z"
  },
  "stale-dirty-holder-agent": {
    "ticket": "46",
    "issue": 46,
    "branch": "feat/issue-46",
    "workdir": "$stale_dirty_holder_parent",
    "repo_root": "$stale_dirty_holder_parent",
    "prompt_file": "/tmp/dispatch-stale-dirty-holder-agent-46.md",
    "dispatched_at": "2026-01-01T00:00:00Z"
  }
}
JSON

cleanup_output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  bash "$SANITIZED_ROOT/scripts/post_merge_cleanup.sh" "$TEST_TMP/config.sh" 42 --json
)

printf '%s\n' "$cleanup_output" | jq -e '
  .[]
  | select(.pr == 42
      and .agent == "clean-agent"
      and .action == "cleanup"
      and .status == "ok"
      and (.detail | contains("assignment_cleared=1")))
' >/dev/null || fail "clean merged worktree should be cleaned: $cleanup_output"

[[ "$(git -C "$clean_clone" branch --show-current)" == "main" ]] \
  || fail "clean clone should return to main"
[[ "$(cat "$clean_clone/file.txt")" == "v2" ]] \
  || fail "clean clone main should fast-forward to origin/main"
jq -e 'has("clean-agent") | not' "$TEST_TMP/state/post-merge-test/assignments.json" >/dev/null \
  || fail "clean assignment should be cleared"
jq -e 'has("dirty-agent")' "$TEST_TMP/state/post-merge-test/assignments.json" >/dev/null \
  || fail "unrelated assignment should remain"
jq -e 'has("linked-agent")' "$TEST_TMP/state/post-merge-test/assignments.json" >/dev/null \
  || fail "linked worktree assignment should remain before its cleanup"

linked_output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  bash "$SANITIZED_ROOT/scripts/post_merge_cleanup.sh" "$TEST_TMP/config.sh" 44 --json
)

printf '%s\n' "$linked_output" | jq -e '
  .[]
  | select(.pr == 44
      and .agent == "linked-agent"
      and .action == "cleanup"
      and .status == "ok"
      and (.detail | contains("assignment_cleared=1")))
' >/dev/null || fail "valid linked worktree should be cleaned, not reported as not_git_repo: $linked_output"

[[ -z "$(git -C "$linked_worktree" branch --show-current)" ]] \
  || fail "linked worktree should park detached instead of checking out main"
[[ "$(cat "$linked_worktree/file.txt")" == "v2" ]] \
  || fail "linked worktree detached HEAD should use origin/main content"
[[ "$(git -C "$linked_parent" branch --show-current)" == "main" ]] \
  || fail "linked parent should remain on main"
jq -e 'has("linked-agent") | not' "$TEST_TMP/state/post-merge-test/assignments.json" >/dev/null \
  || fail "linked worktree assignment should be cleared"
jq -e 'has("stale-main-agent")' "$TEST_TMP/state/post-merge-test/assignments.json" >/dev/null \
  || fail "stale-main assignment should remain before its cleanup"

stale_main_output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  bash "$SANITIZED_ROOT/scripts/post_merge_cleanup.sh" "$TEST_TMP/config.sh" 45 --json
)

printf '%s\n' "$stale_main_output" | jq -e '
  .[]
  | select(.pr == 45
      and .agent == "stale-main-agent"
      and .action == "warning"
      and .status == "ok"
      and .reason == "stale_main_holder")
' >/dev/null || fail "stale main holder should be reported as a warning: $stale_main_output"

printf '%s\n' "$stale_main_output" | jq -e '
  .[]
  | select(.pr == 45
      and .agent == "stale-main-agent"
      and .action == "cleanup"
      and .status == "ok"
      and (.detail | contains("assignment_cleared=1"))
      and (.detail | contains("default_checkout=skipped_default_branch_in_use")))
' >/dev/null || fail "stale main holder should not block assignment cleanup: $stale_main_output"

[[ "$(git -C "$stale_main_default_holder" branch --show-current)" == "main" ]] \
  || fail "stale main holder should remain on main"
[[ "$(git -C "$stale_main_parent" branch --show-current)" == "feat/issue-45" ]] \
  || fail "stale-main cleanup repo should remain on its merged branch"
jq -e 'has("stale-main-agent") | not' "$TEST_TMP/state/post-merge-test/assignments.json" >/dev/null \
  || fail "stale-main assignment should be cleared"
jq -e 'has("stale-dirty-holder-agent")' "$TEST_TMP/state/post-merge-test/assignments.json" >/dev/null \
  || fail "stale dirty holder assignment should remain before its cleanup"

stale_dirty_holder_output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  bash "$SANITIZED_ROOT/scripts/post_merge_cleanup.sh" "$TEST_TMP/config.sh" 46 --json
)

printf '%s\n' "$stale_dirty_holder_output" | jq -e '
  .[]
  | select(.pr == 46
      and .agent == "stale-dirty-holder-agent"
      and .action == "skip"
      and .status == "blocked"
      and .reason == "stale_dirty_default_branch_holder"
      and (.detail | contains("default_branch=main"))
      and (.detail | contains("holder_branch=main"))
      and (.detail | contains("holder_dirty=1"))
      and (.detail | contains("recovery=preserve_archive_or_recover")))
' >/dev/null || fail "dirty default-branch holder should block cleanup with actionable evidence: $stale_dirty_holder_output"

[[ "$(git -C "$stale_dirty_default_holder" branch --show-current)" == "main" ]] \
  || fail "stale dirty holder should remain on main"
[[ -f "$stale_dirty_default_holder/operator-notes.txt" ]] \
  || fail "stale dirty holder file should remain untouched"
[[ "$(git -C "$stale_dirty_holder_parent" branch --show-current)" == "feat/issue-46" ]] \
  || fail "stale dirty cleanup repo should remain on its merged branch"
jq -e 'has("stale-dirty-holder-agent")' "$TEST_TMP/state/post-merge-test/assignments.json" >/dev/null \
  || fail "stale dirty holder assignment should remain for operator recovery"

dirty_output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  bash "$SANITIZED_ROOT/scripts/post_merge_cleanup.sh" "$TEST_TMP/config.sh" 43 --json
)

printf '%s\n' "$dirty_output" | jq -e '
  .[]
  | select(.pr == 43
      and .agent == "dirty-agent"
      and .action == "skip"
      and .status == "blocked"
      and .reason == "dirty_worktree")
' >/dev/null || fail "dirty merged worktree should be blocked, not cleaned: $dirty_output"
[[ "$(git -C "$dirty_clone" branch --show-current)" == "feat/dirty" ]] \
  || fail "dirty clone branch must not be switched"
jq -e 'has("dirty-agent")' "$TEST_TMP/state/post-merge-test/assignments.json" >/dev/null \
  || fail "dirty assignment should remain for operator cleanup"

cat > "$TEST_TMP/wp.config.sh" <<EOF
PROJECT="wordpress-post-merge-test"
GH_REPO="RBOKproject/realisons-wordpress"
GH_CONFIG_DIR="$TEST_TMP/gh"
DEFAULT_BRANCH="develop"
REPO_URL="$remote_repo"
AGENT_WORKDIR_TEMPLATE="$TEST_TMP/repos/%s"
AGENT_PANES=()
EOF

wordpress_output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  ORCH_EXTERNAL_PR_MUTATIONS=issue_close \
  bash "$SANITIZED_ROOT/scripts/post_merge_cleanup.sh" "$TEST_TMP/wp.config.sh" 47 --json
)

printf '%s\n' "$wordpress_output" | jq -e '
  .[]
  | select(.pr == 47
      and .action == "issue_reconcile"
      and .status == "ok"
      and .reason == "closed"
      and (.detail | contains("issue=#646"))
      and (.detail | contains("base=develop"))
      and (.detail | contains("repo_default=main")))
' >/dev/null || fail "WordPress non-default merge should close referenced issue: $wordpress_output"

grep -q "issue close 646 --repo RBOKproject/realisons-wordpress --reason completed" "$TEST_TMP/logs/gh-wordpress-close.log" \
  || fail "WordPress reconciliation must close the referenced issue"
grep -q "default branch is main" "$TEST_TMP/logs/wordpress-close-comment.txt" \
  || fail "close comment should explain why GitHub did not auto-close"

cat > "$TEST_TMP/nonwp.config.sh" <<EOF
PROJECT="nonwordpress-post-merge-test"
GH_REPO="example/repo"
GH_CONFIG_DIR="$TEST_TMP/gh"
DEFAULT_BRANCH="develop"
REPO_URL="$remote_repo"
AGENT_WORKDIR_TEMPLATE="$TEST_TMP/repos/%s"
AGENT_PANES=()
EOF

nonwordpress_output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  ORCH_EXTERNAL_PR_MUTATIONS=issue_close \
  bash "$SANITIZED_ROOT/scripts/post_merge_cleanup.sh" "$TEST_TMP/nonwp.config.sh" 48 --json
)

printf '%s\n' "$nonwordpress_output" | jq -e '
  all(.[]; .action != "issue_reconcile")
' >/dev/null || fail "auto policy must stay off for non-WordPress repos: $nonwordpress_output"
[[ ! -e "$TEST_TMP/logs/non-wordpress-close.log" ]] \
  || fail "non-WordPress auto policy must not call issue close"

# Issue #754: closure_acceptance_gate enforce-mode coverage.
#
# These two scenarios set ORCH_CLOSURE_GATE_ENFORCE=1 EXPLICITLY in the
# invocation so they exercise the enforce path regardless of whether the
# outer test was launched with the env var set (which is how the dispatch's
# validation_command also runs the test in enforce mode).
#
# Scenario A — gate-pass: PR body carries a valid acceptance proof block
# matching the source issue's DoD; close must proceed.
# Scenario B — CLOSURE_REFUSED: PR body lacks the acceptance block; the
# gate must refuse the close (no gh issue close mutation), and the audit
# log must record CLOSURE_REFUSED.
gate_gh_bin="$TEST_TMP/bin_gate"
mkdir -p "$gate_gh_bin"
cat > "$gate_gh_bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"pr view 49"* )
    printf '%s\n' '{"number":49,"title":"feat: with proof","body":"Closes #749\n\n```acceptance\n- Hard-gate test passes against merged commit — artifact: run-id:hg-2026-05-19-z\n- Widget renders on every V2 surface — evidence: https://audit.test/v2/r.html\n```","url":"https://example.test/pull/49","state":"MERGED","headRefName":"feat/issue-749","headRefOid":"sha49","baseRefName":"develop","mergedAt":"2026-01-01T00:00:00Z","mergeCommit":{"oid":"merge49"},"closingIssuesReferences":[]}'
    ;;
  *"pr view 50"* )
    printf '%s\n' '{"number":50,"title":"feat: no proof","body":"Closes #750\n\nNo acceptance block here.","url":"https://example.test/pull/50","state":"MERGED","headRefName":"feat/issue-750","headRefOid":"sha50","baseRefName":"develop","mergedAt":"2026-01-01T00:00:00Z","mergeCommit":{"oid":"merge50"},"closingIssuesReferences":[]}'
    ;;
  *"issue view 749"* )
    printf '%s\n' '{"body":"## Acceptance Criteria\n\n- [ ] Hard-gate test re-runs clean against the merged commit.\n- [ ] Widget renders on every V2 surface listed in the audit.\n"}'
    ;;
  *"issue view 750"* )
    printf '%s\n' '{"body":"## Acceptance Criteria\n\n- [ ] Hard-gate test re-runs clean against the merged commit.\n- [ ] Widget renders on every V2 surface listed in the audit.\n"}'
    ;;
  *"repo view RBOKproject/realisons-wordpress"*defaultBranchRef* )
    printf '%s\n' '{"defaultBranchRef":{"name":"main"}}'
    ;;
  *"issue close 749"* | *"issue close 750"* )
    printf '%s\n' "$*" >> "$ORCH_LOG_DIR/gate-issue-close-attempts.log"
    printf '%s\n' '{"state":"CLOSED"}'
    ;;
  * )
    printf '%s\n' '{}'
    ;;
esac
EOF
chmod +x "$gate_gh_bin/gh"

mkdir -p "$TEST_TMP/state/wordpress-post-merge-test"
printf '%s\n' '{}' > "$TEST_TMP/state/wordpress-post-merge-test/assignments.json"
rm -f "$TEST_TMP/logs/gate-issue-close-attempts.log"

gate_pass_output=$(
  PATH="$gate_gh_bin:$PATH" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  ORCH_EXTERNAL_PR_MUTATIONS=issue_close \
  ORCH_CLOSURE_GATE_ENFORCE=1 \
  bash "$SANITIZED_ROOT/scripts/post_merge_cleanup.sh" "$TEST_TMP/wp.config.sh" 49 --json
)

printf '%s\n' "$gate_pass_output" | jq -e '
  .[]
  | select(.pr == 49
      and .action == "issue_reconcile"
      and .status == "ok"
      and .reason == "closed"
      and (.detail | contains("issue=#749")))
' >/dev/null || fail "ORCH_CLOSURE_GATE_ENFORCE=1 with valid acceptance block must close: $gate_pass_output"

grep -q "issue close 749" "$TEST_TMP/logs/gate-issue-close-attempts.log" \
  || fail "valid acceptance block must invoke gh issue close 749"
grep -q "CLOSURE_GATE pass issue=#749" "$TEST_TMP/logs/wordpress-post-merge-test.log" \
  || fail "audit log must record CLOSURE_GATE pass for issue #749"

rm -f "$TEST_TMP/logs/gate-issue-close-attempts.log"
gate_refused_output=$(
  PATH="$gate_gh_bin:$PATH" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  ORCH_EXTERNAL_PR_MUTATIONS=issue_close \
  ORCH_CLOSURE_GATE_ENFORCE=1 \
  bash "$SANITIZED_ROOT/scripts/post_merge_cleanup.sh" "$TEST_TMP/wp.config.sh" 50 --json
)

printf '%s\n' "$gate_refused_output" | jq -e '
  .[]
  | select(.pr == 50
      and .action == "issue_reconcile"
      and .status == "blocked"
      and .reason == "closure_refused"
      and (.detail | contains("issue=#750"))
      and (.detail | contains("outcome=refused"))
      and (.detail | contains("reason=missing-acceptance-proof"))
      and (.detail | contains("mode=enforce")))
' >/dev/null || fail "ORCH_CLOSURE_GATE_ENFORCE=1 without acceptance must emit CLOSURE_REFUSED: $gate_refused_output"

if [ -e "$TEST_TMP/logs/gate-issue-close-attempts.log" ] \
  && grep -q "issue close 750" "$TEST_TMP/logs/gate-issue-close-attempts.log"; then
  fail "lazy PR under enforce mode must NOT invoke gh issue close 750"
fi
grep -q "CLOSURE_REFUSED issue=#750" "$TEST_TMP/logs/wordpress-post-merge-test.log" \
  || fail "audit log must record CLOSURE_REFUSED for issue #750"

# Issue #643: cleanup should also discover live pane worktrees when the
# inventory workdir points to an orchestrator parent and the assignment
# state has already been cleared. The pane's #{pane_current_path} is the
# canonical signal — the same one `agent_pool_status.sh` uses for
# `live_pane_cwd` / `capacity_class`.
live_pane_orchestrator="$TEST_TMP/repos/live-pane-orchestrator"
live_pane_worktree="$TEST_TMP/repos/live-pane-worktree"
git clone -q "$remote_repo" "$live_pane_orchestrator"
git clone -q "$remote_repo" "$live_pane_worktree"
configure_git "$live_pane_orchestrator"
configure_git "$live_pane_worktree"
git -C "$live_pane_worktree" checkout -q -b feat/issue-47
printf 'feature 47\n' > "$live_pane_worktree/feature-47.txt"
git -C "$live_pane_worktree" add feature-47.txt
git -C "$live_pane_worktree" commit -q -m 'feature 47'

cat > "$TEST_TMP/config_live_pane.sh" <<EOF
PROJECT="post-merge-test"
GH_REPO="example/repo"
GH_CONFIG_DIR="$TEST_TMP/gh"
DEFAULT_BRANCH="main"
REPO_URL="$remote_repo"
AGENT_WORKDIR_TEMPLATE="$TEST_TMP/repos/%s"
AGENT_PANES=(
  "live-pane-agent|live-pane-agent:0.0|$live_pane_orchestrator"
)
EOF

cat > "$TEST_TMP/bin/gh" <<EOF
#!/usr/bin/env bash
case "\$*" in
  *"pr view 47"* )
    printf '%s\n' '{"number":47,"state":"MERGED","headRefName":"feat/issue-47","headRefOid":"pqr","baseRefName":"main","mergedAt":"2026-01-01T00:00:00Z"}'
    ;;
  * )
    printf '%s\n' '{}'
    ;;
esac
EOF
chmod +x "$TEST_TMP/bin/gh"

cat > "$TEST_TMP/bin/tmux" <<EOF
#!/usr/bin/env bash
# Minimal stub: only display-message -p -t <pane> '#{pane_current_path}'
# is required for tmux_pane_current_path to work in this test.
if [[ "\$1" == "display-message" ]]; then
  while [[ "\$#" -gt 0 ]]; do
    case "\$1" in
      -t)
        target="\$2"
        shift 2
        ;;
      -p|-F) shift ;;
      *) shift ;;
    esac
  done
  case "\${target:-}" in
    live-pane-agent:0.0)
      printf '%s\n' '$live_pane_worktree'
      exit 0
      ;;
  esac
  exit 0
fi
exit 0
EOF
chmod +x "$TEST_TMP/bin/tmux"

# Assignment state already cleared (the bug scenario: post-merge cleanup
# of a later PR after the agent's assignment was removed by an earlier
# pass).
cat > "$TEST_TMP/state/post-merge-test/assignments.json" <<'JSON'
{}
JSON

live_pane_output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  bash "$SANITIZED_ROOT/scripts/post_merge_cleanup.sh" "$TEST_TMP/config_live_pane.sh" 47 --json
)

printf '%s\n' "$live_pane_output" | jq -e '
  .[]
  | select(.pr == 47
      and .agent == "live-pane-agent"
      and .action == "cleanup"
      and .status == "ok"
      and (.detail | contains("source=live_pane")))
' >/dev/null || fail "live pane worktree should be discovered when inventory workdir is the orchestrator parent: $live_pane_output"

[[ "$(git -C "$live_pane_worktree" branch --show-current)" == "main" ]] \
  || fail "live pane worktree should return to main"
[[ "$(git -C "$live_pane_orchestrator" branch --show-current)" == "main" ]] \
  || fail "live pane orchestrator should remain on main"

printf 'ok - post_merge_cleanup parks clean merged worktrees and preserves blockers\n'
