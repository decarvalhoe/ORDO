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
  lib/config_check.sh \
  lib/config_resolver.sh \
  lib/dry_run.sh \
  lib/log_bounds.sh \
  lib/process_safety.sh \
  lib/state_persist.sh
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
git clone -q "$remote_repo" "$clean_clone"
git clone -q "$remote_repo" "$dirty_clone"
configure_git "$clean_clone"
configure_git "$dirty_clone"

git -C "$clean_clone" checkout -q -b feat/issue-42
printf 'feature\n' > "$clean_clone/feature.txt"
git -C "$clean_clone" add feature.txt
git -C "$clean_clone" commit -q -m 'feature work'

git -C "$dirty_clone" checkout -q -b feat/dirty
printf 'dirty\n' > "$dirty_clone/dirty.txt"

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

printf 'ok - post_merge_cleanup parks clean merged worktrees and preserves blockers\n'
