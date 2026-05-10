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

mkdir -p "$SANITIZED_ROOT/lib" "$TEST_TMP/repos"

for rel in \
  lib/agent_inventory.sh \
  lib/audit_log.sh \
  lib/log_bounds.sh \
  lib/config_check.sh \
  lib/state_persist.sh \
  lib/worktree_helpers.sh
do
  tr -d '\r' < "$ROOT/$rel" > "$SANITIZED_ROOT/$rel"
done

git init --bare "$TEST_TMP/origin.git" >/dev/null
git init "$TEST_TMP/seed" >/dev/null
git -C "$TEST_TMP/seed" config user.name "Worktree Test"
git -C "$TEST_TMP/seed" config user.email "worktree@test.local"
git -C "$TEST_TMP/seed" checkout -b main >/dev/null
printf 'seed\n' > "$TEST_TMP/seed/README.md"
git -C "$TEST_TMP/seed" add README.md
git -C "$TEST_TMP/seed" commit -m "seed" >/dev/null
git -C "$TEST_TMP/seed" remote add origin "$TEST_TMP/origin.git"
git -C "$TEST_TMP/seed" push -u origin main >/dev/null
git clone "$TEST_TMP/origin.git" "$TEST_TMP/repos/claude" >/dev/null 2>&1
git -C "$TEST_TMP/repos/claude" checkout main >/dev/null
git -C "$TEST_TMP/repos/claude" config user.name "Shared Root"
git -C "$TEST_TMP/repos/claude" config user.email "shared-root@test.local"

cat > "$TEST_TMP/test.config.sh" <<EOF
#!/usr/bin/env bash
PROJECT="worktree-test"
ORCH_LOG_DIR="$TEST_TMP/logs"
ORCH_STATE_BASE="$TEST_TMP/state"
DEFAULT_BRANCH="main"
AGENTS=(claude)
AGENT_SESSION_PREFIX=""
AGENT_REPO_PREFIX="$TEST_TMP/repos/"
export AGENT_WORKDIR_TEMPLATE="$TEST_TMP/repos/%s"
USE_WORKTREES=1
ORCH_WORKTREES_DIR="$TEST_TMP/worktrees"
EOF

mkdir -p "$TEST_TMP/logs"

create_output=$(
  bash -lc "
    source '$TEST_TMP/test.config.sh'
    source '$SANITIZED_ROOT/lib/audit_log.sh'
    source '$SANITIZED_ROOT/lib/state_persist.sh'
    source '$SANITIZED_ROOT/lib/worktree_helpers.sh'
    worktree_create claude 7001
  "
)

worktree_dir="$TEST_TMP/worktrees/claude/feat-issue-7001"
[[ "$create_output" == "$worktree_dir" ]] || fail "unexpected worktree path: $create_output"
git -C "$worktree_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 || fail "worktree_create should create a git worktree"
branch=$(git -C "$worktree_dir" branch --show-current)
[[ "$branch" == "feat/issue-7001" ]] || fail "unexpected worktree branch: $branch"
git -C "$TEST_TMP/repos/claude" worktree list | grep -F "$worktree_dir" >/dev/null || fail "base repo should know about the worktree"

bash -lc "
  source '$TEST_TMP/test.config.sh'
  source '$SANITIZED_ROOT/lib/audit_log.sh'
  source '$SANITIZED_ROOT/lib/state_persist.sh'
  source '$SANITIZED_ROOT/lib/worktree_helpers.sh'
  state_update assignments '.claude = {\"workdir\": \"$worktree_dir\"}'
  worktree_cleanup_stale
"

[[ -d "$worktree_dir" ]] || fail "cleanup should preserve assigned worktrees"

bash -lc "
  source '$TEST_TMP/test.config.sh'
  source '$SANITIZED_ROOT/lib/audit_log.sh'
  source '$SANITIZED_ROOT/lib/state_persist.sh'
  source '$SANITIZED_ROOT/lib/worktree_helpers.sh'
  state_persist assignments.json '{}'
  worktree_cleanup_stale
"

[[ ! -d "$worktree_dir" ]] || fail "cleanup should remove unassigned worktrees"

create_output=$(
  bash -lc "
    source '$TEST_TMP/test.config.sh'
    source '$SANITIZED_ROOT/lib/audit_log.sh'
    source '$SANITIZED_ROOT/lib/state_persist.sh'
    source '$SANITIZED_ROOT/lib/worktree_helpers.sh'
    worktree_create claude 7002
  "
)
worktree_dir="$TEST_TMP/worktrees/claude/feat-issue-7002"

bash -lc "
  source '$TEST_TMP/test.config.sh'
  source '$SANITIZED_ROOT/lib/audit_log.sh'
  source '$SANITIZED_ROOT/lib/state_persist.sh'
  source '$SANITIZED_ROOT/lib/worktree_helpers.sh'
  worktree_remove '$worktree_dir'
"

[[ ! -d "$worktree_dir" ]] || fail "worktree_remove should delete the worktree path"

# Issue #498: agents that share one root checkout must get distinct
# worktree-local git identities so the shared root config can stay stable.
identity_output=$(
  bash -lc "
    source '$TEST_TMP/test.config.sh'
    AGENT_PANES=(
      'claude|claude:0.0|$TEST_TMP/repos/claude'
      'gemini|gemini:0.0|$TEST_TMP/repos/claude'
    )
    AGENT_GIT_IDENTITIES=(
      'claude|ORDO Agent Claude|claude@noreply.test.invalid'
      'gemini|ORDO Agent Gemini|gemini@noreply.test.invalid'
    )
    source '$SANITIZED_ROOT/lib/audit_log.sh'
    source '$SANITIZED_ROOT/lib/state_persist.sh'
    source '$SANITIZED_ROOT/lib/worktree_helpers.sh'
    claude_wt=\$(worktree_create claude 7003)
    gemini_wt=\$(worktree_create gemini 7004)
    printf 'claude=%s\n' \"\$claude_wt\"
    printf 'gemini=%s\n' \"\$gemini_wt\"
  "
)

claude_identity_dir=$(printf '%s\n' "$identity_output" | awk -F= '$1 == "claude" {print $2}')
gemini_identity_dir=$(printf '%s\n' "$identity_output" | awk -F= '$1 == "gemini" {print $2}')
[[ -n "$claude_identity_dir" && -n "$gemini_identity_dir" ]] \
  || fail "identity fixture should emit both worktree paths: $identity_output"
[[ "$claude_identity_dir" != "$gemini_identity_dir" ]] \
  || fail "two agents should get separate worktree paths: $identity_output"
[[ "$(git -C "$claude_identity_dir" config user.name)" == "ORDO Agent Claude" ]] \
  || fail "claude worktree should have its own user.name"
[[ "$(git -C "$claude_identity_dir" config user.email)" == "claude@noreply.test.invalid" ]] \
  || fail "claude worktree should have its own user.email"
[[ "$(git -C "$gemini_identity_dir" config user.name)" == "ORDO Agent Gemini" ]] \
  || fail "gemini worktree should have its own user.name"
[[ "$(git -C "$gemini_identity_dir" config user.email)" == "gemini@noreply.test.invalid" ]] \
  || fail "gemini worktree should have its own user.email"
[[ "$(git -C "$TEST_TMP/repos/claude" config user.name)" == "Shared Root" ]] \
  || fail "shared root user.name must not be overwritten"
[[ "$(git -C "$TEST_TMP/repos/claude" config user.email)" == "shared-root@test.local" ]] \
  || fail "shared root user.email must not be overwritten"
[[ "$(git -C "$TEST_TMP/repos/claude" config extensions.worktreeConfig)" == "true" ]] \
  || fail "shared root should enable extensions.worktreeConfig for worktree-local identity"

# -----------------------------------------------------------------------------
# Issue #305: per-agent launch contract + identity-token verification.
# -----------------------------------------------------------------------------

# agent_launch_contract returns 1 when AGENT_LAUNCH_CONTRACTS is unset.
unset_contract_status=$(
  bash -lc "
    set +e
    source '$SANITIZED_ROOT/lib/worktree_helpers.sh'
    agent_launch_contract rbok-claude >/dev/null 2>&1
    echo \$?
  "
)
[[ "$unset_contract_status" == "1" ]] \
  || fail "agent_launch_contract with unset array should return 1, got: $unset_contract_status"

# agent_launch_contract returns 1 when no entry matches the label.
no_match_status=$(
  bash -lc "
    set +e
    AGENT_LAUNCH_CONTRACTS=(
      'rbok-claude|claude --name rbok-claude --debug-file /tmp/c.log --append-system-prompt /tmp/p.md'
    )
    source '$SANITIZED_ROOT/lib/worktree_helpers.sh'
    agent_launch_contract rbok-codex >/dev/null 2>&1
    echo \$?
  "
)
[[ "$no_match_status" == "1" ]] \
  || fail "agent_launch_contract with no matching label should return 1, got: $no_match_status"

# agent_launch_contract echoes the configured command for a matching label.
contract_output=$(
  bash -lc "
    AGENT_LAUNCH_CONTRACTS=(
      'rbok-claude|claude --name rbok-claude --debug-file /tmp/c.log --append-system-prompt /tmp/p.md'
      'rbok-codex|codex -m gpt-5.5 --name rbok-codex --debug-file /tmp/x.log'
    )
    source '$SANITIZED_ROOT/lib/worktree_helpers.sh'
    agent_launch_contract rbok-codex
  "
)
[[ "$contract_output" == 'codex -m gpt-5.5 --name rbok-codex --debug-file /tmp/x.log' ]] \
  || fail "agent_launch_contract should echo configured command, got: $contract_output"

# agent_launch_command prefers AGENT_LAUNCH_COMMAND env over per-agent contract
# so deployments that pin a single launch line continue to win.
env_wins_output=$(
  bash -lc "
    AGENT_LAUNCH_COMMAND='claude --legacy-pin'
    AGENT_LAUNCH_CONTRACTS=(
      'rbok-claude|claude --name rbok-claude --debug-file /tmp/c.log --append-system-prompt /tmp/p.md'
    )
    source '$SANITIZED_ROOT/lib/worktree_helpers.sh'
    agent_launch_command shared:0.0 rbok-claude
  "
)
[[ "$env_wins_output" == 'exec claude --legacy-pin' ]] \
  || fail "AGENT_LAUNCH_COMMAND should win over per-agent contract, got: $env_wins_output"

# agent_launch_command falls back to the per-agent contract when no env override
# and the contract is configured for the requested label.
contract_wins_output=$(
  bash -lc "
    unset AGENT_LAUNCH_COMMAND
    AGENT_LAUNCH_CONTRACTS=(
      'rbok-claude|claude --name rbok-claude --debug-file /tmp/c.log --append-system-prompt /tmp/p.md'
    )
    source '$SANITIZED_ROOT/lib/worktree_helpers.sh'
    agent_launch_command shared:0.0 rbok-claude
  "
)
[[ "$contract_wins_output" == 'exec claude --name rbok-claude --debug-file /tmp/c.log --append-system-prompt /tmp/p.md' ]] \
  || fail "agent_launch_command should use per-agent contract, got: $contract_wins_output"

# agent_launch_command_missing_identity_tokens reports every missing token for
# claude when the launch line is the bare CLI.
missing_claude_output=$(
  bash -lc "
    source '$SANITIZED_ROOT/lib/worktree_helpers.sh'
    agent_launch_command_missing_identity_tokens 'exec claude' claude
  " | paste -sd ',' -
)
[[ "$missing_claude_output" == '--name,--debug-file,--append-system-prompt' ]] \
  || fail "bare claude should miss every claude identity token, got: $missing_claude_output"

# agent_launch_command_missing_identity_tokens reports nothing when every
# identity token is present (whitespace-separated or '=' style).
preserved_claude_output=$(
  bash -lc "
    source '$SANITIZED_ROOT/lib/worktree_helpers.sh'
    agent_launch_command_missing_identity_tokens \
      'exec claude --name rbok-claude --debug-file=/tmp/c.log --append-system-prompt /tmp/p.md' \
      claude
  "
)
[[ -z "$preserved_claude_output" ]] \
  || fail "fully-decorated claude should report no missing tokens, got: $preserved_claude_output"

# agent_launch_command_missing_identity_tokens emits nothing for unknown CLIs
# so the helper does not gate non-claude/non-codex agents.
unknown_cli_output=$(
  bash -lc "
    source '$SANITIZED_ROOT/lib/worktree_helpers.sh'
    agent_launch_command_missing_identity_tokens 'exec something --foo bar' something-else
  "
)
[[ -z "$unknown_cli_output" ]] \
  || fail "unknown CLI should report no required tokens, got: $unknown_cli_output"

printf 'ok - worktree helpers create, cleanup, and remove isolated worktrees\n'
