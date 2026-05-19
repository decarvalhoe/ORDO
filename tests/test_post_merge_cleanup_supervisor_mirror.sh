#!/usr/bin/env bash
# Issue #501: post_merge_cleanup must not treat a supervisor/integration
# mirror that holds a foreign agent's merged branch as an owner. Cleanup
# may only act on the dispatched assignment owner, unless an explicit
# assignment maps the supervisor agent to the mirror workdir.
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
  "$TEST_TMP/bin" "$TEST_TMP/repos" "$TEST_TMP/logs"

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
  lib/tmux_helpers.sh
do
  if [ -f "$ROOT/$rel" ]; then
    tr -d '\r' < "$ROOT/$rel" > "$SANITIZED_ROOT/$rel"
  fi
done
chmod +x "$SANITIZED_ROOT/scripts/post_merge_cleanup.sh"

configure_git() {
  local repo=$1
  git -C "$repo" config user.email test@example.invalid
  git -C "$repo" config user.name "Post Merge Cleanup Supervisor Mirror Test"
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

worker_clone="$TEST_TMP/repos/worker"
supervisor_clone="$TEST_TMP/repos/supervisor"

git clone -q "$remote_repo" "$worker_clone"
git clone -q "$remote_repo" "$supervisor_clone"
configure_git "$worker_clone"
configure_git "$supervisor_clone"

# Worker actually owns the merged branch.
git -C "$worker_clone" checkout -q -b feat/issue-500
printf 'worker work\n' > "$worker_clone/feature.txt"
git -C "$worker_clone" add feature.txt
git -C "$worker_clone" commit -q -m 'worker feature'

# Supervisor integration mirror — same branch was copied in.
git -C "$supervisor_clone" checkout -q -b feat/issue-500
printf 'mirror copy\n' > "$supervisor_clone/mirror.txt"
git -C "$supervisor_clone" add mirror.txt
git -C "$supervisor_clone" commit -q -m 'mirror copy of feature'

# Advance the remote default branch so post-merge fast-forward has something
# meaningful to pull when it cleans the owner.
printf 'v2\n' > "$seed_repo/file.txt"
git -C "$seed_repo" add file.txt
git -C "$seed_repo" commit -q -m 'default update'
git -C "$seed_repo" push -q origin main

cat > "$TEST_TMP/config.sh" <<EOF
PROJECT="ordo-supervisor-mirror"
GH_REPO="example/repo"
GH_CONFIG_DIR="$TEST_TMP/gh"
DEFAULT_BRANCH="main"
REPO_URL="$remote_repo"
SUPERVISOR_REPO="$supervisor_clone"
AGENT_WORKDIR_TEMPLATE="$TEST_TMP/repos/%s"
AGENT_PANES=(
  "worker-agent|worker-agent:0.0|$worker_clone"
  "supervisor-agent|supervisor-agent:0.0|$supervisor_clone"
)
EOF

cat > "$TEST_TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"pr view 500"* )
    printf '%s\n' '{"number":500,"state":"MERGED","headRefName":"feat/issue-500","headRefOid":"abc","baseRefName":"main","mergedAt":"2026-05-10T00:00:00Z"}'
    ;;
  *)
    printf '%s\n' '{}'
    ;;
esac
EOF
chmod +x "$TEST_TMP/bin/gh"

# Only the worker has an assignment. The supervisor mirror is NOT recorded as
# owning the branch.
mkdir -p "$TEST_TMP/state/ordo-supervisor-mirror"
cat > "$TEST_TMP/state/ordo-supervisor-mirror/assignments.json" <<JSON
{
  "worker-agent": {
    "ticket": "500",
    "issue": 500,
    "branch": "feat/issue-500",
    "workdir": "$worker_clone",
    "repo_root": "$worker_clone",
    "prompt_file": "/tmp/dispatch-worker-agent-500.md",
    "dispatched_at": "2026-05-10T00:00:00Z"
  }
}
JSON

cleanup_output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  bash "$SANITIZED_ROOT/scripts/post_merge_cleanup.sh" "$TEST_TMP/config.sh" 500 --json
)

# Worker is the assignment owner and gets cleaned.
printf '%s\n' "$cleanup_output" | jq -e '
  .[]
  | select(.pr == 500
      and .agent == "worker-agent"
      and .action == "cleanup"
      and .status == "ok"
      and (.detail | contains("assignment_cleared=1")))
' >/dev/null || fail "worker assignment owner should be cleaned: $cleanup_output"

# Supervisor mirror is reported as a skip, NOT a cleanup.
printf '%s\n' "$cleanup_output" | jq -e '
  .[]
  | select(.pr == 500
      and .agent == "supervisor-agent"
      and .action == "skip"
      and .status == "not_applicable"
      and .reason == "supervisor_mirror"
      and (.detail | contains("source=inventory"))
      and (.detail | contains("branch=feat/issue-500")))
' >/dev/null || fail "supervisor mirror should be skipped, not cleaned: $cleanup_output"

# Supervisor mirror MUST NOT have a cleanup record.
if printf '%s\n' "$cleanup_output" | jq -e '
  .[]
  | select(.agent == "supervisor-agent" and .action == "cleanup")
' >/dev/null; then
  fail "supervisor mirror must not be cleaned: $cleanup_output"
fi

# State assertions: worker switched back to main, supervisor mirror untouched.
[[ "$(git -C "$worker_clone" branch --show-current)" == "main" ]] \
  || fail "worker clone should switch back to main"
[[ "$(cat "$worker_clone/file.txt")" == "v2" ]] \
  || fail "worker clone main should fast-forward to origin/main"
[[ "$(git -C "$supervisor_clone" branch --show-current)" == "feat/issue-500" ]] \
  || fail "supervisor mirror must remain on its mirrored branch"
[[ -f "$supervisor_clone/mirror.txt" ]] \
  || fail "supervisor mirror working tree must remain untouched"

# Assignment file: worker entry cleared, supervisor entry was never added so
# the file should now be empty.
jq -e 'has("worker-agent") | not' \
  "$TEST_TMP/state/ordo-supervisor-mirror/assignments.json" >/dev/null \
  || fail "worker assignment should be cleared"
jq -e 'has("supervisor-agent") | not' \
  "$TEST_TMP/state/ordo-supervisor-mirror/assignments.json" >/dev/null \
  || fail "supervisor agent must not appear in assignments"

# Explicit mirror mapping: when the supervisor agent has an assignment that
# resolves to the mirror workdir, cleanup should treat it as an owner and
# park it back to the default branch.
git -C "$supervisor_clone" checkout -q feat/issue-500
cat > "$TEST_TMP/state/ordo-supervisor-mirror/assignments.json" <<JSON
{
  "supervisor-agent": {
    "ticket": "501",
    "issue": 501,
    "branch": "feat/issue-501",
    "workdir": "$supervisor_clone",
    "repo_root": "$supervisor_clone",
    "prompt_file": "/tmp/dispatch-supervisor-agent-501.md",
    "dispatched_at": "2026-05-10T00:00:00Z"
  }
}
JSON

# Rename mirror branch to match the supervisor assignment and create the
# matching gh stub PR.
git -C "$supervisor_clone" branch -m feat/issue-500 feat/issue-501

cat > "$TEST_TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"pr view 501"* )
    printf '%s\n' '{"number":501,"state":"MERGED","headRefName":"feat/issue-501","headRefOid":"abc","baseRefName":"main","mergedAt":"2026-05-10T00:05:00Z"}'
    ;;
  *)
    printf '%s\n' '{}'
    ;;
esac
EOF
chmod +x "$TEST_TMP/bin/gh"

mapped_output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  bash "$SANITIZED_ROOT/scripts/post_merge_cleanup.sh" "$TEST_TMP/config.sh" 501 --json
)

printf '%s\n' "$mapped_output" | jq -e '
  .[]
  | select(.pr == 501
      and .agent == "supervisor-agent"
      and .action == "cleanup"
      and .status == "ok"
      and (.detail | contains("assignment_cleared=1")))
' >/dev/null || fail "explicit mirror mapping should be cleaned as an owner: $mapped_output"

# Supervisor mirror must NOT be skipped now that it owns the assignment.
if printf '%s\n' "$mapped_output" | jq -e '
  .[]
  | select(.agent == "supervisor-agent"
      and .action == "skip"
      and .reason == "supervisor_mirror")
' >/dev/null; then
  fail "explicit mirror mapping should not be marked supervisor_mirror skip: $mapped_output"
fi

printf 'ok - post_merge_cleanup respects supervisor mirror ownership boundary\n'
