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

mkdir -p "$SANITIZED_ROOT/scripts" "$SANITIZED_ROOT/lib" "$SANITIZED_ROOT/examples" "$TEST_TMP/bin" "$TEST_TMP/repos" "$TEST_TMP/configs"

for rel in \
  scripts/agent_product_switch.sh \
  lib/agent_inventory.sh \
  lib/config_resolver.sh \
  lib/dry_run.sh \
  lib/portfolio_config.sh
do
  tr -d '\r' < "$ROOT/$rel" > "$SANITIZED_ROOT/$rel"
done
chmod +x "$SANITIZED_ROOT/scripts/agent_product_switch.sh"

make_repo() {
  local repo=$1
  git init -q "$repo"
  git -C "$repo" config user.email test@example.invalid
  git -C "$repo" config user.name "Switch Test"
  printf 'init\n' > "$repo/file.txt"
  git -C "$repo" add file.txt
  git -C "$repo" commit -q -m 'init'
  git -C "$repo" branch -M main
}

source_repo="$TEST_TMP/repos/source"
target_repo="$TEST_TMP/repos/target"
make_repo "$source_repo"
make_repo "$target_repo"

cat > "$TEST_TMP/configs/source.config.sh" <<EOF
PROJECT="source"
GH_REPO="example/source"
DEFAULT_BRANCH="main"
GH_CONFIG_DIR="$TEST_TMP/gh"
AGENT_REPO_PREFIX="$TEST_TMP/repos/source-"
export AGENT_WORKDIR_TEMPLATE="$TEST_TMP/repos/source-%s"
AGENT_PANES=(
  "worker|shared:0.0|$source_repo"
)
EOF

cat > "$TEST_TMP/configs/target.config.sh" <<EOF
PROJECT="target"
GH_REPO="example/target"
DEFAULT_BRANCH="main"
GH_CONFIG_DIR="$TEST_TMP/gh"
AGENT_REPO_PREFIX="$TEST_TMP/repos/target-"
export AGENT_WORKDIR_TEMPLATE="$TEST_TMP/repos/target-%s"
AGENT_PANES=(
  "worker|shared:0.0|$target_repo"
)
EOF

cat > "$TEST_TMP/configs/portfolio.config.sh" <<EOF
PORTFOLIO_NAME="test"
PORTFOLIO_PROJECTS=(
  "source|$TEST_TMP/configs/source.config.sh"
  "target|$TEST_TMP/configs/target.config.sh"
)
EOF

cat > "$TEST_TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *"pr list"* && "$*" == *"feat/done"* ]]; then
  printf '%s\n' '[{"number":44,"mergeStateStatus":"BLOCKED"}]'
else
  printf '%s\n' '[]'
fi
EOF
chmod +x "$TEST_TMP/bin/gh"

free_output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  bash "$SANITIZED_ROOT/scripts/agent_product_switch.sh" "$TEST_TMP/configs/portfolio.config.sh" source worker target --dry-run
)
[[ "$free_output" == *'DRY-RUN: switch mode=hard pane=shared:0.0 source=source/main state=free target=target/worker'* ]] || \
  fail "free switch dry-run unexpected: $free_output"

git -C "$source_repo" checkout -q -b feat/no-pr
printf 'work\n' > "$source_repo/work.txt"
git -C "$source_repo" add work.txt
git -C "$source_repo" commit -q -m 'work'

set +e
blocked_output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  bash "$SANITIZED_ROOT/scripts/agent_product_switch.sh" "$TEST_TMP/configs/portfolio.config.sh" source worker target --dry-run 2>&1
)
blocked_status=$?
set -e
[[ "$blocked_status" -eq 7 ]] || fail "branch without PR should be refused, got $blocked_status: $blocked_output"
[[ "$blocked_output" == *'branch-without-open-pr'* ]] || fail "missing refusal reason: $blocked_output"
[[ "$blocked_output" == *'DRY-RUN: portfolio unblock task'* ]] || fail "dry-run should surface unblock task: $blocked_output"
[[ ! -e "$TEST_TMP/state/_portfolio/unblock_tasks.json" ]] || fail "dry-run should not persist unblock tasks"

set +e
live_blocked_output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  bash "$SANITIZED_ROOT/scripts/agent_product_switch.sh" "$TEST_TMP/configs/portfolio.config.sh" source worker target 2>&1
)
live_blocked_status=$?
set -e
[[ "$live_blocked_status" -eq 7 ]] || fail "live unsafe switch should be refused, got $live_blocked_status: $live_blocked_output"
jq -e '.open | to_entries[] | select(.value.code == "source-branch-without-pr" and .value.recommended_action != "")' \
  "$TEST_TMP/state/_portfolio/unblock_tasks.json" >/dev/null \
  || fail "live unsafe switch should persist unblock JSON"
grep -q 'source-branch-without-pr' "$TEST_TMP/state/_portfolio/ORCH_TASKS.md" \
  || fail "live unsafe switch should persist orchestrator task list"

git -C "$source_repo" branch -m feat/done
parked_output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  bash "$SANITIZED_ROOT/scripts/agent_product_switch.sh" "$TEST_TMP/configs/portfolio.config.sh" source worker target --dry-run
)
[[ "$parked_output" == *'state=parked-pr'* ]] || fail "open PR branch should be parkable: $parked_output"
printf '%s\n' "$parked_output" | tail -1 | jq -e '.source_pr == 44 and .safe_state == "parked-pr" and .target_project == "target"' >/dev/null \
  || fail "switch JSON record missing trace fields: $parked_output"

soft_output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  bash "$SANITIZED_ROOT/scripts/agent_product_switch.sh" "$TEST_TMP/configs/portfolio.config.sh" source worker target --soft --dry-run
)
[[ "$soft_output" == *'DRY-RUN: soft workspace keeps pane=shared:0.0 and targets workdir='* ]] || \
  fail "soft switch should not respawn pane: $soft_output"
[[ "$soft_output" == *'DRY-RUN: write workspace contract'* ]] || \
  fail "soft switch should write workspace contract: $soft_output"
printf '%s\n' "$soft_output" | tail -1 | jq -e '.mode == "soft" and .brief_pane == "shared:0.0" and .strict_context == 1 and .target_dirty == 0' >/dev/null \
  || fail "soft switch JSON missing strict context fields: $soft_output"

git -C "$target_repo" checkout -q -b feat/occupied
set +e
occupied_target_output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  bash "$SANITIZED_ROOT/scripts/agent_product_switch.sh" "$TEST_TMP/configs/portfolio.config.sh" source worker target --soft --dry-run 2>&1
)
occupied_target_status=$?
set -e
[[ "$occupied_target_status" -eq 10 ]] || fail "soft switch should refuse non-default target branch, got $occupied_target_status: $occupied_target_output"
[[ "$occupied_target_output" == *'target branch is not default'* ]] || fail "missing occupied target reason: $occupied_target_output"

allowed_branch_output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  bash "$SANITIZED_ROOT/scripts/agent_product_switch.sh" "$TEST_TMP/configs/portfolio.config.sh" source worker target --soft --allow-target-branch --dry-run
)
printf '%s\n' "$allowed_branch_output" | tail -1 | jq -e '.allow_target_branch == 1 and .target_branch == "feat/occupied"' >/dev/null \
  || fail "allow-target-branch should be explicit in contract: $allowed_branch_output"

git -C "$target_repo" checkout -q main
printf 'dirty-target\n' > "$target_repo/dirty.txt"
set +e
dirty_target_output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  bash "$SANITIZED_ROOT/scripts/agent_product_switch.sh" "$TEST_TMP/configs/portfolio.config.sh" source worker target --soft --dry-run 2>&1
)
dirty_target_status=$?
set -e
[[ "$dirty_target_status" -eq 9 ]] || fail "soft switch should refuse dirty target, got $dirty_target_status: $dirty_target_output"
[[ "$dirty_target_output" == *'target workdir dirty'* ]] || fail "missing dirty target reason: $dirty_target_output"

printf 'ok - agent_product_switch refuses unsafe work and parks PR branches\n'
