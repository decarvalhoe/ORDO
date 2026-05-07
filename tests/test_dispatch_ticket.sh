#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP=$(mktemp -d)
SANITIZED_ROOT="$TEST_TMP/toolkit"

cleanup() {
  rm -rf "$TEST_TMP"
  rm -f /tmp/dispatch-claude-5001.md /tmp/dispatch-claude-5002.md /tmp/dispatch-rbok-claude-5003.md
}
trap cleanup EXIT

fail() {
  printf 'not ok - %s\n' "$*" >&2
  exit 1
}

mkdir -p "$TEST_TMP/bin" "$TEST_TMP/logs" "$TEST_TMP/repos"

# shellcheck source=../lib/test_sanitize.sh
source "$ROOT/lib/test_sanitize.sh"
sanitize_toolkit_copy "$SANITIZED_ROOT" \
  scripts/brief_agents.sh \
  scripts/dispatch_ticket.sh \
  templates/dispatch-canonical.md.tpl

chmod +x "$SANITIZED_ROOT/scripts/brief_agents.sh" "$SANITIZED_ROOT/scripts/dispatch_ticket.sh"

cat > "$TEST_TMP/test.config.sh" <<EOF
#!/usr/bin/env bash
PROJECT="dispatch-test"
GH_REPO="RBOKproject/ORDO"
GH_CONFIG_DIR="$TEST_TMP/gh"
DEFAULT_BRANCH="main"
REPO_URL="$TEST_TMP/origin.git"
AGENT_SESSION_PREFIX=""
AGENT_REPO_PREFIX="$TEST_TMP/repos/"
SUPERVISOR_REPO="orchestrator"
export AGENT_WORKDIR_TEMPLATE="$TEST_TMP/repos/%s"
USE_WORKTREES="\${USE_WORKTREES:-0}"
ORCH_WORKTREES_DIR="\${ORCH_WORKTREES_DIR:-$TEST_TMP/agent-worktrees}"
EOF

cat > "$TEST_TMP/bin/tmux" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "\$*" >> "$TEST_TMP/logs/tmux.log"
if [[ "\${1:-}" == "has-session" ]]; then
  exit 0
fi
exit 0
EOF
chmod +x "$TEST_TMP/bin/tmux"

git init --bare "$TEST_TMP/origin.git" >/dev/null
git init "$TEST_TMP/seed" >/dev/null
git -C "$TEST_TMP/seed" config user.name "Dispatch Test"
git -C "$TEST_TMP/seed" config user.email "dispatch@test.local"
git -C "$TEST_TMP/seed" checkout -b main >/dev/null
printf 'seed\n' > "$TEST_TMP/seed/README.md"
git -C "$TEST_TMP/seed" add README.md
git -C "$TEST_TMP/seed" commit -m "seed" >/dev/null
git -C "$TEST_TMP/seed" remote add origin "$TEST_TMP/origin.git"
git -C "$TEST_TMP/seed" push -u origin main >/dev/null
git clone "$TEST_TMP/origin.git" "$TEST_TMP/repos/claude" >/dev/null 2>&1
git -C "$TEST_TMP/repos/claude" checkout main >/dev/null
git -C "$TEST_TMP/repos/claude" config user.name "Dispatch Claude"
git -C "$TEST_TMP/repos/claude" config user.email "claude@test.local"
git clone "$TEST_TMP/origin.git" "$TEST_TMP/repos/rbok-claude" >/dev/null 2>&1
git -C "$TEST_TMP/repos/rbok-claude" checkout main >/dev/null
git -C "$TEST_TMP/repos/rbok-claude" config user.name "Dispatch Matrix"
git -C "$TEST_TMP/repos/rbok-claude" config user.email "matrix@test.local"

cat > "$TEST_TMP/portfolio.config.sh" <<EOF
PORTFOLIO_NAME="dispatch-portfolio"
PORTFOLIO_PROJECTS=(
  "dispatch-test|$TEST_TMP/test.config.sh"
)
PORTFOLIO_ENSURE_AGENT_MATRIX=1
PORTFOLIO_FLEET_AGENTS=(
  "rbok-claude|rbok-claude:0.0"
)
EOF

generated_prompt="$TEST_TMP/generated.md"
origin_only_prompt="$TEST_TMP/origin-only.md"
invalid_prompt="$TEST_TMP/invalid.md"

PATH="$TEST_TMP/bin:$PATH" \
ORCH_LOG_DIR="$TEST_TMP/logs" \
bash "$SANITIZED_ROOT/scripts/brief_agents.sh" "$TEST_TMP/test.config.sh" claude 5001 summary="Prompt canon test" validation="bash tests.sh" > "$generated_prompt"

for heading in \
  "## Objectif" \
  "## Format de sortie attendu" \
  "## Tools / sources autorises" \
  "## Boundaries / interdictions" \
  "## Definition of Done verifiable" \
  "## Preuves attendues"
do
  grep -q "$heading" "$generated_prompt" || fail "generated prompt missing heading: $heading"
done

grep -Fq "\`git fetch orchestrator\`" "$generated_prompt" || fail "supervisor remote should still render when configured"
grep -q 'base: orchestrator/main @ HEAD' "$generated_prompt" || fail "supervisor base ref should render in final report format"

cat > "$TEST_TMP/origin-only.config.sh" <<EOF
#!/usr/bin/env bash
PROJECT="dispatch-test"
GH_REPO="RBOKproject/ORDO"
GH_CONFIG_DIR="$TEST_TMP/gh"
DEFAULT_BRANCH="main"
AGENT_SESSION_PREFIX=""
AGENT_REPO_PREFIX="$TEST_TMP/repos/"
SUPERVISOR_REPO=""
export AGENT_WORKDIR_TEMPLATE="$TEST_TMP/repos/%s"
USE_WORKTREES="\${USE_WORKTREES:-0}"
ORCH_WORKTREES_DIR="\${ORCH_WORKTREES_DIR:-$TEST_TMP/agent-worktrees}"
EOF

base_sha=$(git -C "$TEST_TMP/repos/claude" rev-parse origin/main)
git -C "$TEST_TMP/repos/claude" remote get-url origin >/dev/null || fail "origin-only clone should have origin"
if git -C "$TEST_TMP/repos/claude" remote get-url orchestrator >/dev/null 2>&1; then
  fail "origin-only clone should not have orchestrator remote"
fi

PATH="$TEST_TMP/bin:$PATH" \
ORCH_LOG_DIR="$TEST_TMP/logs" \
bash "$SANITIZED_ROOT/scripts/brief_agents.sh" "$TEST_TMP/origin-only.config.sh" claude 5003 base_sha="$base_sha" summary="Origin fallback" validation="bash tests.sh" > "$origin_only_prompt"

if grep -Fq "\`git fetch orchestrator\`" "$origin_only_prompt"; then
  fail "empty SUPERVISOR_REPO should not render mandatory orchestrator fetch"
fi
grep -Fq "\`git fetch origin\`" "$origin_only_prompt" || fail "empty SUPERVISOR_REPO should render origin fetch"
grep -q "base: origin/main @ $base_sha" "$origin_only_prompt" || fail "origin fallback should render base proof"
grep -q 'remote equivalent' "$origin_only_prompt" || fail "prompt should document equivalent remote fallback semantics"

cat > "$invalid_prompt" <<'EOF'
# Prompt cassé

Pas de structure canonique ici.
EOF

set +e
invalid_output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  bash "$SANITIZED_ROOT/scripts/dispatch_ticket.sh" "$TEST_TMP/test.config.sh" claude 5002 "$invalid_prompt" 2>&1
)
invalid_status=$?
set -e

[[ "$invalid_status" -ne 0 ]] || fail "invalid prompt should be refused"
[[ "$invalid_output" == *"missing canonical sections"* ]] || fail "expected canonical validation error, got: $invalid_output"

set +e
bypass_output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  bash "$SANITIZED_ROOT/scripts/dispatch_ticket.sh" "$TEST_TMP/test.config.sh" claude 5002 "$invalid_prompt" --no-validate --dry-run 2>&1
)
bypass_status=$?
set -e

[[ "$bypass_status" -eq 0 ]] || fail "bypass dispatch should succeed, got: $bypass_output"
[[ "$bypass_output" == *"VALIDATION BYPASSED"* ]] || fail "expected audit of bypass, got: $bypass_output"
[[ "$bypass_output" == *"DRY-RUN:"* ]] || fail "expected dry-run logs on bypass path"

preflight_dir="$TEST_TMP/state/_portfolio"
mkdir -p "$preflight_dir"
preflight_file="$preflight_dir/session_start.json"

write_preflight_ready() {
  cat > "$preflight_file" <<JSON
[
  {"alias":"dispatch-test","label":"rbok-claude","ready":1,"status":"ready","priority":100,"source":"portfolio_matrix"}
]
JSON
  touch "$preflight_file"
}

# AC: missing preflight must fail closed before reaching tmux.
rm -f "$preflight_file"
set +e
missing_preflight_output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  bash "$SANITIZED_ROOT/scripts/dispatch_ticket.sh" "$TEST_TMP/test.config.sh" rbok-claude 5003 "$generated_prompt" --portfolio "$TEST_TMP/portfolio.config.sh" --dry-run 2>&1
)
missing_preflight_status=$?
set -e
[[ "$missing_preflight_status" -ne 0 ]] || fail "missing preflight should fail closed, got: $missing_preflight_output"
[[ "$missing_preflight_output" == *"portfolio_preflight_required"* ]] \
  || fail "expected portfolio_preflight_required on missing preflight, got: $missing_preflight_output"
[[ "$missing_preflight_output" == *"status=missing"* ]] \
  || fail "expected explicit missing status, got: $missing_preflight_output"

# AC: stale preflight must fail closed (older than max age).
write_preflight_ready
touch -d "@$(($(date +%s) - 7200))" "$preflight_file"
set +e
stale_preflight_output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  PORTFOLIO_PREFLIGHT_MAX_AGE_SEC=3600 \
  bash "$SANITIZED_ROOT/scripts/dispatch_ticket.sh" "$TEST_TMP/test.config.sh" rbok-claude 5003 "$generated_prompt" --portfolio "$TEST_TMP/portfolio.config.sh" --dry-run 2>&1
)
stale_preflight_status=$?
set -e
[[ "$stale_preflight_status" -ne 0 ]] || fail "stale preflight should fail closed, got: $stale_preflight_output"
[[ "$stale_preflight_output" == *"portfolio_preflight_required"* ]] \
  || fail "expected portfolio_preflight_required on stale preflight, got: $stale_preflight_output"
[[ "$stale_preflight_output" == *"status=stale"* ]] \
  || fail "expected explicit stale status, got: $stale_preflight_output"

# AC: preflight present but agent row not ready must fail closed.
cat > "$preflight_file" <<JSON
[
  {"alias":"dispatch-test","label":"rbok-claude","ready":0,"status":"dirty_worktree","priority":100,"source":"portfolio_matrix"}
]
JSON
touch "$preflight_file"
set +e
notready_output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  bash "$SANITIZED_ROOT/scripts/dispatch_ticket.sh" "$TEST_TMP/test.config.sh" rbok-claude 5003 "$generated_prompt" --portfolio "$TEST_TMP/portfolio.config.sh" --dry-run 2>&1
)
notready_status=$?
set -e
[[ "$notready_status" -ne 0 ]] || fail "preflight not_ready should fail closed, got: $notready_output"
[[ "$notready_output" == *"portfolio_target_not_ready"* ]] \
  || fail "expected portfolio_target_not_ready, got: $notready_output"

# AC: duplicate clone with mismatched origin must fail closed with context-mismatch.
git init -q --bare "$TEST_TMP/wrong.git"
git -C "$TEST_TMP/repos/rbok-claude" remote set-url origin "$TEST_TMP/wrong.git"
write_preflight_ready
set +e
mismatch_output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  bash "$SANITIZED_ROOT/scripts/dispatch_ticket.sh" "$TEST_TMP/test.config.sh" rbok-claude 5003 "$generated_prompt" --portfolio "$TEST_TMP/portfolio.config.sh" --dry-run 2>&1
)
mismatch_status=$?
set -e
[[ "$mismatch_status" -ne 0 ]] || fail "canonical mismatch should fail closed, got: $mismatch_output"
[[ "$mismatch_output" == *"context-mismatch"* ]] || fail "expected context-mismatch, got: $mismatch_output"
git -C "$TEST_TMP/repos/rbok-claude" remote set-url origin "$TEST_TMP/origin.git"

# Happy path: fresh preflight + canonical origin → matrix dispatch succeeds.
write_preflight_ready
set +e
matrix_output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  bash "$SANITIZED_ROOT/scripts/dispatch_ticket.sh" "$TEST_TMP/test.config.sh" rbok-claude 5003 "$generated_prompt" --portfolio "$TEST_TMP/portfolio.config.sh" --dry-run 2>&1
)
matrix_status=$?
set -e

[[ "$matrix_status" -eq 0 ]] || fail "matrix dispatch should succeed, got: $matrix_output"
[[ "$matrix_output" == *"tmux send-keys -t rbok-claude:0.0"* ]] || fail "matrix dispatch should target portfolio pane: $matrix_output"
[[ "$matrix_output" == *"workdir=$TEST_TMP/repos/rbok-claude"* ]] || fail "matrix dispatch should record portfolio workdir: $matrix_output"

set +e
worktree_output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  USE_WORKTREES=1 \
  ORCH_WORKTREES_DIR="$TEST_TMP/agent-worktrees" \
  ORCH_CONTEXT_PROOF_WAIT_SEC=0 \
  bash "$SANITIZED_ROOT/scripts/dispatch_ticket.sh" "$TEST_TMP/test.config.sh" claude 5001 "$generated_prompt" 2>&1
)
worktree_status=$?
set -e

[[ "$worktree_status" -eq 0 ]] || fail "worktree dispatch should succeed, got: $worktree_output"
worktree_dir="$TEST_TMP/agent-worktrees/claude/feat-issue-5001"
git -C "$worktree_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 || fail "dispatch should create a worktree"
branch=$(git -C "$worktree_dir" branch --show-current)
[[ "$branch" == "feat/issue-5001" ]] || fail "unexpected worktree branch: $branch"
jq -e --arg dir "$worktree_dir" '
  .claude.issue == 5001 and
  .claude.branch == "feat/issue-5001" and
  .claude.workdir == $dir
' "$TEST_TMP/state/dispatch-test/assignments.json" >/dev/null || fail "dispatch should record assignment worktree metadata"
grep -q "respawn-pane" "$TEST_TMP/logs/tmux.log" || fail "worktree dispatch should repoint the tmux pane"

audit_log_file="$TEST_TMP/logs/orchestrator.audit.log"
if [[ -f "$audit_log_file" ]]; then
  grep -q "DISPATCH CONTEXT_PROOF_OK agent=claude ticket=#5001" "$audit_log_file" \
    || fail "worktree dispatch should record CONTEXT_PROOF_OK audit line"
fi

# Multi-project context-mismatch: workdir does not exist (e.g. matrix
# misconfiguration pointed at a wrong clone). Dispatch must surface a
# `dispatch-context-mismatch` blocker on stderr and exit non-zero.
cat > "$TEST_TMP/missing-workdir.config.sh" <<EOF
#!/usr/bin/env bash
PROJECT="dispatch-test"
GH_REPO="RBOKproject/ORDO"
GH_CONFIG_DIR="$TEST_TMP/gh"
DEFAULT_BRANCH="main"
AGENT_SESSION_PREFIX=""
AGENT_REPO_PREFIX="$TEST_TMP/no-such-repos/"
SUPERVISOR_REPO=""
export AGENT_WORKDIR_TEMPLATE="$TEST_TMP/no-such-repos/%s"
USE_WORKTREES=0
EOF

set +e
mismatch_output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  ORCH_CONTEXT_PROOF_WAIT_SEC=0 \
  bash "$SANITIZED_ROOT/scripts/dispatch_ticket.sh" "$TEST_TMP/missing-workdir.config.sh" claude 5004 "$generated_prompt" 2>&1
)
mismatch_status=$?
set -e

[[ "$mismatch_status" -eq 76 ]] || fail "missing workdir should exit 76, got $mismatch_status: $mismatch_output"
[[ "$mismatch_output" == *"dispatch-context-mismatch"* ]] \
  || fail "expected dispatch-context-mismatch on stderr, got: $mismatch_output"
[[ "$mismatch_output" == *"reason=workdir-missing"* ]] \
  || fail "expected reason=workdir-missing on stderr, got: $mismatch_output"

# Opt-out: ORCH_CONTEXT_PROOF=0 must skip the proof entirely so a
# degraded agent host can still dispatch when the operator accepts the
# audit-only signal.
mkdir -p "$TEST_TMP/no-such-repos/claude"
git -C "$TEST_TMP/no-such-repos/claude" init -q
git -C "$TEST_TMP/no-such-repos/claude" config user.email "ctx@test.local"
git -C "$TEST_TMP/no-such-repos/claude" config user.name  "Ctx Test"
set +e
optout_output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  ORCH_CONTEXT_PROOF=0 \
  bash "$SANITIZED_ROOT/scripts/dispatch_ticket.sh" "$TEST_TMP/missing-workdir.config.sh" claude 5005 "$generated_prompt" 2>&1
)
optout_status=$?
set -e

[[ "$optout_status" -eq 0 ]] || fail "ORCH_CONTEXT_PROOF=0 should bypass proof, got $optout_status: $optout_output"
[[ "$optout_output" != *"dispatch-context-mismatch"* ]] \
  || fail "ORCH_CONTEXT_PROOF=0 should not emit mismatch, got: $optout_output"

rm -f /tmp/dispatch-claude-5004.md /tmp/dispatch-claude-5005.md

printf 'ok - dispatch prompt canonical validation and bypass\n'
