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
#!/bin/sh
set -eu
printf '%s\n' "\$*" >> "$TEST_TMP/logs/tmux.log"
case "\${1:-}" in
  has-session)
    exit 0
    ;;
  list-panes)
    # orch_tmux_probe sanity check
    exit 0
    ;;
  display-message)
    # Issue #123 readiness handshake: report the post-respawn pane state
    # from the latest respawn-pane log entry so the dispatch helper sees
    # a workdir that matches the worktree it just created.
    # Issue #322: agent_pane_ready now batches command + path into one
    # display-message call separated by ASCII US (\x1f); detect that
    # combined format string and emit command + path together.
    fmt=""
    batched=0
    for arg in "\$@"; do
      case "\$arg" in
        *'#{pane_current_command}'*'#{pane_current_path}'*)
          batched=1
          ;;
        '#{pane_current_path}'|'#{pane_current_command}')
          fmt=\$arg
          ;;
      esac
    done
    last_workdir=\$(awk '/^respawn-pane / { for (i=1;i<=NF;i++) if (\$i=="-c") { print \$(i+1); exit } }' "$TEST_TMP/logs/tmux.log" 2>/dev/null || true)
    if [ "\$batched" = "1" ]; then
      # \037 == ASCII US (0x1f). Octal so /bin/sh printf honors it.
      printf 'claude\037%s\n' "\${last_workdir:-/}"
    elif [ "\$fmt" = '#{pane_current_path}' ]; then
      printf '%s\n' "\${last_workdir:-/}"
    elif [ "\$fmt" = '#{pane_current_command}' ]; then
      printf '%s\n' "claude"
    fi
    exit 0
    ;;
esac
exit 0
EOF
chmod +x "$TEST_TMP/bin/tmux"

cat > "$TEST_TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "pr" && "${2:-}" == "list" ]]; then
  head=""
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --head)
        head=${2:-}
        shift 2
        ;;
      *)
        shift
        ;;
    esac
  done
  case "$head" in
    feat/same-pr-rebase)
      printf '[{"number":5006,"headRefName":"feat/same-pr-rebase","headRefOid":"samepr","mergeStateStatus":"BEHIND"}]\n'
      ;;
    *)
      printf '[]\n'
      ;;
  esac
  exit 0
fi
printf '[]\n'
EOF
chmod +x "$TEST_TMP/bin/gh"

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
local_validators_prompt="$TEST_TMP/local-validators.md"
heavy_prompt="$TEST_TMP/heavy.md"

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
grep -q 'require-local-validators: no' "$generated_prompt" || fail "default brief must mark local validators disabled"
grep -q 'CI-delegated' "$generated_prompt" || fail "default brief must use CI-delegated validation guidance"
! grep -q 'timeout 300 bash scripts/run_shell_tests.sh' "$generated_prompt" \
  || fail "default brief must not mandate full local shell tests"

PATH="$TEST_TMP/bin:$PATH" \
ORCH_LOG_DIR="$TEST_TMP/logs" \
bash "$SANITIZED_ROOT/scripts/brief_agents.sh" "$TEST_TMP/test.config.sh" claude 5006 --require-local-validators summary="Local validators" > "$local_validators_prompt"

grep -q 'require-local-validators: yes' "$local_validators_prompt" || fail "opt-in brief must mark local validators enabled"
grep -q 'timeout 300 bash scripts/run_shellcheck.sh' "$local_validators_prompt" || fail "opt-in brief must include shellcheck runner"
grep -q 'timeout 300 bash scripts/run_shell_tests.sh' "$local_validators_prompt" || fail "opt-in brief must include shell tests runner"
grep -q 'timeout 300 bash scripts/run_bats.sh' "$local_validators_prompt" || fail "opt-in brief must include bats runner"

set +e
heavy_validation_output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  bash "$SANITIZED_ROOT/scripts/brief_agents.sh" "$TEST_TMP/test.config.sh" claude 5007 \
    summary="Heavy validation without opt-in" \
    validation="timeout 300 bash scripts/run_shell_tests.sh" 2>&1
)
heavy_validation_status=$?
set -e
[[ "$heavy_validation_status" -eq 78 ]] || \
  fail "heavy local validation must be refused without opt-in, got $heavy_validation_status: $heavy_validation_output"
[[ "$heavy_validation_output" == *"--require-local-validators"* ]] || \
  fail "heavy validation refusal should explain opt-in flag, got: $heavy_validation_output"

cp "$generated_prompt" "$heavy_prompt"
printf '\nManual heavy validation:\n- timeout 300 bash scripts/run_shell_tests.sh\n' >> "$heavy_prompt"
set +e
heavy_dispatch_output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  bash "$SANITIZED_ROOT/scripts/dispatch_ticket.sh" "$TEST_TMP/test.config.sh" claude 5008 "$heavy_prompt" --dry-run 2>&1
)
heavy_dispatch_status=$?
set -e
[[ "$heavy_dispatch_status" -eq 78 ]] || \
  fail "dispatch must refuse heavy local validators without opt-in, got $heavy_dispatch_status: $heavy_dispatch_output"
[[ "$heavy_dispatch_output" == *"--require-local-validators"* ]] || \
  fail "dispatch refusal should explain opt-in flag, got: $heavy_dispatch_output"

set +e
heavy_dispatch_optin_output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  bash "$SANITIZED_ROOT/scripts/dispatch_ticket.sh" "$TEST_TMP/test.config.sh" claude 5009 "$heavy_prompt" --require-local-validators --dry-run 2>&1
)
heavy_dispatch_optin_status=$?
set -e
[[ "$heavy_dispatch_optin_status" -eq 0 ]] || \
  fail "dispatch opt-in should allow heavy local validators, got: $heavy_dispatch_optin_output"

host_gate_load="$TEST_TMP/host-gate.loadavg"
host_gate_df="$TEST_TMP/host-gate.df"
host_gate_ps="$TEST_TMP/host-gate.ps"
printf '10.00 9.00 8.00 1/100 555\n' > "$host_gate_load"
cat > "$host_gate_df" <<'EOF'
Filesystem     1024-blocks Used Available Capacity Mounted on
/dev/root              1000  940        60      94% /
EOF
cat > "$host_gate_ps" <<'EOF'
303 1 1800 1.0 bash backup_worker --fixture
EOF

set +e
host_gate_dispatch_output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  ORCH_HOST_LOAD_GATE=1 \
  ORCH_HOST_GATE_LOADAVG_FILE="$host_gate_load" \
  ORCH_HOST_GATE_CPU_COUNT=2 \
  ORCH_HOST_GATE_LOAD_PER_CPU_MAX=2 \
  ORCH_HOST_GATE_FORK_LATENCY_MS=900 \
  ORCH_HOST_GATE_FORK_LATENCY_MAX_MS=500 \
  ORCH_HOST_GATE_DF_FILE="$host_gate_df" \
  ORCH_HOST_GATE_DISK_USED_MAX_PCT=90 \
  ORCH_HOST_GATE_PS_FILE="$host_gate_ps" \
  ORCH_HOST_GATE_PROCESS_MARKER_RE='backup_worker' \
  bash "$SANITIZED_ROOT/scripts/dispatch_ticket.sh" "$TEST_TMP/test.config.sh" claude 5010 "$local_validators_prompt" --require-local-validators --dry-run 2>&1
)
host_gate_dispatch_status=$?
set -e
[[ "$host_gate_dispatch_status" -eq 75 ]] || \
  fail "local validator opt-in should be gated on degraded host, got $host_gate_dispatch_status: $host_gate_dispatch_output"
[[ "$host_gate_dispatch_output" == *"host_degraded"* ]] || \
  fail "local validator gate should report host_degraded, got: $host_gate_dispatch_output"
grep -q 'HOST_GATE refuse context=local_validators:dispatch-test:claude:#5010' "$TEST_TMP/logs/dispatch-test.log" \
  || fail "local validator gate refusal should be audit logged"

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
  {"alias":"dispatch-test","project":"dispatch-test","label":"rbok-claude","workdir":"$TEST_TMP/repos/rbok-claude","ready":1,"status":"ready","priority":100,"source":"portfolio_matrix"}
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
  {"alias":"dispatch-test","project":"dispatch-test","label":"rbok-claude","workdir":"$TEST_TMP/repos/rbok-claude","ready":0,"status":"dirty_worktree","priority":100,"source":"portfolio_matrix"}
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

[[ "$matrix_status" -eq 0 ]] || fail "matrix dispatch should succeed, preflight=$(cat "$preflight_file" 2>/dev/null || true), got: $matrix_output"
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

# #127 — duplicate-clone remote mismatch must be refused before matrix dispatch.
other_origin="$TEST_TMP/other-origin.git"
git init --bare "$other_origin" >/dev/null
git -C "$TEST_TMP/seed" remote add other "$other_origin"
git -C "$TEST_TMP/seed" push -u other main >/dev/null

mismatch_workdir="$TEST_TMP/repos/rbok-mismatch"
git clone "$other_origin" "$mismatch_workdir" >/dev/null 2>&1
git -C "$mismatch_workdir" checkout main >/dev/null
git -C "$mismatch_workdir" config user.name "Mismatch Agent"
git -C "$mismatch_workdir" config user.email "mismatch@test.local"

cat > "$TEST_TMP/portfolio-mismatch.config.sh" <<EOF
PORTFOLIO_NAME="dispatch-portfolio-mismatch"
PORTFOLIO_PROJECTS=(
  "dispatch-test|$TEST_TMP/test.config.sh"
)
PORTFOLIO_ENSURE_AGENT_MATRIX=1
PORTFOLIO_FLEET_AGENTS=(
  "rbok-mismatch|rbok-mismatch:0.0"
)
EOF

set +e
duplicate_output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  bash "$SANITIZED_ROOT/scripts/dispatch_ticket.sh" "$TEST_TMP/test.config.sh" rbok-mismatch 5004 "$generated_prompt" --portfolio "$TEST_TMP/portfolio-mismatch.config.sh" 2>&1
)
duplicate_status=$?
set -e

[[ "$duplicate_status" -eq 4 ]] || fail "duplicate-clone mismatch should exit 4, got $duplicate_status: $duplicate_output"
[[ "$duplicate_output" == *"duplicate-clone context mismatch"* ]] || fail "expected duplicate-clone diagnostic, got: $duplicate_output"
grep -q 'DISPATCH REFUSED reason=duplicate_clone_remote_mismatch' "$TEST_TMP/logs"/*.log || fail "expected audit refusal line for duplicate clone"

# #127 — matrix workdir not ready (dirty worktree) must be refused before dispatch.
dirty_workdir="$TEST_TMP/repos/rbok-dirty"
git clone "$TEST_TMP/origin.git" "$dirty_workdir" >/dev/null 2>&1
git -C "$dirty_workdir" checkout main >/dev/null
git -C "$dirty_workdir" config user.name "Dirty Agent"
git -C "$dirty_workdir" config user.email "dirty@test.local"
printf 'uncommitted\n' > "$dirty_workdir/UNCOMMITTED.txt"

cat > "$TEST_TMP/portfolio-dirty.config.sh" <<EOF
PORTFOLIO_NAME="dispatch-portfolio-dirty"
PORTFOLIO_PROJECTS=(
  "dispatch-test|$TEST_TMP/test.config.sh"
)
PORTFOLIO_ENSURE_AGENT_MATRIX=1
PORTFOLIO_FLEET_AGENTS=(
  "rbok-dirty|rbok-dirty:0.0"
)
EOF

cat > "$preflight_file" <<JSON
[
  {"alias":"dispatch-test","project":"dispatch-test","label":"rbok-dirty","workdir":"$dirty_workdir","ready":1,"status":"ready","priority":100,"source":"portfolio_matrix"}
]
JSON
touch "$preflight_file"

set +e
dirty_output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  bash "$SANITIZED_ROOT/scripts/dispatch_ticket.sh" "$TEST_TMP/test.config.sh" rbok-dirty 5005 "$generated_prompt" --portfolio "$TEST_TMP/portfolio-dirty.config.sh" 2>&1
)
dirty_status=$?
set -e

[[ "$dirty_status" -eq 4 ]] || fail "dirty matrix workdir should exit 4, got $dirty_status: $dirty_output"
# #367 — refusal stderr must surface the structured readiness state and
# the dirty count proven by porcelain. The old generic "uncommitted
# change" wording is replaced by the precise state=dirty diagnostic.
[[ "$dirty_output" == *"state=dirty"* ]] || fail "expected state=dirty in refusal output, got: $dirty_output"
[[ "$dirty_output" == *"dirty=1"* ]] || fail "expected porcelain-proven dirty=1 in refusal output, got: $dirty_output"
grep -q 'DISPATCH REFUSED reason=matrix_workdir_not_ready' "$TEST_TMP/logs"/*.log || fail "expected audit refusal line for not-ready matrix workdir"
grep -q 'state=dirty' "$TEST_TMP/logs"/*.log || fail "expected audit log to include readiness state, got log without state=dirty"
grep -q 'destructive=1' "$TEST_TMP/logs"/*.log || fail "expected audit log to mark dirty refusal as destructive=1"

# #380 — a clean non-default branch with an open PR matching the dispatched
# PR-op ticket is dispatchable for same-PR repair work, even when portfolio
# preflight marks it not_ready because it needs rebase. This is not capacity
# for unrelated new work; it only re-enters the same PR branch.
same_pr_workdir="$TEST_TMP/repos/rbok-same-pr"
git clone "$TEST_TMP/origin.git" "$same_pr_workdir" >/dev/null 2>&1
git -C "$same_pr_workdir" checkout -b feat/same-pr-rebase >/dev/null
git -C "$same_pr_workdir" config user.name "Same PR Agent"
git -C "$same_pr_workdir" config user.email "same-pr@test.local"

printf 'advance main\n' >> "$TEST_TMP/seed/README.md"
git -C "$TEST_TMP/seed" add README.md
git -C "$TEST_TMP/seed" commit -m "advance main for same-pr rebase" >/dev/null
git -C "$TEST_TMP/seed" push origin main >/dev/null
git -C "$same_pr_workdir" fetch origin main >/dev/null 2>&1

cat > "$TEST_TMP/portfolio-same-pr.config.sh" <<EOF
PORTFOLIO_NAME="dispatch-portfolio-same-pr"
PORTFOLIO_PROJECTS=(
  "dispatch-test|$TEST_TMP/test.config.sh"
)
PORTFOLIO_ENSURE_AGENT_MATRIX=1
PORTFOLIO_FLEET_AGENTS=(
  "rbok-same-pr|rbok-same-pr:0.0"
)
EOF

cat > "$preflight_file" <<JSON
[
  {"alias":"dispatch-test","project":"dispatch-test","label":"rbok-same-pr","workdir":"$same_pr_workdir","ready":0,"status":"branch_needs_rebase","priority":100,"source":"portfolio_matrix"}
]
JSON
touch "$preflight_file"

set +e
same_pr_output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  bash "$SANITIZED_ROOT/scripts/dispatch_ticket.sh" "$TEST_TMP/test.config.sh" rbok-same-pr 5006 "$generated_prompt" --portfolio "$TEST_TMP/portfolio-same-pr.config.sh" --dry-run 2>&1
)
same_pr_status=$?
set -e

[[ "$same_pr_status" -eq 0 ]] || fail "same-PR rebase dispatch should proceed, got $same_pr_status: $same_pr_output"
[[ "$same_pr_output" == *"tmux send-keys -t rbok-same-pr:0.0"* ]] || fail "same-PR dispatch should target same PR pane: $same_pr_output"
grep -q 'DISPATCH PREFLIGHT SAME_PR_OK agent=rbok-same-pr ticket=#5006' "$TEST_TMP/logs"/*.log || fail "same-PR bypass must be audited"

rm -f /tmp/dispatch-claude-5004.md /tmp/dispatch-claude-5005.md

# ---------------------------------------------------------------------------
# Issue #273 — explicit GitHub assignment policy.
#
# Three fixtures cover the policy decision matrix:
#   1. assignment disabled (default): audit must record
#      `assignee_policy=skipped reason=disabled-by-default ledger=...`
#      and the local assignments.json must still be written.
#   2. assignment enabled with matching identity: audit must record
#      `assignee_policy=applied login=...` and the mock `gh issue edit`
#      must observe the `--add-assignee` call.
#   3. assignment enabled with identity mismatch: audit must record
#      `assignee_policy=refused reason=identity-mismatch`, the mock
#      `gh issue edit` must NOT have been called, and dispatch must
#      still exit 0 so a single agent's drift does not knock out the
#      whole wave.
# ---------------------------------------------------------------------------

policy_state_dir="$TEST_TMP/state-policy"
policy_log_dir="$TEST_TMP/logs-policy"
gh_call_log="$TEST_TMP/logs-policy/gh-issue-edit.log"
mkdir -p "$policy_log_dir"

# Mock `gh` for the policy fixtures: `gh api user --jq .login` echoes the
# configured POLICY_GH_ACTIVE_LOGIN, `gh issue edit ... --add-assignee X`
# records the full argv to gh-issue-edit.log, and everything else is a
# no-op success.
cat > "$TEST_TMP/bin/gh" <<EOF
#!/bin/sh
set -eu
log_file="$gh_call_log"
case "\${1:-}-\${2:-}" in
  api-user)
    printf '%s\n' "\${POLICY_GH_ACTIVE_LOGIN:-}"
    exit 0
    ;;
  issue-edit)
    printf '%s\n' "\$*" >> "\$log_file"
    if [ "\${POLICY_GH_ISSUE_EDIT_FAIL:-0}" = "1" ]; then
      printf 'mock gh issue edit forced failure\n' >&2
      exit 7
    fi
    printf '%s\n' "https://github.com/example/repo/issues/\${3:-0}"
    exit 0
    ;;
esac
exit 0
EOF
chmod +x "$TEST_TMP/bin/gh"
: > "$gh_call_log"

# 1. assignment disabled (default) → policy=skipped, ledger pointer surfaced.
set +e
disabled_output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  ORCH_LOG_DIR="$policy_log_dir" \
  ORCH_STATE_BASE="$policy_state_dir" \
  bash "$SANITIZED_ROOT/scripts/dispatch_ticket.sh" \
    "$TEST_TMP/test.config.sh" claude 5101 "$generated_prompt" --dry-run 2>&1
)
disabled_status=$?
set -e
[[ "$disabled_status" -eq 0 ]] \
  || fail "assignment-disabled dispatch should succeed, got $disabled_status: $disabled_output"
[[ "$disabled_output" == *"GitHub assignment disabled by policy"* ]] \
  || fail "default dispatch should surface the ledger pointer on stderr, got: $disabled_output"
[[ "$disabled_output" == *"$policy_state_dir/dispatch-test/assignments.json"* ]] \
  || fail "default dispatch stderr should reference the ledger path, got: $disabled_output"
disabled_log="$policy_log_dir/dispatch-test.log"
grep -q 'DISPATCH assignee_policy=skipped ticket=#5101 reason=disabled-by-default ledger=' "$disabled_log" \
  || fail "default dispatch should audit policy=skipped reason=disabled-by-default, log: $(cat "$disabled_log" 2>/dev/null)"
[[ ! -s "$gh_call_log" ]] \
  || fail "default dispatch must not call gh issue edit, log: $(cat "$gh_call_log")"

# 2. assignment enabled + identity match → policy=applied, gh issue edit invoked.
: > "$gh_call_log"
mkdir -p "$TEST_TMP/no-such-repos/claude"
git -C "$TEST_TMP/no-such-repos/claude" init -q 2>/dev/null || true
git -C "$TEST_TMP/no-such-repos/claude" config user.email "policy@test.local" 2>/dev/null || true
git -C "$TEST_TMP/no-such-repos/claude" config user.name "Policy Test" 2>/dev/null || true

cat > "$TEST_TMP/policy-match.config.sh" <<EOF
#!/usr/bin/env bash
PROJECT="dispatch-test"
GH_REPO="RBOKproject/ORDO"
GH_CONFIG_DIR="$TEST_TMP/gh"
DEFAULT_BRANCH="main"
AGENT_SESSION_PREFIX=""
AGENT_REPO_PREFIX="$TEST_TMP/repos/"
SUPERVISOR_REPO=""
export AGENT_WORKDIR_TEMPLATE="$TEST_TMP/repos/%s"
USE_WORKTREES=0
EOF

# Issue #273 / PR #300 + Required Rule 12 (#289): the `--assign` path is
# gated twice — first by the identity guard, then by the external-PR-mutation
# gate (`external_pr_mutation_assert issue_assignees`). The first two
# fixtures in this matrix exercised the audit lines without authorizing the
# downstream mutation, so the dispatch correctly refused with exit 80
# (`reason=external-pr-mutation-gate`) once Rule 12 landed. Authorize the
# `issue_assignees` scope explicitly for the assign+match fixture so the
# `policy=applied` happy path is exercised end-to-end. The mismatch fixture
# below intentionally omits the scope: the identity guard short-circuits
# first and the mutation gate is never reached.
set +e
match_output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  ORCH_LOG_DIR="$policy_log_dir" \
  ORCH_STATE_BASE="$policy_state_dir" \
  ORCH_CONTEXT_PROOF=0 \
  ORCH_CONTEXT_PROOF_WAIT_SEC=0 \
  POLICY_GH_ACTIVE_LOGIN="claude" \
  ORCH_GH_EXPECTED_LOGIN="claude" \
  ORCH_EXTERNAL_PR_MUTATIONS="issue_assignees" \
  bash "$SANITIZED_ROOT/scripts/dispatch_ticket.sh" \
    "$TEST_TMP/policy-match.config.sh" claude 5102 "$generated_prompt" --assign 2>&1
)
match_status=$?
set -e
[[ "$match_status" -eq 0 ]] \
  || fail "assign+match dispatch should succeed, got $match_status: $match_output"
match_log="$policy_log_dir/dispatch-test.log"
grep -q 'DISPATCH assignee_policy=applied ticket=#5102 login=claude ledger=' "$match_log" \
  || fail "assign+match should audit policy=applied login=claude, log: $(cat "$match_log" 2>/dev/null)"
grep -q 'issue edit 5102 --repo RBOKproject/ORDO --add-assignee claude' "$gh_call_log" \
  || fail "assign+match should invoke gh issue edit with --add-assignee, log: $(cat "$gh_call_log" 2>/dev/null)"

# 3. assignment enabled + identity mismatch → policy=refused, gh edit NOT called.
: > "$gh_call_log"
set +e
mismatch_assign_output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  ORCH_LOG_DIR="$policy_log_dir" \
  ORCH_STATE_BASE="$policy_state_dir" \
  ORCH_CONTEXT_PROOF=0 \
  ORCH_CONTEXT_PROOF_WAIT_SEC=0 \
  POLICY_GH_ACTIVE_LOGIN="someone-else" \
  ORCH_GH_EXPECTED_LOGIN="claude" \
  bash "$SANITIZED_ROOT/scripts/dispatch_ticket.sh" \
    "$TEST_TMP/policy-match.config.sh" claude 5103 "$generated_prompt" --assign 2>&1
)
mismatch_assign_status=$?
set -e
[[ "$mismatch_assign_status" -eq 0 ]] \
  || fail "assign+mismatch dispatch should still exit 0 so wave continues, got $mismatch_assign_status: $mismatch_assign_output"
[[ "$mismatch_assign_output" == *"github_identity_mismatch"* ]] \
  || fail "assign+mismatch should surface guard mismatch on stderr, got: $mismatch_assign_output"
mismatch_log="$policy_log_dir/dispatch-test.log"
grep -q 'DISPATCH assignee_policy=refused ticket=#5103' "$mismatch_log" \
  || fail "assign+mismatch should audit policy=refused, log: $(cat "$mismatch_log" 2>/dev/null)"
grep -q 'reason=identity-mismatch' "$mismatch_log" \
  || fail "assign+mismatch audit must record reason=identity-mismatch, log: $(cat "$mismatch_log" 2>/dev/null)"
grep -q 'expected_login=claude active_login=someone-else' "$mismatch_log" \
  || fail "assign+mismatch audit must record expected vs active login, log: $(cat "$mismatch_log" 2>/dev/null)"
[[ ! -s "$gh_call_log" ]] \
  || fail "assign+mismatch must not call gh issue edit, log: $(cat "$gh_call_log")"

rm -f /tmp/dispatch-claude-5101.md /tmp/dispatch-claude-5102.md /tmp/dispatch-claude-5103.md

printf 'ok - dispatch prompt canonical validation and bypass\n'
