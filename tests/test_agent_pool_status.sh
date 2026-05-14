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

mkdir -p "$SANITIZED_ROOT/scripts" "$SANITIZED_ROOT/lib" "$TEST_TMP/bin" "$TEST_TMP/repos"

for rel in \
  scripts/agent_pool_status.sh \
  lib/agent_inventory.sh \
  lib/config_resolver.sh \
  lib/dispatch_capacity.sh \
  lib/process_safety.sh \
  lib/tmux_helpers.sh \
  lib/worktree_helpers.sh
do
  tr -d '\r' < "$ROOT/$rel" > "$SANITIZED_ROOT/$rel"
done
chmod +x "$SANITIZED_ROOT/scripts/agent_pool_status.sh"

# Regression for agent shells that export BASH_ENV with tmux helpers: the
# scenario-local fake tmux must not be invoked during bash startup.
BASH_ENV_POISON="$TEST_TMP/bash_env_poison.sh"
cat > "$BASH_ENV_POISON" <<'EOF'
#!/usr/bin/env bash
tmux display-message -p '#S' >/dev/null 2>&1 || true
EOF
export BASH_ENV="$BASH_ENV_POISON"

repo="$TEST_TMP/repos/agent-one"
git init -q "$repo"
git -C "$repo" config user.email test@example.invalid
git -C "$repo" config user.name "Test Agent"
printf 'ok\n' > "$repo/file.txt"
git -C "$repo" add file.txt
git -C "$repo" commit -q -m 'init'
git -C "$repo" branch -M main
git -C "$repo" remote add origin "$repo"
git -C "$repo" update-ref refs/remotes/origin/main HEAD
git -C "$repo" checkout -q -b feat/one
printf 'base drift\n' > "$repo/base.txt"
git -C "$repo" checkout -q main
git -C "$repo" add base.txt
git -C "$repo" commit -q -m 'base drift'
git -C "$repo" update-ref refs/remotes/origin/main HEAD
git -C "$repo" checkout -q feat/one
printf 'dirty\n' > "$repo/dirty.txt"

synced_repo="$TEST_TMP/repos/synced-agent"
git init -q "$synced_repo"
git -C "$synced_repo" config user.email synced@example.invalid
git -C "$synced_repo" config user.name "Synced Test Agent"
printf 'ok\n' > "$synced_repo/file.txt"
git -C "$synced_repo" add file.txt
git -C "$synced_repo" commit -q -m 'init'
git -C "$synced_repo" branch -M main
git -C "$synced_repo" remote add origin "$synced_repo"
git -C "$synced_repo" update-ref refs/remotes/origin/main HEAD
git -C "$synced_repo" checkout -q -b feat/synced
git -C "$synced_repo" update-ref refs/remotes/origin/feat/synced HEAD
git -C "$synced_repo" branch --set-upstream-to=origin/feat/synced feat/synced >/dev/null
printf 'staged after pr\n' > "$synced_repo/staged.txt"
git -C "$synced_repo" add staged.txt

identity_repo="$TEST_TMP/repos/identity-agent"
git init -q "$identity_repo"
git -C "$identity_repo" config user.email stale@example.invalid
git -C "$identity_repo" config user.name "Stale Identity"
printf 'ok\n' > "$identity_repo/file.txt"
git -C "$identity_repo" add file.txt
git -C "$identity_repo" commit -q -m 'init'
git -C "$identity_repo" branch -M main
git -C "$identity_repo" remote add origin "$identity_repo"
git -C "$identity_repo" update-ref refs/remotes/origin/main HEAD

cat > "$TEST_TMP/config.sh" <<EOF
PROJECT="pool-test"
DEFAULT_BRANCH="main"
GH_REPO="example/repo"
GH_CONFIG_DIR="$TEST_TMP/gh"
AGENT_PANES=(
  "agent-one|agent-one:0.0|$repo"
  "synced-agent|synced-agent:0.0|$synced_repo"
)
EOF

cat > "$TEST_TMP/identity.config.sh" <<EOF
PROJECT="pool-identity-test"
DEFAULT_BRANCH="main"
GH_REPO="example/repo"
GH_CONFIG_DIR="$TEST_TMP/gh"
AGENT_GH_LOGINS=(
  "identity-agent|ExpectedIdentity"
)
AGENT_GIT_IDENTITIES=(
  "identity-agent|ExpectedIdentity|expected@example.invalid"
)
AGENT_PANES=(
  "identity-agent|identity-agent:0.0|$identity_repo"
)
EOF

cat > "$TEST_TMP/bin/tmux" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  has-session) exit 0 ;;
  display-message) printf 'node\n' ;;
esac
EOF
chmod +x "$TEST_TMP/bin/tmux"

local_head_full=$(git -C "$repo" rev-parse HEAD)

# Scenario A: PR head SHA differs from local HEAD -> remote-rebased-local-stale.
cat > "$TEST_TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '[{"number":123,"headRefName":"feat/one","headRefOid":"abcdef123456789012345678901234567890abcd","mergeStateStatus":"BLOCKED","isDraft":false,"updatedAt":"2026-01-01T00:00:00Z","title":"test"}]'
EOF
chmod +x "$TEST_TMP/bin/gh"

output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  BASH_ENV='' \
  ORCH_STATE_BASE="$TEST_TMP/state-tsv" \
  bash "$SANITIZED_ROOT/scripts/agent_pool_status.sh" "$TEST_TMP/config.sh" --tsv
)

[[ "$output" == *$'label\tpane\talive\tcommand'* ]] || fail "missing TSV header: $output"
[[ "$output" == *$'agent-one\tagent-one:0.0\t1\tnode'* ]] || fail "missing agent row: $output"
[[ "$output" == *$'\tfeat/one\t'* ]] || fail "missing branch: $output"
[[ "$output" == *"remote-rebased-local-stale"* ]] || fail "missing remote-rebased-local-stale: $output"
[[ "$output" != *"needs-rebase"* ]] || fail "should not double-report needs-rebase when stale: $output"

json_output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  BASH_ENV='' \
  ORCH_STATE_BASE="$TEST_TMP/state-json" \
  bash "$SANITIZED_ROOT/scripts/agent_pool_status.sh" "$TEST_TMP/config.sh" --json
)

printf '%s' "$json_output" | jq -e '.[0].label == "agent-one" and .[0].pr == "123" and .[0].alive == 1 and .[0].base_current == "0" and (.[0].signals | index("remote-rebased-local-stale")) and ((.[0].signals | index("needs-rebase")) | not)' >/dev/null \
  || fail "unexpected JSON output (stale): $json_output"

printf '%s' "$json_output" | jq -e '.[] | select(.label == "synced-agent" and .branch == "feat/synced" and .upstream == "origin/feat/synced" and .ahead == "0" and .behind == "0" and .dirty == "1" and (.signals | index("dirty_after_pr")))' >/dev/null \
  || fail "synced staged work should report dirty_after_pr: $json_output"

cat > "$TEST_TMP/bin/tmux" <<EOF
#!/usr/bin/env bash
case "\$1" in
  has-session) exit 0 ;;
  display-message)
    fmt=""
    batched=0
    for arg in "\$@"; do
      case "\$arg" in
        *'#{pane_current_command}'*'#{pane_current_path}'*) batched=1 ;;
        '#{pane_current_path}'|'#{pane_current_command}') fmt=\$arg ;;
      esac
    done
    if [ "\$batched" = "1" ]; then
      printf 'node\037%s\n' "$identity_repo"
    elif [ "\$fmt" = '#{pane_current_path}' ]; then
      printf '%s\n' "$identity_repo"
    elif [ "\$fmt" = '#{pane_current_command}' ]; then
      printf 'node\n'
    fi
    exit 0
    ;;
esac
exit 0
EOF
chmod +x "$TEST_TMP/bin/tmux"

identity_json=$(
  PATH="$TEST_TMP/bin:$PATH" \
  BASH_ENV='' \
  ORCH_STATE_BASE="$TEST_TMP/state-identity" \
  bash "$SANITIZED_ROOT/scripts/agent_pool_status.sh" "$TEST_TMP/identity.config.sh" --json
)

printf '%s' "$identity_json" \
  | jq -e '
      .[0].label == "identity-agent"
      and .[0].capacity_class == "identity_mismatch"
      and .[0].expected_login == "ExpectedIdentity"
      and .[0].expected_git_identity == "ExpectedIdentity"
      and .[0].observed_git_identity == "Stale Identity"
      and .[0].git_identity_match == "0"
      and .[0].git_identity_repair == "set-git-identity"
      and (.[0].signals | map(select(startswith("git_identity_mismatch:expected_login=ExpectedIdentity:observed=Stale_Identity"))) | length == 1)
    ' >/dev/null \
  || fail "stale git identity should make an otherwise available clone non-dispatchable: $identity_json"

occupied_workdir="$TEST_TMP/agent-worktrees/rbok/agent-one/feat-issue-7000"
mkdir -p "$occupied_workdir" "$TEST_TMP/state-occupied/rbok"
cat > "$TEST_TMP/state-occupied/rbok/assignments.json" <<JSON
{
  "agent-one": {
    "ticket": "7000",
    "issue": 7000,
    "workdir": "$occupied_workdir",
    "branch": "feat/issue-7000"
  }
}
JSON

cat > "$TEST_TMP/bin/tmux" <<EOF
#!/usr/bin/env bash
case "\$1" in
  has-session) exit 0 ;;
  display-message)
    fmt=""
    batched=0
    for arg in "\$@"; do
      case "\$arg" in
        *'#{pane_current_command}'*'#{pane_current_path}'*) batched=1 ;;
        '#{pane_current_path}'|'#{pane_current_command}') fmt=\$arg ;;
      esac
    done
    if [ "\$batched" = "1" ]; then
      printf 'node\037%s\n' "$occupied_workdir"
    elif [ "\$fmt" = '#{pane_current_path}' ]; then
      printf '%s\n' "$occupied_workdir"
    elif [ "\$fmt" = '#{pane_current_command}' ]; then
      printf 'node\n'
    fi
    exit 0
    ;;
esac
exit 0
EOF
chmod +x "$TEST_TMP/bin/tmux"

occupied_json=$(
  PATH="$TEST_TMP/bin:$PATH" \
  BASH_ENV='' \
  ORCH_STATE_BASE="$TEST_TMP/state-occupied" \
  bash "$SANITIZED_ROOT/scripts/agent_pool_status.sh" "$TEST_TMP/config.sh" --json
)

printf '%s' "$occupied_json" \
  | jq -e --arg live "$occupied_workdir" \
      '.[0].live_pane_cwd == $live and (.[0].signals | index("pane-occupied:rbok#7000"))' >/dev/null \
  || fail "live pane cwd matching an active assignment should surface pane_occupied signal: $occupied_json"

parked_state="$TEST_TMP/state-parked-cross-project"
mkdir -p "$parked_state/ordo" "$parked_state/rbok"
cat > "$parked_state/ordo/assignments.json" <<JSON
{
  "agent-one": {
    "ticket": "605",
    "issue": 605,
    "workdir": "$occupied_workdir",
    "branch": "feat/issue-605",
    "parked": true
  }
}
JSON
cat > "$parked_state/rbok/assignments.json" <<JSON
{
  "agent-one": {
    "ticket": "7000",
    "issue": 7000,
    "workdir": "$occupied_workdir",
    "branch": "feat/issue-7000"
  }
}
JSON

parked_json=$(
  PATH="$TEST_TMP/bin:$PATH" \
  BASH_ENV='' \
  ORCH_STATE_BASE="$parked_state" \
  bash "$SANITIZED_ROOT/scripts/agent_pool_status.sh" "$TEST_TMP/config.sh" --json
)

printf '%s' "$parked_json" \
  | jq -e '
      .[0].signals
      | index("pane-occupied:rbok#7000")
        and ((index("pane-occupied:ordo#605")) | not)
    ' >/dev/null \
  || fail "parked cross-project assignment should not mask active occupancy: $parked_json"

parked_tsv=$(
  PATH="$TEST_TMP/bin:$PATH" \
  BASH_ENV='' \
  ORCH_STATE_BASE="$parked_state" \
  bash "$SANITIZED_ROOT/scripts/agent_pool_status.sh" "$TEST_TMP/config.sh" --tsv
)

parked_row=$(printf '%s\n' "$parked_tsv" | grep '^agent-one\b')
[[ "$parked_row" == *"pane-occupied:rbok#7000"* ]] \
  || fail "TSV should surface active occupancy when parked cross-project assignment exists: $parked_tsv"
[[ "$parked_row" != *"pane-occupied:ordo#605"* ]] \
  || fail "TSV should not surface parked cross-project occupancy: $parked_tsv"

shared_root="$TEST_TMP/repos/shared-root"
git init -q "$shared_root"
git -C "$shared_root" config user.email shared@example.invalid
git -C "$shared_root" config user.name "Shared Root"
printf 'ok\n' > "$shared_root/file.txt"
git -C "$shared_root" add file.txt
git -C "$shared_root" commit -q -m 'init'
git -C "$shared_root" branch -M main
git -C "$shared_root" remote add origin "$shared_root"
git -C "$shared_root" update-ref refs/remotes/origin/main HEAD
git -C "$shared_root" checkout -q -b feat/operator-local-work

live_worktree_root="$TEST_TMP/live-worktrees"
live_worktree="$live_worktree_root/agent-one/feat-issue-462"
mkdir -p "$(dirname "$live_worktree")"
git -C "$shared_root" worktree add -q "$live_worktree" main

cat > "$TEST_TMP/worktree-live.config.sh" <<EOF
PROJECT="pool-worktree-test"
DEFAULT_BRANCH="main"
GH_REPO="example/repo"
GH_CONFIG_DIR="$TEST_TMP/gh"
AGENT_PANES=(
  "agent-one|agent-one:0.0|$shared_root"
)
USE_WORKTREES=1
ORCH_WORKTREES_DIR="$live_worktree_root"
EOF

cat > "$TEST_TMP/bin/tmux" <<EOF
#!/usr/bin/env bash
case "\$1" in
  has-session) exit 0 ;;
  display-message)
    fmt=""
    batched=0
    for arg in "\$@"; do
      case "\$arg" in
        *'#{pane_current_command}'*'#{pane_current_path}'*) batched=1 ;;
        '#{pane_current_path}'|'#{pane_current_command}') fmt=\$arg ;;
      esac
    done
    if [ "\$batched" = "1" ]; then
      printf 'node\037%s\n' "$live_worktree"
    elif [ "\$fmt" = '#{pane_current_path}' ]; then
      printf '%s\n' "$live_worktree"
    elif [ "\$fmt" = '#{pane_current_command}' ]; then
      printf 'node\n'
    fi
    exit 0
    ;;
esac
exit 0
EOF
chmod +x "$TEST_TMP/bin/tmux"

worktree_live_json=$(
  PATH="$TEST_TMP/bin:$PATH" \
  BASH_ENV='' \
  ORCH_STATE_BASE="$TEST_TMP/state-worktree-live" \
  bash "$SANITIZED_ROOT/scripts/agent_pool_status.sh" "$TEST_TMP/worktree-live.config.sh" --json
)

printf '%s' "$worktree_live_json" \
  | jq -e --arg live "$live_worktree" \
      '.[0].assigned_workdir == $live
       and .[0].live_pane_cwd == $live
       and .[0].live_cwd_match == "1"
       and .[0].branch == "main"
       and .[0].capacity_class == "available"
       and ((.[0].signals | index("live_cwd_mismatch")) | not)' >/dev/null \
  || fail "USE_WORKTREES pool status should evaluate live agent worktree, not shared checkout: $worktree_live_json"

mkdir -p "$TEST_TMP/state-worktree-clean-assigned/pool-worktree-test"
cat > "$TEST_TMP/state-worktree-clean-assigned/pool-worktree-test/assignments.json" <<JSON
{
  "agent-one": {
    "ticket": "7002",
    "issue": 7002,
    "workdir": "$live_worktree",
    "branch": "main"
  }
}
JSON

worktree_clean_assigned_json=$(
  PATH="$TEST_TMP/bin:$PATH" \
  BASH_ENV='' \
  ORCH_STATE_BASE="$TEST_TMP/state-worktree-clean-assigned" \
  bash "$SANITIZED_ROOT/scripts/agent_pool_status.sh" "$TEST_TMP/worktree-live.config.sh" --json
)

printf '%s' "$worktree_clean_assigned_json" \
  | jq -e --arg live "$live_worktree" \
      '.[0].assigned_workdir == $live
       and .[0].live_pane_cwd == $live
       and .[0].live_cwd_match == "1"
       and .[0].branch == "main"
       and .[0].capacity_class == "local_work"
       and (.[0].signals | index("pane-occupied:pool-worktree-test#7002"))' >/dev/null \
  || fail "active assignment on clean default-branch worktree should not report available: $worktree_clean_assigned_json"

assigned_worktree="$live_worktree_root/agent-one/feat-issue-7001"
git -C "$shared_root" worktree add -q -b feat/issue-7001 "$assigned_worktree" main
mkdir -p "$TEST_TMP/state-worktree-assigned/pool-worktree-test"
cat > "$TEST_TMP/state-worktree-assigned/pool-worktree-test/assignments.json" <<JSON
{
  "agent-one": {
    "ticket": "7001",
    "issue": 7001,
    "workdir": "$assigned_worktree",
    "branch": "feat/issue-7001"
  }
}
JSON

cat > "$TEST_TMP/bin/tmux" <<EOF
#!/usr/bin/env bash
case "\$1" in
  has-session) exit 0 ;;
  display-message)
    fmt=""
    batched=0
    for arg in "\$@"; do
      case "\$arg" in
        *'#{pane_current_command}'*'#{pane_current_path}'*) batched=1 ;;
        '#{pane_current_path}'|'#{pane_current_command}') fmt=\$arg ;;
      esac
    done
    if [ "\$batched" = "1" ]; then
      printf 'node\037%s\n' "$assigned_worktree"
    elif [ "\$fmt" = '#{pane_current_path}' ]; then
      printf '%s\n' "$assigned_worktree"
    elif [ "\$fmt" = '#{pane_current_command}' ]; then
      printf 'node\n'
    fi
    exit 0
    ;;
esac
exit 0
EOF
chmod +x "$TEST_TMP/bin/tmux"

worktree_assigned_json=$(
  PATH="$TEST_TMP/bin:$PATH" \
  BASH_ENV='' \
  ORCH_STATE_BASE="$TEST_TMP/state-worktree-assigned" \
  bash "$SANITIZED_ROOT/scripts/agent_pool_status.sh" "$TEST_TMP/worktree-live.config.sh" --json
)

printf '%s' "$worktree_assigned_json" \
  | jq -e --arg assigned "$assigned_worktree" \
      '.[0].assigned_workdir == $assigned
       and .[0].live_pane_cwd == $assigned
       and .[0].live_cwd_match == "1"
       and .[0].branch == "feat/issue-7001"
       and .[0].capacity_class == "local_work"
       and ((.[0].signals | index("live_cwd_mismatch")) | not)' >/dev/null \
  || fail "USE_WORKTREES pool status should derive assigned workdir from assignments.json: $worktree_assigned_json"

ordo_soft_assigned_worktree="$TEST_TMP/ORDO-worktrees/RBOK-copilot/feat-issue-603"
mkdir -p "$(dirname "$ordo_soft_assigned_worktree")"
git -C "$shared_root" worktree add -q -b fix/issue-603-ordo-live-worktree-status "$ordo_soft_assigned_worktree" main
mkdir -p "$TEST_TMP/state-ordo-soft-assigned/ordo"
cat > "$TEST_TMP/state-ordo-soft-assigned/ordo/assignments.json" <<JSON
{
  "RBOK-copilot": {
    "ticket": "603",
    "issue": 603,
    "workdir": "$ordo_soft_assigned_worktree",
    "branch": "fix/issue-603-ordo-live-worktree-status"
  }
}
JSON

cat > "$TEST_TMP/ordo-soft-route.config.sh" <<EOF
PROJECT="ordo"
DEFAULT_BRANCH="main"
GH_REPO="example/repo"
GH_CONFIG_DIR="$TEST_TMP/gh"
AGENT_PANES=(
  "RBOK-copilot|rbok-copilot:0.0|$shared_root"
)
EOF

cat > "$TEST_TMP/bin/tmux" <<EOF
#!/usr/bin/env bash
case "\$1" in
  has-session) exit 0 ;;
  display-message)
    fmt=""
    batched=0
    for arg in "\$@"; do
      case "\$arg" in
        *'#{pane_current_command}'*'#{pane_current_path}'*) batched=1 ;;
        '#{pane_current_path}'|'#{pane_current_command}') fmt=\$arg ;;
      esac
    done
    if [ "\$batched" = "1" ]; then
      printf 'node\037%s\n' "$ordo_soft_assigned_worktree"
    elif [ "\$fmt" = '#{pane_current_path}' ]; then
      printf '%s\n' "$ordo_soft_assigned_worktree"
    elif [ "\$fmt" = '#{pane_current_command}' ]; then
      printf 'node\n'
    fi
    exit 0
    ;;
esac
exit 0
EOF
chmod +x "$TEST_TMP/bin/tmux"

ordo_soft_assigned_json=$(
  PATH="$TEST_TMP/bin:$PATH" \
  BASH_ENV='' \
  ORCH_STATE_BASE="$TEST_TMP/state-ordo-soft-assigned" \
  bash "$SANITIZED_ROOT/scripts/agent_pool_status.sh" "$TEST_TMP/ordo-soft-route.config.sh" --json
)

printf '%s' "$ordo_soft_assigned_json" \
  | jq -e --arg assigned "$ordo_soft_assigned_worktree" \
      '.[0].assigned_workdir == $assigned
       and .[0].live_pane_cwd == $assigned
       and .[0].live_cwd_match == "1"
       and .[0].branch == "fix/issue-603-ordo-live-worktree-status"
       and .[0].capacity_class == "local_work"
       and (.[0].signals | index("pane-occupied:ordo#603"))
       and ((.[0].signals | index("live_cwd_mismatch")) | not)' >/dev/null \
  || fail "ORDO soft-routed active assignment should use the assignment worktree without USE_WORKTREES: $ordo_soft_assigned_json"

ordo_soft_unassigned_worktree="$TEST_TMP/ORDO-worktrees/RBOK-codex/feat-issue-604"
mkdir -p "$(dirname "$ordo_soft_unassigned_worktree")"
git -C "$shared_root" worktree add -q -b feat/issue-604 "$ordo_soft_unassigned_worktree" main

cat > "$TEST_TMP/ordo-soft-route-unassigned.config.sh" <<EOF
PROJECT="ordo"
DEFAULT_BRANCH="main"
GH_REPO="example/repo"
GH_CONFIG_DIR="$TEST_TMP/gh"
AGENT_PANES=(
  "RBOK-codex|rbok-codex:0.0|$shared_root"
)
EOF

cat > "$TEST_TMP/bin/tmux" <<EOF
#!/usr/bin/env bash
case "\$1" in
  has-session) exit 0 ;;
  display-message)
    fmt=""
    batched=0
    for arg in "\$@"; do
      case "\$arg" in
        *'#{pane_current_command}'*'#{pane_current_path}'*) batched=1 ;;
        '#{pane_current_path}'|'#{pane_current_command}') fmt=\$arg ;;
      esac
    done
    if [ "\$batched" = "1" ]; then
      printf 'node\037%s\n' "$ordo_soft_unassigned_worktree"
    elif [ "\$fmt" = '#{pane_current_path}' ]; then
      printf '%s\n' "$ordo_soft_unassigned_worktree"
    elif [ "\$fmt" = '#{pane_current_command}' ]; then
      printf 'node\n'
    fi
    exit 0
    ;;
esac
exit 0
EOF
chmod +x "$TEST_TMP/bin/tmux"

ordo_soft_unassigned_json=$(
  PATH="$TEST_TMP/bin:$PATH" \
  BASH_ENV='' \
  ORCH_STATE_BASE="$TEST_TMP/state-ordo-soft-unassigned" \
  bash "$SANITIZED_ROOT/scripts/agent_pool_status.sh" "$TEST_TMP/ordo-soft-route-unassigned.config.sh" --json
)

printf '%s' "$ordo_soft_unassigned_json" \
  | jq -e --arg live "$ordo_soft_unassigned_worktree" \
      '.[0].assigned_workdir == $live
       and .[0].live_pane_cwd == $live
       and .[0].live_cwd_match == "1"
       and .[0].branch == "feat/issue-604"
       and .[0].capacity_class == "local_work"
       and ((.[0].signals | index("live_cwd_mismatch")) | not)' >/dev/null \
  || fail "ORDO soft-routed live worktree should be treated as the effective workdir without USE_WORKTREES: $ordo_soft_unassigned_json"

mkdir -p "$TEST_TMP/state-rbok-soft-assigned/rbok"
cat > "$TEST_TMP/state-rbok-soft-assigned/rbok/assignments.json" <<JSON
{
  "RBOK-copilot": {
    "ticket": "603",
    "issue": 603,
    "workdir": "$ordo_soft_assigned_worktree",
    "branch": "fix/issue-603-ordo-live-worktree-status"
  }
}
JSON

cat > "$TEST_TMP/rbok-soft-route.config.sh" <<EOF
PROJECT="rbok"
DEFAULT_BRANCH="develop"
GH_REPO="example/repo"
GH_CONFIG_DIR="$TEST_TMP/gh"
AGENT_PANES=(
  "RBOK-copilot|rbok-copilot:0.0|$shared_root"
)
EOF

rbok_soft_assigned_json=$(
  PATH="$TEST_TMP/bin:$PATH" \
  BASH_ENV='' \
  ORCH_STATE_BASE="$TEST_TMP/state-rbok-soft-assigned" \
  bash "$SANITIZED_ROOT/scripts/agent_pool_status.sh" "$TEST_TMP/rbok-soft-route.config.sh" --json
)

printf '%s' "$rbok_soft_assigned_json" \
  | jq -e --arg configured "$shared_root" --arg live "$ordo_soft_unassigned_worktree" \
      '.[0].assigned_workdir == $configured
       and .[0].live_pane_cwd == $live
       and .[0].live_cwd_match == "0"
       and .[0].capacity_class == "local_work"
       and (.[0].signals | index("live_cwd_mismatch"))' >/dev/null \
  || fail "non-ORDO profile should keep existing USE_WORKTREES-disabled cwd behavior: $rbok_soft_assigned_json"

# Scenario B: PR head SHA matches local HEAD -> genuine needs-rebase.
cat > "$TEST_TMP/bin/gh" <<EOF
#!/usr/bin/env bash
printf '%s\n' '[{"number":124,"headRefName":"feat/one","headRefOid":"$local_head_full","mergeStateStatus":"BLOCKED","isDraft":false,"updatedAt":"2026-01-01T00:00:00Z","title":"test"}]'
EOF
chmod +x "$TEST_TMP/bin/gh"

needs_rebase_output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  BASH_ENV='' \
  ORCH_STATE_BASE="$TEST_TMP/state-needs-rebase" \
  ORCH_PROCESS_BUDGET_WARN_PROCS=999999 \
  ORCH_PROCESS_BUDGET_MAX_PROCS=999999 \
  bash "$SANITIZED_ROOT/scripts/agent_pool_status.sh" "$TEST_TMP/config.sh" --json
)

printf '%s' "$needs_rebase_output" | jq -e '.[0].pr == "124" and (.[0].signals | index("needs-rebase")) and ((.[0].signals | index("remote-rebased-local-stale")) | not)' >/dev/null \
  || fail "expected genuine needs-rebase when PR head matches local HEAD: $needs_rebase_output"

partial_output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  BASH_ENV='' \
  ORCH_STATE_BASE="$TEST_TMP/state-partial" \
  ORCH_PROCESS_BUDGET_WARN_PROCS=1 \
  ORCH_PROCESS_BUDGET_MAX_PROCS=1 \
  bash "$SANITIZED_ROOT/scripts/agent_pool_status.sh" "$TEST_TMP/config.sh" --json
)

printf '%s' "$partial_output" | jq -e '.[0].label == "agent-one" and .[0].alive == 0 and (.[0].signals | index("process_budget_degraded")) and (.[0].signals | index("fork_risk"))' >/dev/null \
  || fail "expected partial process-budget status: $partial_output"

printf 'ok - agent_pool_status reports universal fleet state\n'
