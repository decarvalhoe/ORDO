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
  scripts/dispatch_ticket.sh \
  templates/dispatch-canonical.md.tpl

chmod +x "$SANITIZED_ROOT/scripts/brief_agents.sh" "$SANITIZED_ROOT/scripts/dispatch_ticket.sh"

cat > "$TEST_TMP/test.config.sh" <<EOF
#!/usr/bin/env bash
PROJECT="brief-worktree"
GH_REPO="RBOKproject/ORDO"
GH_CONFIG_DIR="$TEST_TMP/gh"
DEFAULT_BRANCH="main"
# REPO_URL pins the canonical clone URL the #683 workdir-origin preflight
# compares against; the synthetic fixture origin below is a local file
# path, so without REPO_URL the preflight would derive the canonical from
# GH_REPO (https://github.com/RBOKproject/ORDO.git) and refuse on the
# trivial mismatch — shadowing the route-mismatch assertion this test
# exercises. Coverage for the workdir-origin guard itself lives in
# tests/dispatch_workdir_origin_preflight.bats.
REPO_URL="$TEST_TMP/origin.git"
AGENT_SESSION_PREFIX=""
AGENT_REPO_PREFIX="$TEST_TMP/repos/"
SUPERVISOR_REPO="origin"
export AGENT_WORKDIR_TEMPLATE="$TEST_TMP/repos/%s"
ORCH_SCOPE_IN_SCOPE_PROJECTS="brief-worktree"
USE_WORKTREES="\${USE_WORKTREES:-0}"
ORCH_WORKTREES_DIR="\${ORCH_WORKTREES_DIR:-$TEST_TMP/worktrees}"
EOF

worktree_prompt="$TEST_TMP/worktree.md"
base_prompt="$TEST_TMP/base.md"
ci_delegated_prompt="$TEST_TMP/ci-delegated.md"
expected_worktree="$TEST_TMP/worktrees/claude/feat-issue-462"
base_repo="$TEST_TMP/repos/claude"
legacy_prompt="$TEST_TMP/dispatch-claude-462.md"

git init --bare "$TEST_TMP/origin.git" >/dev/null
git init "$TEST_TMP/seed" >/dev/null
git -C "$TEST_TMP/seed" config user.name "Brief Test"
git -C "$TEST_TMP/seed" config user.email "brief@test.local"
git -C "$TEST_TMP/seed" checkout -b main >/dev/null
printf 'seed\n' > "$TEST_TMP/seed/README.md"
git -C "$TEST_TMP/seed" add README.md
git -C "$TEST_TMP/seed" commit -m "seed" >/dev/null
git -C "$TEST_TMP/seed" remote add origin "$TEST_TMP/origin.git"
git -C "$TEST_TMP/seed" push -u origin main >/dev/null
git clone "$TEST_TMP/origin.git" "$base_repo" >/dev/null 2>&1
git -C "$base_repo" checkout main >/dev/null
git -C "$base_repo" config user.name "Dispatch claude"
git -C "$base_repo" config user.email "claude@test.local"
expected_base_sha=$(git -C "$base_repo" rev-parse origin/main)

USE_WORKTREES=0 \
ORCH_LOG_DIR="$TEST_TMP/logs" \
bash "$SANITIZED_ROOT/scripts/brief_agents.sh" \
  "$TEST_TMP/test.config.sh" \
  claude 519 \
  branch_slug="fix/519-validation-guidance" \
  summary="fix #519 render executable validation guidance" \
  scope_files="scripts/brief_agents.sh" \
  > "$ci_delegated_prompt"

grep -Fq -- "validation_policy=ci-delegated" "$ci_delegated_prompt" \
  || fail "CI-delegated brief should render a machine-readable validation policy"
grep -Fq -- "validation_command=none" "$ci_delegated_prompt" \
  || fail "CI-delegated brief should render validation_command=none"
grep -Fq -- "allowed_focused_checks:" "$ci_delegated_prompt" \
  || fail "CI-delegated brief should render explicit allowed focused checks"
grep -Fq -- "- timeout 30 bash -n <edited-shell-script>" "$ci_delegated_prompt" \
  || fail "CI-delegated brief should give an executable shell syntax check shape"
! grep -Fq -- "CI-delegated validation. Do not run full local repository validators" "$ci_delegated_prompt" \
  || fail "CI-delegated brief must not use prose-only validation guidance"

USE_WORKTREES=1 \
ORCH_LOG_DIR="$TEST_TMP/logs" \
bash "$SANITIZED_ROOT/scripts/brief_agents.sh" \
  "$TEST_TMP/test.config.sh" \
  claude 462 \
  branch_slug="feat/issue-462" \
  summary="fix #462 render effective worktree path" \
  scope_files="scripts/brief_agents.sh" \
  validation="timeout 30 bash -n scripts/brief_agents.sh" \
  > "$worktree_prompt"

grep -Fq -- "- \`cd $expected_worktree\`" "$worktree_prompt" \
  || fail "worktree brief should instruct cd into ticket worktree"
grep -Fq -- "ne jamais modifier un autre workdir que \`$expected_worktree\`" "$worktree_prompt" \
  || fail "worktree brief should pin the isolation guard to the ticket worktree"
grep -Fq -- "base: origin/main @ $expected_base_sha" "$worktree_prompt" \
  || fail "worktree brief should render the concrete default-branch SHA"
! grep -Fq -- "base: origin/main @ HEAD" "$worktree_prompt" \
  || fail "worktree brief must not render HEAD as the base SHA"
! grep -Fq -- "- \`cd $base_repo\`" "$worktree_prompt" \
  || fail "worktree brief must not instruct cd into the base repo"
! grep -Fq -- "ne jamais modifier un autre workdir que \`$base_repo\`" "$worktree_prompt" \
  || fail "worktree brief must not pin isolation to the base repo"

# Issue #466: when USE_WORKTREES=1 and no branch_slug override is provided,
# the rendered brief must default to the same value as worktree_feature_branch
# (feat/issue-<N>), not the legacy feat/<project>-ticket-<N> form which
# diverges from the worktree branch and forces agents onto a different
# branch.
canonical_prompt="$TEST_TMP/canonical.md"
USE_WORKTREES=1 \
ORCH_LOG_DIR="$TEST_TMP/logs" \
bash "$SANITIZED_ROOT/scripts/brief_agents.sh" \
  "$TEST_TMP/test.config.sh" \
  claude 462 \
  summary="fix #466 align canonical branch_slug" \
  scope_files="scripts/brief_agents.sh" \
  validation="timeout 30 bash -n scripts/brief_agents.sh" \
  > "$canonical_prompt"

grep -Fq -- "Branche locale: \`feat/issue-462\`" "$canonical_prompt" \
  || fail "worktree brief should default branch_slug to worktree_feature_branch (feat/issue-462)"
grep -Fq -- "git checkout -B feat/issue-462" "$canonical_prompt" \
  || fail "worktree brief should instruct checkout of the canonical worktree branch"
! grep -Fq -- "feat/brief-worktree-ticket-462" "$canonical_prompt" \
  || fail "worktree brief must not render the legacy feat/<project>-ticket-<N> form when worktrees are enabled"

# Issue #466: an explicit branch_slug override that diverges from the
# worktree branch must emit a clear WARN on stderr so dispatch can surface
# the mismatch before agents check out a divergent branch.
mismatch_prompt="$TEST_TMP/mismatch.md"
mismatch_stderr="$TEST_TMP/mismatch.err"
USE_WORKTREES=1 \
ORCH_LOG_DIR="$TEST_TMP/logs" \
bash "$SANITIZED_ROOT/scripts/brief_agents.sh" \
  "$TEST_TMP/test.config.sh" \
  claude 462 \
  branch_slug="feat/divergent-override-462" \
  summary="fix #466 detect branch_slug override drift" \
  scope_files="scripts/brief_agents.sh" \
  validation="timeout 30 bash -n scripts/brief_agents.sh" \
  > "$mismatch_prompt" 2> "$mismatch_stderr"

grep -Fq -- "WARN: brief branch_slug=feat/divergent-override-462 diverges from worktree branch feat/issue-462" \
  "$mismatch_stderr" \
  || fail "worktree brief must warn when an explicit branch_slug override diverges from the worktree branch"

sed "s|$expected_worktree|$base_repo|g" "$worktree_prompt" > "$legacy_prompt"
set +e
legacy_dispatch_output=$(
  USE_WORKTREES=1 \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  ORCH_WORKTREES_DIR="$TEST_TMP/worktrees" \
  bash "$SANITIZED_ROOT/scripts/dispatch_ticket.sh" \
    "$TEST_TMP/test.config.sh" claude 462 "$legacy_prompt" --dry-run 2>&1
)
legacy_dispatch_status=$?
set -e
[[ "$legacy_dispatch_status" -eq 81 ]] \
  || fail "root-pinned worktree dispatch should be refused, got $legacy_dispatch_status: $legacy_dispatch_output"
[[ "$legacy_dispatch_output" == *"DISPATCH_ROUTE_MISMATCH"* ]] \
  || fail "root-pinned worktree dispatch should report a route mismatch, got: $legacy_dispatch_output"
[[ "$legacy_dispatch_output" == *"mismatched_fields=pinned_cwd"* ]] \
  || fail "root-pinned worktree dispatch should name pinned_cwd, got: $legacy_dispatch_output"

USE_WORKTREES=0 \
ORCH_LOG_DIR="$TEST_TMP/logs" \
bash "$SANITIZED_ROOT/scripts/brief_agents.sh" \
  "$TEST_TMP/test.config.sh" \
  claude 462 \
  branch_slug="feat/issue-462" \
  summary="fix #462 render effective worktree path" \
  scope_files="scripts/brief_agents.sh" \
  validation="timeout 30 bash -n scripts/brief_agents.sh" \
  > "$base_prompt"

grep -Fq -- "- \`cd $base_repo\`" "$base_prompt" \
  || fail "base brief should continue to instruct cd into the base repo"

printf 'ok - brief_agents renders effective worktree paths\n'
