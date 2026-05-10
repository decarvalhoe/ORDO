#!/usr/bin/env bash
# test_brief_agents_worktree.sh — prompt rendering must match effective
# per-ticket worktree dispatch paths when USE_WORKTREES=1.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP=$(mktemp -d)
SANITIZED_ROOT="$TEST_TMP/toolkit"

cleanup() { rm -rf "$TEST_TMP"; }
trap cleanup EXIT

fail() { printf 'not ok - %s\n' "$*" >&2; exit 1; }

mkdir -p "$TEST_TMP/logs" "$TEST_TMP/repos"

# shellcheck source=../lib/test_sanitize.sh
source "$ROOT/lib/test_sanitize.sh"
sanitize_toolkit_copy "$SANITIZED_ROOT" \
  scripts/brief_agents.sh \
  templates/dispatch-canonical.md.tpl

chmod +x "$SANITIZED_ROOT/scripts/brief_agents.sh"

cat > "$TEST_TMP/test.config.sh" <<EOF
#!/usr/bin/env bash
PROJECT="brief-worktree"
GH_REPO="RBOKproject/ORDO"
GH_CONFIG_DIR="$TEST_TMP/gh"
DEFAULT_BRANCH="main"
AGENT_SESSION_PREFIX=""
AGENT_REPO_PREFIX="$TEST_TMP/repos/"
SUPERVISOR_REPO="origin"
export AGENT_WORKDIR_TEMPLATE="$TEST_TMP/repos/%s"
USE_WORKTREES="\${USE_WORKTREES:-0}"
ORCH_WORKTREES_DIR="\${ORCH_WORKTREES_DIR:-$TEST_TMP/worktrees}"
EOF

worktree_prompt="$TEST_TMP/worktree.md"
base_prompt="$TEST_TMP/base.md"
expected_worktree="$TEST_TMP/worktrees/claude/feat-issue-462"
base_repo="$TEST_TMP/repos/claude"

USE_WORKTREES=1 \
ORCH_LOG_DIR="$TEST_TMP/logs" \
bash "$SANITIZED_ROOT/scripts/brief_agents.sh" \
  "$TEST_TMP/test.config.sh" \
  claude 462 \
  branch_slug="feat/issue-462" \
  summary="fix #462 render effective worktree path" \
  validation="timeout 30 bash -n scripts/brief_agents.sh" \
  > "$worktree_prompt"

grep -Fq -- "- \`cd $expected_worktree\`" "$worktree_prompt" \
  || fail "worktree brief should instruct cd into ticket worktree"
grep -Fq -- "ne jamais modifier un autre workdir que \`$expected_worktree\`" "$worktree_prompt" \
  || fail "worktree brief should pin the isolation guard to the ticket worktree"
! grep -Fq -- "- \`cd $base_repo\`" "$worktree_prompt" \
  || fail "worktree brief must not instruct cd into the base repo"
! grep -Fq -- "ne jamais modifier un autre workdir que \`$base_repo\`" "$worktree_prompt" \
  || fail "worktree brief must not pin isolation to the base repo"

USE_WORKTREES=0 \
ORCH_LOG_DIR="$TEST_TMP/logs" \
bash "$SANITIZED_ROOT/scripts/brief_agents.sh" \
  "$TEST_TMP/test.config.sh" \
  claude 462 \
  branch_slug="feat/issue-462" \
  summary="fix #462 render effective worktree path" \
  validation="timeout 30 bash -n scripts/brief_agents.sh" \
  > "$base_prompt"

grep -Fq -- "- \`cd $base_repo\`" "$base_prompt" \
  || fail "base brief should continue to instruct cd into the base repo"

printf 'ok - brief_agents renders effective worktree paths\n'
