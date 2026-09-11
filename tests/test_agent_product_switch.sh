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
  lib/portfolio_config.sh \
  lib/process_safety.sh \
  lib/worktree_helpers.sh \
  lib/external_mutation_gate.sh \
  lib/ordo_contracts.sh \
  lib/ordo_provider_adapter.sh \
  lib/ordo_provider_adapter_github.sh \
  lib/ordo_provider_adapter_fake.sh
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
target_matrix_repo="$TEST_TMP/repos/target-worker"
make_repo "$source_repo"
make_repo "$target_repo"
make_repo "$target_matrix_repo"

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

cat > "$TEST_TMP/configs/target-matrix.config.sh" <<EOF
PROJECT="matrix-target"
GH_REPO="example/matrix-target"
DEFAULT_BRANCH="main"
GH_CONFIG_DIR="$TEST_TMP/gh"
AGENT_REPO_PREFIX="$TEST_TMP/repos/target-"
export AGENT_WORKDIR_TEMPLATE="$TEST_TMP/repos/target-%s"
EOF

cat > "$TEST_TMP/configs/portfolio.config.sh" <<EOF
PORTFOLIO_NAME="test"
PORTFOLIO_PROJECTS=(
  "source|$TEST_TMP/configs/source.config.sh"
  "target|$TEST_TMP/configs/target.config.sh"
  "matrix-target|$TEST_TMP/configs/target-matrix.config.sh"
)
PORTFOLIO_ENSURE_AGENT_MATRIX=1
PORTFOLIO_FLEET_AGENTS=(
  "worker|shared:0.0"
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
# Issue #123: hard switch dry-run must announce the post-respawn readiness
# handshake so reviewers can confirm the gate is active.
[[ "$free_output" == *"DRY-RUN: agent_pane_ready shared:0.0 $target_repo retries="* ]] || \
  fail "hard dry-run should announce readiness handshake: $free_output"

# AGENT_SWITCH_VERIFY_READY=0 must opt out of the readiness handshake so
# legacy environments without tmux pane introspection can still drive the
# switch flow.
ready_off_output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  AGENT_SWITCH_VERIFY_READY=0 \
  bash "$SANITIZED_ROOT/scripts/agent_product_switch.sh" "$TEST_TMP/configs/portfolio.config.sh" source worker target --dry-run
)
[[ "$ready_off_output" == *'DRY-RUN: agent_pane_ready'* ]] && \
  fail "AGENT_SWITCH_VERIFY_READY=0 should suppress readiness handshake: $ready_off_output"
[[ "$ready_off_output" == *'DRY-RUN: tmux respawn-pane'* ]] || \
  fail "ready-off dry-run should still announce respawn: $ready_off_output"

# Issue #305: hard switch must surface launch-contract drift when the resolved
# launch command lacks the per-agent identity flags (--name, --debug-file,
# --append-system-prompt) so a hard respawn never silently degrades audit /
# debug / posture-prompt traces. The resolution is logged in dry-run output,
# and the missing-token warning fires when AGENT_LAUNCH_COMMAND pins the legacy
# minimal "claude --model ... --effort ..." form that triggered the audit.
contract_missing_output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  ORCH_STATE_BASE="$TEST_TMP/state-contract-missing" \
  AGENT_LAUNCH_COMMAND='claude --model opus --effort max' \
  bash "$SANITIZED_ROOT/scripts/agent_product_switch.sh" "$TEST_TMP/configs/portfolio.config.sh" source worker target --dry-run 2>&1
)
[[ "$contract_missing_output" == *'DRY-RUN: launch_cmd cli=claude cmd=exec claude --model opus --effort max'* ]] || \
  fail "hard dry-run should surface resolved launch_cmd: $contract_missing_output"
[[ "$contract_missing_output" == *'DRY-RUN: switch-launch-contract-missing target_pane=shared:0.0 target_agent=worker missing=--name,--debug-file,--append-system-prompt'* ]] || \
  fail "hard dry-run should warn on missing identity tokens: $contract_missing_output"
[[ "$contract_missing_output" == *'DRY-RUN: portfolio unblock task'*'code=switch-launch-contract-missing'* ]] || \
  fail "hard dry-run should record launch-contract unblock task: $contract_missing_output"

# Issue #305: per-agent AGENT_LAUNCH_CONTRACTS in the target profile preserves
# every required identity token; the dry-run must NOT warn or record a
# launch-contract unblock task when the contract is fully decorated.
cat > "$TEST_TMP/configs/target-with-contract.config.sh" <<EOF
PROJECT="target"
GH_REPO="example/target"
DEFAULT_BRANCH="main"
GH_CONFIG_DIR="$TEST_TMP/gh"
AGENT_REPO_PREFIX="$TEST_TMP/repos/target-"
export AGENT_WORKDIR_TEMPLATE="$TEST_TMP/repos/target-%s"
AGENT_PANES=(
  "worker|shared:0.0|$target_repo"
)
AGENT_LAUNCH_CONTRACTS=(
  "worker|claude --name worker --debug-file /tmp/worker.log --append-system-prompt /tmp/posture.md"
)
EOF
cat > "$TEST_TMP/configs/portfolio-with-contract.config.sh" <<EOF
PORTFOLIO_NAME="test"
PORTFOLIO_PROJECTS=(
  "source|$TEST_TMP/configs/source.config.sh"
  "target|$TEST_TMP/configs/target-with-contract.config.sh"
  "matrix-target|$TEST_TMP/configs/target-matrix.config.sh"
)
PORTFOLIO_ENSURE_AGENT_MATRIX=1
PORTFOLIO_FLEET_AGENTS=(
  "worker|shared:0.0"
)
EOF
contract_present_output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  ORCH_STATE_BASE="$TEST_TMP/state-contract-present" \
  bash "$SANITIZED_ROOT/scripts/agent_product_switch.sh" "$TEST_TMP/configs/portfolio-with-contract.config.sh" source worker target --dry-run 2>&1
)
[[ "$contract_present_output" == *'DRY-RUN: launch_cmd cli=claude cmd=exec claude --name worker --debug-file /tmp/worker.log --append-system-prompt /tmp/posture.md'* ]] || \
  fail "hard dry-run should resolve launch_cmd from AGENT_LAUNCH_CONTRACTS: $contract_present_output"
[[ "$contract_present_output" == *'switch-launch-contract-missing'* ]] && \
  fail "fully-decorated contract should not warn: $contract_present_output"

# AGENT_LAUNCH_COMMAND env override must continue to win over per-agent contract
# (deployment-pinned launch lines are intentional). Verifying via a fully
# decorated AGENT_LAUNCH_COMMAND so no warning fires.
env_override_output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  ORCH_STATE_BASE="$TEST_TMP/state-env-override" \
  AGENT_LAUNCH_COMMAND='claude --name env-pin --debug-file /tmp/env.log --append-system-prompt /tmp/env.md' \
  bash "$SANITIZED_ROOT/scripts/agent_product_switch.sh" "$TEST_TMP/configs/portfolio-with-contract.config.sh" source worker target --dry-run 2>&1
)
[[ "$env_override_output" == *'DRY-RUN: launch_cmd cli=claude cmd=exec claude --name env-pin --debug-file /tmp/env.log --append-system-prompt /tmp/env.md'* ]] || \
  fail "AGENT_LAUNCH_COMMAND should win over per-agent contract: $env_override_output"
[[ "$env_override_output" == *'switch-launch-contract-missing'* ]] && \
  fail "env-decorated launch should not warn: $env_override_output"

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
# Issue #123: soft switch keeps the existing pane, so the post-respawn
# readiness handshake must not be announced (it only applies to hard).
[[ "$soft_output" == *'DRY-RUN: agent_pane_ready'* ]] && \
  fail "soft switch dry-run should not announce hard readiness handshake: $soft_output"
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

matrix_output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  bash "$SANITIZED_ROOT/scripts/agent_product_switch.sh" "$TEST_TMP/configs/portfolio.config.sh" source worker matrix-target --soft --dry-run
)
[[ "$matrix_output" == *"target=matrix-target/worker workdir=$target_matrix_repo"* ]] || \
  fail "matrix target should be resolved from portfolio fleet: $matrix_output"
printf '%s\n' "$matrix_output" | tail -1 | jq -e --arg workdir "$target_matrix_repo" \
  '.target_project == "matrix-target" and .target_agent == "worker" and .target_workdir == $workdir and .target_pane == "shared:0.0"' >/dev/null \
  || fail "matrix switch JSON should include target workdir and pane: $matrix_output"

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

# Reset target to a clean main so the next scenarios can run.
rm -f "$target_repo/dirty.txt"

# Scenario: open PR with headRefOid that differs from local HEAD (issue #102).
# Expected: safe_state=parked-pr-stale and an informational unblock task is recorded
# with code=source-remote-rebased-local-stale.
git -C "$source_repo" branch -m feat/stale
cat > "$TEST_TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *"pr list"* && "$*" == *"feat/stale"* ]]; then
  printf '%s\n' '[{"number":55,"mergeStateStatus":"BLOCKED","headRefOid":"deadbeefcafef00ddeadbeefcafef00ddeadbeef"}]'
else
  printf '%s\n' '[]'
fi
EOF
chmod +x "$TEST_TMP/bin/gh"

stale_dry_output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  ORCH_STATE_BASE="$TEST_TMP/state-stale" \
  bash "$SANITIZED_ROOT/scripts/agent_product_switch.sh" "$TEST_TMP/configs/portfolio.config.sh" source worker target --dry-run 2>&1
)
[[ "$stale_dry_output" == *'state=parked-pr-stale'* ]] || fail "expected parked-pr-stale state: $stale_dry_output"
[[ "$stale_dry_output" == *'DRY-RUN: portfolio unblock task'*'code=source-remote-rebased-local-stale'* ]] || \
  fail "expected dry-run informational unblock task: $stale_dry_output"
printf '%s\n' "$stale_dry_output" | tail -1 | jq -e '.safe_state == "parked-pr-stale" and .source_pr == 55 and .source_pr_head == "deadbeefcafef00ddeadbeefcafef00ddeadbeef"' >/dev/null \
  || fail "stale switch JSON missing source_pr_head/safe_state fields: $stale_dry_output"
[[ ! -e "$TEST_TMP/state-stale/_portfolio/unblock_tasks.json" ]] || fail "dry-run should not persist unblock tasks for stale state"

set +e
PATH="$TEST_TMP/bin:$PATH" \
  ORCH_STATE_BASE="$TEST_TMP/state-stale" \
  bash "$SANITIZED_ROOT/scripts/agent_product_switch.sh" "$TEST_TMP/configs/portfolio.config.sh" source worker target --soft >/dev/null 2>&1
set -e
# The script will not complete the tmux respawn in the test environment, but the
# informational unblock task is recorded before any tmux interaction.
jq -e '.open | to_entries[] | select(.value.code == "source-remote-rebased-local-stale" and (.value.exit_code == 0) and (.value.recommended_action | test("git pull --ff-only")))' \
  "$TEST_TMP/state-stale/_portfolio/unblock_tasks.json" >/dev/null \
  || fail "live stale switch should persist informational unblock task"
grep -q 'source-remote-rebased-local-stale' "$TEST_TMP/state-stale/_portfolio/ORCH_TASKS.md" \
  || fail "live stale switch should append to ORCH_TASKS.md"

printf 'ok - agent_product_switch refuses unsafe work and parks PR branches\n'
