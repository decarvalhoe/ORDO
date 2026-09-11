#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP=$(mktemp -d)
SANITIZED_ROOT="$TEST_TMP/toolkit"

cleanup() {
  rm -rf "$TEST_TMP"
  rm -f \
    /tmp/dispatch-claude-5001.md \
    /tmp/dispatch-claude-5002.md \
    /tmp/dispatch-rbok-claude-5003.md \
    /tmp/dispatch-claude-5011.md \
    /tmp/dispatch-claude-5012.md \
    /tmp/dispatch-claude-5101.md \
    /tmp/dispatch-claude-5410.md \
    /tmp/dispatch-gemini-5411.md
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
# This legacy dispatch fixture predates #573's post-dispatch pane
# acceptance gate. The gate itself is covered by test_pane_acceptance_proof.sh.
export REQUIRE_ACCEPTANCE_PROOF="\${REQUIRE_ACCEPTANCE_PROOF:-0}"
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
  capture-pane)
    printf '%s\n' "working on dispatch"
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
    last_workdir=\$(awk '/^respawn-pane / { for (i=1;i<=NF;i++) if (\$i=="-c") last=\$(i+1) } END { print last }' "$TEST_TMP/logs/tmux.log" 2>/dev/null || true)
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
  state=""
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --head)
        head=${2:-}
        shift 2
        ;;
      --state)
        state=${2:-}
        shift 2
        ;;
      *)
        shift
        ;;
    esac
  done
  # Issue #708: the auto-clear path queries `--state merged` for the
  # occupied assignment's feature branch. The "feat/issue-7100" branch
  # below stands in for a merged feature branch in the regression
  # fixture; everything else returns an empty merged list so legacy
  # pane_occupied tests still see the original refusal.
  case "$state:$head" in
    merged:feat/issue-7100)
      printf '[{"number":7099,"mergedAt":"2026-05-19T10:00:00Z","mergeCommit":{"oid":"deadbeefcafefade"}}]\n'
      exit 0
      ;;
  esac
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
worktree_generated_prompt="$TEST_TMP/generated-worktree-5001.md"
origin_only_prompt="$TEST_TMP/origin-only.md"
invalid_prompt="$TEST_TMP/invalid.md"
local_validators_prompt="$TEST_TMP/local-validators.md"
heavy_prompt="$TEST_TMP/heavy.md"
generated_base_sha=$(git -C "$TEST_TMP/repos/claude" rev-parse origin/main)
# Keep this broad legacy dispatch test focused on its historical gates. The
# pinned-base freshness guard has focused coverage in test_dispatch_base_sha_refresh.sh.
export REFUSE_STALE_BASE=0

PATH="$TEST_TMP/bin:$PATH" \
ORCH_LOG_DIR="$TEST_TMP/logs" \
bash "$SANITIZED_ROOT/scripts/brief_agents.sh" "$TEST_TMP/test.config.sh" claude 5001 summary="Prompt canon test" scope_files="lib/foo.sh" validation="bash tests.sh" > "$generated_prompt"

PATH="$TEST_TMP/bin:$PATH" \
ORCH_LOG_DIR="$TEST_TMP/logs" \
USE_WORKTREES=1 \
ORCH_WORKTREES_DIR="$TEST_TMP/agent-worktrees" \
bash "$SANITIZED_ROOT/scripts/brief_agents.sh" "$TEST_TMP/test.config.sh" claude 5001 summary="Prompt canon test" scope_files="lib/foo.sh" validation="bash tests.sh" > "$worktree_generated_prompt"

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
grep -q "base: orchestrator/main @ $generated_base_sha" "$generated_prompt" || fail "supervisor base ref should render concrete base SHA"
grep -q 'require-local-validators: no' "$generated_prompt" || fail "default brief must mark local validators disabled"
grep -q 'CI-delegated' "$generated_prompt" || fail "default brief must use CI-delegated validation guidance"
! grep -q 'timeout 300 bash scripts/run_shell_tests.sh' "$generated_prompt" \
  || fail "default brief must not mandate full local shell tests"

PATH="$TEST_TMP/bin:$PATH" \
ORCH_LOG_DIR="$TEST_TMP/logs" \
bash "$SANITIZED_ROOT/scripts/brief_agents.sh" "$TEST_TMP/test.config.sh" claude 5006 --require-local-validators summary="Local validators" scope_files="lib/foo.sh" > "$local_validators_prompt"

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
    scope_files="lib/foo.sh" \
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
export REQUIRE_ACCEPTANCE_PROOF="\${REQUIRE_ACCEPTANCE_PROOF:-0}"
EOF

base_sha=$(git -C "$TEST_TMP/repos/claude" rev-parse origin/main)
git -C "$TEST_TMP/repos/claude" remote get-url origin >/dev/null || fail "origin-only clone should have origin"
if git -C "$TEST_TMP/repos/claude" remote get-url orchestrator >/dev/null 2>&1; then
  fail "origin-only clone should not have orchestrator remote"
fi

PATH="$TEST_TMP/bin:$PATH" \
ORCH_LOG_DIR="$TEST_TMP/logs" \
bash "$SANITIZED_ROOT/scripts/brief_agents.sh" "$TEST_TMP/origin-only.config.sh" claude 5003 base_sha="$base_sha" summary="Origin fallback" scope_files="lib/foo.sh" validation="bash tests.sh" > "$origin_only_prompt"

if grep -Fq "\`git fetch orchestrator\`" "$origin_only_prompt"; then
  fail "empty SUPERVISOR_REPO should not render mandatory orchestrator fetch"
fi
grep -Fq "\`git fetch origin\`" "$origin_only_prompt" || fail "empty SUPERVISOR_REPO should render origin fetch"
grep -q "base: origin/main @ $base_sha" "$origin_only_prompt" || fail "origin fallback should render base proof"
grep -q 'remote equivalent' "$origin_only_prompt" || fail "prompt should document equivalent remote fallback semantics"

# Issue #481: a held/collision-resumed brief may be read after the mutable
# default branch has advanced. The accepted immutable base is still valid when
# it is an ancestor of the refreshed default ref; that is pinned-base drift, not
# a context mismatch.
held_base_sha="$base_sha"
printf 'advance default after held brief\n' >> "$TEST_TMP/seed/README.md"
git -C "$TEST_TMP/seed" add README.md
git -C "$TEST_TMP/seed" commit -m "advance main after held brief render" >/dev/null
git -C "$TEST_TMP/seed" push origin main >/dev/null
git -C "$TEST_TMP/repos/claude" fetch origin main >/dev/null 2>&1
held_current_sha=$(git -C "$TEST_TMP/repos/claude" rev-parse origin/main)
[[ "$held_current_sha" != "$held_base_sha" ]] \
  || fail "held fixture should advance origin/main after prompt render"
git -C "$TEST_TMP/repos/claude" merge-base --is-ancestor "$held_base_sha" origin/main \
  || fail "held accepted base should remain an ancestor of advanced origin/main"
grep -Fq "accepted immutable base: \`origin/main\` at \`$held_base_sha\`" "$origin_only_prompt" \
  || fail "brief should name the accepted immutable base ref and SHA"
grep -Fq "\`git cat-file -e $held_base_sha^{commit}\`" "$origin_only_prompt" \
  || fail "brief should require proving the accepted base commit exists"
grep -Fq "\`git merge-base --is-ancestor $held_base_sha origin/main\`" "$origin_only_prompt" \
  || fail "brief should allow descendant default refs as accepted pinned-base drift"
grep -Fq "accepted-pinned-base-drift" "$origin_only_prompt" \
  || fail "brief should distinguish accepted pinned-base drift from context-mismatch"
grep -Fq "\`git checkout -B feat/dispatch-test-ticket-5003 $held_base_sha\`" "$origin_only_prompt" \
  || fail "brief should branch from the accepted immutable base SHA, not the mutable default ref"

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

malformed_literal_prompt="$TEST_TMP/malformed-literals.md"
cp "$generated_prompt" "$malformed_literal_prompt"
cat >> "$malformed_literal_prompt" <<'EOF'

Malformed stripped-literal regression:
- Use , targeted shell tests, and existing prompt validation patterns.
- PR target: .
- No direct push to , no , no admin merge.
- PR body references .
EOF

: > "$TEST_TMP/logs/tmux.log"
rm -f "$TEST_TMP/logs/dispatch-test.log"
set +e
malformed_literal_output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$TEST_TMP/state-malformed-literal" \
  ORCH_CONTEXT_PROOF=0 \
  ORCH_DISPATCH_CONSUME_WAIT_SEC=0 \
  bash "$SANITIZED_ROOT/scripts/dispatch_ticket.sh" \
    "$TEST_TMP/test.config.sh" claude 5012 "$malformed_literal_prompt" 2>&1
)
malformed_literal_status=$?
set -e

[[ "$malformed_literal_status" -ne 0 ]] \
  || fail "stripped-literal prompt should be refused, got: $malformed_literal_output"
[[ "$malformed_literal_output" == *"stripped required literal"* ]] \
  || fail "expected stripped-literal prompt-integrity error, got: $malformed_literal_output"
if [[ -s "$TEST_TMP/logs/tmux.log" ]] \
  && grep -E 'load-buffer|paste-buffer|send-keys' "$TEST_TMP/logs/tmux.log" >/dev/null 2>&1; then
  fail "stripped-literal prompt must be refused before tmux send, tmux log: $(cat "$TEST_TMP/logs/tmux.log")"
fi
if [[ -f "$TEST_TMP/logs/dispatch-test.log" ]] \
  && grep -q 'DISPATCH PROMPT_EXECUTION_PROOF_OK agent=claude ticket=#5012' "$TEST_TMP/logs/dispatch-test.log"; then
  fail "stripped-literal prompt must be refused before prompt execution proof"
fi
[[ ! -e /tmp/dispatch-claude-5012.md ]] \
  || fail "stripped-literal prompt must be refused before staging the brief at /tmp"

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
# Issue #376: matrix dispatch routes to `rbok-claude`, so the brief
# must address rbok-claude (and pin the rbok-claude workdir) for the
# new routing-surface guard to allow the send. Re-rendering the brief
# under the matrix label is what `dispatch_plan.sh` already does in
# production; the previous fixture re-used the claude-addressed brief
# only because there was no orchestrator-side route check to catch it.
matrix_brief="$TEST_TMP/dispatch-rbok-claude-5003.md"
PATH="$TEST_TMP/bin:$PATH" \
ORCH_LOG_DIR="$TEST_TMP/logs" \
bash "$SANITIZED_ROOT/scripts/brief_agents.sh" "$TEST_TMP/test.config.sh" rbok-claude 5003 \
  --portfolio "$TEST_TMP/portfolio.config.sh" 2>/dev/null \
  summary="Matrix dispatch routing fixture" scope_files="lib/foo.sh" validation="bash tests.sh" > "$matrix_brief" \
  || PATH="$TEST_TMP/bin:$PATH" \
     ORCH_LOG_DIR="$TEST_TMP/logs" \
     bash "$SANITIZED_ROOT/scripts/brief_agents.sh" "$TEST_TMP/test.config.sh" rbok-claude 5003 \
       summary="Matrix dispatch routing fixture" scope_files="lib/foo.sh" validation="bash tests.sh" > "$matrix_brief"
set +e
matrix_output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  bash "$SANITIZED_ROOT/scripts/dispatch_ticket.sh" "$TEST_TMP/test.config.sh" rbok-claude 5003 "$matrix_brief" --portfolio "$TEST_TMP/portfolio.config.sh" --dry-run 2>&1
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
  bash "$SANITIZED_ROOT/scripts/dispatch_ticket.sh" "$TEST_TMP/test.config.sh" claude 5001 "$worktree_generated_prompt" 2>&1
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

# Issue #498: USE_WORKTREES=1 must route against the effective per-ticket
# worktree identity, not the shared root identity. The shared checkout below
# deliberately has a non-agent user.name; dispatch should still proceed because
# each target worktree receives an agent-specific --worktree identity before
# the route guard makes its identity decision.
shared_identity_root="$TEST_TMP/repos/shared-identity"
git clone "$TEST_TMP/origin.git" "$shared_identity_root" >/dev/null 2>&1
git -C "$shared_identity_root" checkout main >/dev/null
git -C "$shared_identity_root" config user.name "Shared Root"
git -C "$shared_identity_root" config user.email "shared-root@test.local"

cat > "$TEST_TMP/worktree-identity.config.sh" <<EOF
#!/usr/bin/env bash
PROJECT="dispatch-identity-test"
GH_REPO="RBOKproject/ORDO"
GH_CONFIG_DIR="$TEST_TMP/gh"
DEFAULT_BRANCH="main"
# REPO_URL pins the canonical clone URL the #683 workdir-origin preflight
# compares against; the shared_identity_root clone below has a local file
# path origin, so without REPO_URL the preflight would derive the
# canonical from GH_REPO and refuse on the trivial mismatch — shadowing
# the worktree-identity routing assertion this fixture exercises.
REPO_URL="$TEST_TMP/origin.git"
AGENT_SESSION_PREFIX=""
export AGENT_WORKDIR_TEMPLATE="$shared_identity_root"
AGENT_PANES=(
  "claude|claude:0.0|$shared_identity_root"
  "gemini|gemini:0.0|$shared_identity_root"
)
AGENT_GH_LOGINS=(
  "claude|claude"
  "gemini|gemini"
)
AGENT_GIT_IDENTITY_NAME_TEMPLATE="Dispatch %s"
AGENT_GIT_IDENTITY_EMAIL_TEMPLATE="%s@identity.test.local"
USE_WORKTREES="\${USE_WORKTREES:-1}"
ORCH_WORKTREES_DIR="\${ORCH_WORKTREES_DIR:-$TEST_TMP/identity-worktrees}"
# Legacy identity fixture; #573 acceptance gate is covered separately.
export REQUIRE_ACCEPTANCE_PROOF="\${REQUIRE_ACCEPTANCE_PROOF:-0}"
EOF

identity_claude_prompt="$TEST_TMP/dispatch-claude-5410.md"
PATH="$TEST_TMP/bin:$PATH" \
ORCH_LOG_DIR="$TEST_TMP/logs-identity" \
bash "$SANITIZED_ROOT/scripts/brief_agents.sh" \
  "$TEST_TMP/worktree-identity.config.sh" claude 5410 \
  summary="Worktree identity route guard fixture" scope_files="lib/foo.sh" validation="bash tests.sh" \
  > "$identity_claude_prompt"

set +e
identity_claude_output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  ORCH_LOG_DIR="$TEST_TMP/logs-identity" \
  ORCH_STATE_BASE="$TEST_TMP/state-identity-legacy" \
  USE_WORKTREES=1 \
  ORCH_WORKTREES_DIR="$TEST_TMP/identity-worktrees" \
  ORCH_CONTEXT_PROOF_WAIT_SEC=0 \
  bash "$SANITIZED_ROOT/scripts/dispatch_ticket.sh" \
    "$TEST_TMP/worktree-identity.config.sh" claude 5410 "$identity_claude_prompt" 2>&1
)
identity_claude_status=$?
set -e
[[ "$identity_claude_status" -eq 0 ]] \
  || fail "worktree identity dispatch should ignore shared root identity and succeed, got $identity_claude_status: $identity_claude_output"

identity_claude_wt="$TEST_TMP/identity-worktrees/claude/feat-issue-5410"
grep -Fq -- "- \`cd $identity_claude_wt\`" "$identity_claude_prompt" \
  || fail "new worktree brief should pin the ticket worktree cwd"
[[ "$(git -C "$identity_claude_wt" config user.name)" == "Dispatch claude" ]] \
  || fail "claude dispatch worktree should receive per-worktree user.name"
[[ "$(git -C "$identity_claude_wt" config user.email)" == "claude@identity.test.local" ]] \
  || fail "claude dispatch worktree should receive per-worktree user.email"
[[ "$(git -C "$shared_identity_root" config user.name)" == "Shared Root" ]] \
  || fail "shared root identity must not be overwritten by claude dispatch"
grep -q 'DISPATCH ROUTE_WORKTREE_IDENTITY_OK agent=claude ticket=#5410' "$TEST_TMP/logs-identity/dispatch-identity-test.log" \
  || fail "worktree identity dispatch should audit identity OK"
! grep -q 'DISPATCH ROUTE_WORKTREE_CWD_COMPAT agent=claude ticket=#5410' "$TEST_TMP/logs-identity/dispatch-identity-test.log" \
  || fail "new worktree brief should not need repo-root prompt compatibility"

identity_gemini_prompt="$TEST_TMP/dispatch-gemini-5411.md"
identity_gemini_legacy_dir="$TEST_TMP/legacy-root-pinned"
identity_gemini_legacy_prompt="$identity_gemini_legacy_dir/dispatch-gemini-5411.md"
identity_gemini_wt="$TEST_TMP/identity-worktrees/gemini/feat-issue-5411"
mkdir -p "$identity_gemini_legacy_dir"
PATH="$TEST_TMP/bin:$PATH" \
ORCH_LOG_DIR="$TEST_TMP/logs-identity" \
bash "$SANITIZED_ROOT/scripts/brief_agents.sh" \
  "$TEST_TMP/worktree-identity.config.sh" gemini 5411 \
  summary="Legacy root-pinned route guard fixture" scope_files="lib/foo.sh" validation="bash tests.sh" \
  > "$identity_gemini_prompt"
sed "s|$identity_gemini_wt|$shared_identity_root|g" \
  "$identity_gemini_prompt" > "$identity_gemini_legacy_prompt"

set +e
identity_gemini_output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  ORCH_LOG_DIR="$TEST_TMP/logs-identity" \
  ORCH_STATE_BASE="$TEST_TMP/state-identity" \
  USE_WORKTREES=1 \
  ORCH_WORKTREES_DIR="$TEST_TMP/identity-worktrees" \
  ORCH_CONTEXT_PROOF_WAIT_SEC=0 \
  bash "$SANITIZED_ROOT/scripts/dispatch_ticket.sh" \
    "$TEST_TMP/worktree-identity.config.sh" gemini 5411 "$identity_gemini_legacy_prompt" --dry-run 2>&1
)
identity_gemini_status=$?
set -e
[[ "$identity_gemini_status" -eq 81 ]] \
  || fail "legacy root-pinned worktree dispatch should be refused, got $identity_gemini_status: $identity_gemini_output"
[[ "$identity_gemini_output" == *"DISPATCH_ROUTE_MISMATCH"* ]] \
  || fail "legacy root-pinned prompt should report a route mismatch, got: $identity_gemini_output"
[[ "$identity_gemini_output" == *"mismatched_fields=pinned_cwd"* ]] \
  || fail "legacy root-pinned prompt should name pinned_cwd, got: $identity_gemini_output"

occupied_workdir="$TEST_TMP/agent-worktrees/rbok/claude/feat-issue-7000"
occupied_state="$TEST_TMP/state-occupied"
mkdir -p "$occupied_workdir" "$occupied_state/rbok"
cat > "$occupied_state/rbok/assignments.json" <<JSON
{
  "claude": {
    "ticket": "7000",
    "issue": 7000,
    "workdir": "$occupied_workdir",
    "branch": "feat/issue-7000"
  }
}
JSON
printf 'respawn-pane -k -t claude:0.0 -c %s exec claude\n' "$occupied_workdir" >> "$TEST_TMP/logs/tmux.log"

set +e
occupied_output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$occupied_state" \
  USE_WORKTREES=1 \
  ORCH_WORKTREES_DIR="$TEST_TMP/agent-worktrees" \
  ORCH_CONTEXT_PROOF_WAIT_SEC=0 \
  bash "$SANITIZED_ROOT/scripts/dispatch_ticket.sh" "$TEST_TMP/test.config.sh" claude 5001 "$worktree_generated_prompt" 2>&1
)
occupied_status=$?
set -e

[[ "$occupied_status" -eq 77 ]] \
  || fail "occupied pane dispatch should exit 77 before respawn, got $occupied_status: $occupied_output"
[[ "$occupied_output" == *"pane-occupied:rbok#7000"* ]] \
  || fail "occupied pane refusal should name the active assignment, got: $occupied_output"
grep -q 'DISPATCH REFUSED reason=pane_occupied' "$TEST_TMP/logs/dispatch-test.log" \
  || fail "occupied pane refusal should be audit logged"

# Issue #708: auto-clear of a stale "occupied" assignment whose
# feature branch has already been merged. After a successful PR
# merge the agent finishes, but `assignments.json` still carries
# the merged ticket. Without the auto-clear, the next dispatch on
# that pane refuses with `pane_occupied` and the autonomous
# orchestration loop silently caps throughput at the fleet size.
# The dispatcher must consult `gh pr list --state merged --head
# <branch>` for the occupied row's branch and, on a positive
# merged-PR result, rewrite the ledger row before resuming dispatch.
merged_clear_workdir="$TEST_TMP/agent-worktrees/dispatch-test/claude/feat-issue-7100"
merged_clear_state="$TEST_TMP/state-merged-clear"
mkdir -p "$merged_clear_workdir" "$merged_clear_state/dispatch-test"
cat > "$merged_clear_state/dispatch-test/assignments.json" <<JSON
{
  "claude": {
    "ticket": "7100",
    "issue": 7100,
    "workdir": "$merged_clear_workdir",
    "branch": "feat/issue-7100"
  }
}
JSON
printf 'respawn-pane -k -t claude:0.0 -c %s exec claude\n' "$merged_clear_workdir" >> "$TEST_TMP/logs/tmux.log"

merged_clear_prompt="$TEST_TMP/generated-merged-clear-5101.md"
PATH="$TEST_TMP/bin:$PATH" \
ORCH_LOG_DIR="$TEST_TMP/logs" \
USE_WORKTREES=1 \
ORCH_WORKTREES_DIR="$TEST_TMP/agent-worktrees" \
bash "$SANITIZED_ROOT/scripts/brief_agents.sh" "$TEST_TMP/test.config.sh" claude 5101 summary="Auto-clear merged occupied" scope_files="lib/foo.sh" validation="bash tests.sh" > "$merged_clear_prompt"

set +e
merged_clear_output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$merged_clear_state" \
  USE_WORKTREES=1 \
  ORCH_WORKTREES_DIR="$TEST_TMP/agent-worktrees" \
  ORCH_CONTEXT_PROOF_WAIT_SEC=0 \
  bash "$SANITIZED_ROOT/scripts/dispatch_ticket.sh" "$TEST_TMP/test.config.sh" claude 5101 "$merged_clear_prompt" 2>&1
)
merged_clear_status=$?
set -e

[[ "$merged_clear_status" -ne 77 ]] \
  || fail "merged-branch occupied refusal should be auto-cleared, got 77: $merged_clear_output"
grep -q 'DISPATCH AUTO_CLEAR_MERGED_OCCUPIED' "$TEST_TMP/logs/dispatch-test.log" \
  || fail "auto-clear path should be audit logged"
grep -q 'branch=feat/issue-7100' "$TEST_TMP/logs/dispatch-test.log" \
  || fail "auto-clear audit should record the merged feature branch"
grep -q 'mergedAt=2026-05-19T10:00:00Z' "$TEST_TMP/logs/dispatch-test.log" \
  || fail "auto-clear audit should record the merged-PR timestamp"
merged_clear_assignment_issue=$(jq -r '.claude.issue // .claude.ticket // ""' \
  "$merged_clear_state/dispatch-test/assignments.json" 2>/dev/null || printf '')
[[ "$merged_clear_assignment_issue" != "7100" ]] \
  || fail "stale merged ticket 7100 should be cleared from assignments.json (still present: $merged_clear_assignment_issue)"

# Opt-out: ORCH_DISPATCH_AUTO_CLEAR_MERGED_OCCUPIED=0 must restore
# the legacy pane_occupied refusal so operators can still drive the
# original error path on purpose (forensics, regression fixtures,
# audit-mode rehearsals).
cat > "$merged_clear_state/dispatch-test/assignments.json" <<JSON
{
  "claude": {
    "ticket": "7100",
    "issue": 7100,
    "workdir": "$merged_clear_workdir",
    "branch": "feat/issue-7100"
  }
}
JSON
printf 'respawn-pane -k -t claude:0.0 -c %s exec claude\n' "$merged_clear_workdir" >> "$TEST_TMP/logs/tmux.log"
set +e
merged_clear_optout_output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$merged_clear_state" \
  USE_WORKTREES=1 \
  ORCH_WORKTREES_DIR="$TEST_TMP/agent-worktrees" \
  ORCH_CONTEXT_PROOF_WAIT_SEC=0 \
  ORCH_DISPATCH_AUTO_CLEAR_MERGED_OCCUPIED=0 \
  bash "$SANITIZED_ROOT/scripts/dispatch_ticket.sh" "$TEST_TMP/test.config.sh" claude 5101 "$merged_clear_prompt" 2>&1
)
merged_clear_optout_status=$?
set -e
[[ "$merged_clear_optout_status" -eq 77 ]] \
  || fail "ORCH_DISPATCH_AUTO_CLEAR_MERGED_OCCUPIED=0 must restore pane_occupied refusal, got $merged_clear_optout_status: $merged_clear_optout_output"
[[ "$merged_clear_optout_output" == *"pane-occupied:dispatch-test#7100"* ]] \
  || fail "opt-out refusal should still name the active assignment, got: $merged_clear_optout_output"

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
export REQUIRE_ACCEPTANCE_PROOF="\${REQUIRE_ACCEPTANCE_PROOF:-0}"
EOF

# Issue #376: regenerate the brief against the missing-workdir config
# so the body's pinned cwd matches the dispatcher-resolved workdir
# (which still points at $no-such-repos/claude). The new routing guard
# would otherwise refuse with exit 81 *before* the post-dispatch live
# cwd check could fire — that earlier refusal is correct behavior, but
# the contract under test here is the live-cwd context proof itself.
missing_workdir_brief="$TEST_TMP/dispatch-claude-5004.md"
PATH="$TEST_TMP/bin:$PATH" \
ORCH_LOG_DIR="$TEST_TMP/logs" \
bash "$SANITIZED_ROOT/scripts/brief_agents.sh" \
  "$TEST_TMP/missing-workdir.config.sh" claude 5004 \
  summary="Missing workdir live-cwd proof" scope_files="lib/foo.sh" validation="bash tests.sh" \
  > "$missing_workdir_brief"

set +e
mismatch_output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  ORCH_CONTEXT_PROOF_WAIT_SEC=0 \
  bash "$SANITIZED_ROOT/scripts/dispatch_ticket.sh" "$TEST_TMP/missing-workdir.config.sh" claude 5004 "$missing_workdir_brief" 2>&1
)
mismatch_status=$?
set -e

[[ "$mismatch_status" -eq 76 ]] || fail "missing workdir should exit 76, got $mismatch_status: $mismatch_output"
[[ "$mismatch_output" == *"dispatch-context-mismatch"* ]] \
  || fail "expected dispatch-context-mismatch on stderr, got: $mismatch_output"
[[ "$mismatch_output" == *"reason=workdir-missing"* ]] \
  || fail "expected reason=workdir-missing on stderr, got: $mismatch_output"

# Issue #491: a dispatch whose live pane cwd does not match the target
# workdir must not overwrite a previous final assignment. The new ticket
# may be tracked in the pending ledger as failed, but assignments.json
# remains the last proven live context.
context_state_dir="$TEST_TMP/state-context-mismatch"
mkdir -p "$context_state_dir/dispatch-test"
old_assignment_workdir="$TEST_TMP/agent-worktrees/claude/feat-issue-4999"
mkdir -p "$old_assignment_workdir"
cat > "$context_state_dir/dispatch-test/assignments.json" <<JSON
{
  "claude": {
    "ticket": "4999",
    "issue": 4999,
    "branch": "feat/issue-4999",
    "workdir": "$old_assignment_workdir",
    "repo_root": "$TEST_TMP/repos/claude",
    "prompt_file": "/tmp/dispatch-claude-4999.md",
    "dispatched_at": "2026-05-09T00:00:00Z"
  }
}
JSON

set +e
live_cwd_mismatch_output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$context_state_dir" \
  ORCH_CONTEXT_PROOF_WAIT_SEC=0 \
  bash "$SANITIZED_ROOT/scripts/dispatch_ticket.sh" "$TEST_TMP/test.config.sh" claude 5011 "$generated_prompt" 2>&1
)
live_cwd_mismatch_status=$?
set -e

[[ "$live_cwd_mismatch_status" -eq 76 ]] \
  || fail "live cwd mismatch should exit 76, got $live_cwd_mismatch_status: $live_cwd_mismatch_output"
[[ "$live_cwd_mismatch_output" == *"dispatch-context-mismatch"* ]] \
  || fail "expected dispatch-context-mismatch on live cwd mismatch, got: $live_cwd_mismatch_output"
[[ "$live_cwd_mismatch_output" == *"reason=live-cwd-mismatch"* ]] \
  || fail "expected live-cwd-mismatch reason, got: $live_cwd_mismatch_output"
jq -e --arg dir "$old_assignment_workdir" '
  .claude.issue == 4999 and
  .claude.workdir == $dir
' "$context_state_dir/dispatch-test/assignments.json" >/dev/null \
  || fail "failed live-context proof must leave the prior final assignment intact"
jq -e '
  .claude.issue == 5011 and
  .claude.status == "failed" and
  .claude.reason == "live-cwd-mismatch"
' "$context_state_dir/dispatch-test/assignments_pending.json" >/dev/null \
  || fail "failed live-context proof should be recorded only in assignments_pending.json"

# Opt-out: ORCH_CONTEXT_PROOF=0 must skip the proof entirely so a
# degraded agent host can still dispatch when the operator accepts the
# audit-only signal.
mkdir -p "$TEST_TMP/no-such-repos/claude"
git -C "$TEST_TMP/no-such-repos/claude" init -q
git -C "$TEST_TMP/no-such-repos/claude" config user.email "ctx@test.local"
git -C "$TEST_TMP/no-such-repos/claude" config user.name  "Ctx Test"
# Issue #376: brief must address the missing-workdir's claude clone for
# the routing-surface guard to allow the send. Without this, the guard
# refuses on `pinned_cwd` mismatch before ORCH_CONTEXT_PROOF=0 can take
# effect (the route guard does not consult the context-proof toggle).
optout_brief="$TEST_TMP/dispatch-claude-5005.md"
PATH="$TEST_TMP/bin:$PATH" \
ORCH_LOG_DIR="$TEST_TMP/logs" \
bash "$SANITIZED_ROOT/scripts/brief_agents.sh" \
  "$TEST_TMP/missing-workdir.config.sh" claude 5005 \
  summary="Context-proof opt-out smoke" scope_files="lib/foo.sh" validation="bash tests.sh" \
  > "$optout_brief"
set +e
optout_output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  ORCH_CONTEXT_PROOF=0 \
  bash "$SANITIZED_ROOT/scripts/dispatch_ticket.sh" "$TEST_TMP/missing-workdir.config.sh" claude 5005 "$optout_brief" 2>&1
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
# Issue #362: a destructive readiness refusal must capture a fresh
# RECOVERY_CONTEXT_PROOF and embed its path in the audit + stderr so any
# downstream destructive recovery can re-validate freshness before
# mutation. The proof file itself must exist on disk.
grep -q 'RECOVERY_CONTEXT_PROOF captured' "$TEST_TMP/logs"/*.log \
  || fail "expected RECOVERY_CONTEXT_PROOF capture audit on destructive refusal"
grep -qE 'recovery_context_proof=[^ ]+/recovery/[^ ]+\.json' "$TEST_TMP/logs"/*.log \
  || fail "expected DISPATCH REFUSED audit to embed the recovery proof path"
[[ "$dirty_output" == *"recovery_context_proof:"* ]] \
  || fail "expected stderr to surface the proof path on destructive refusal, got: $dirty_output"
recovery_proof_path=$(grep -hoE '/[^ ]+/recovery/[^ ]+\.json' "$TEST_TMP/logs"/*.log | head -1)
[[ -s "$recovery_proof_path" ]] \
  || fail "expected proof file to exist at $recovery_proof_path"
jq -e '.destructive == true' "$recovery_proof_path" >/dev/null \
  || fail "proof file must record destructive=true on dirty workdir refusal"
jq -e '.local_state.porcelain_count >= 1' "$recovery_proof_path" >/dev/null \
  || fail "proof file must record the porcelain count proven on capture"

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

# Issue #376: same-PR brief must address rbok-same-pr (and pin its
# clone) so the routing-surface guard accepts the send. The preceding
# fixture intentionally generated the brief for `claude` against a
# different config; without re-rendering, the new guard would refuse
# before the matrix same-PR escape hatch can take effect.
same_pr_brief="$TEST_TMP/dispatch-rbok-same-pr-5006.md"
PATH="$TEST_TMP/bin:$PATH" \
ORCH_LOG_DIR="$TEST_TMP/logs" \
AGENT_PANES=("rbok-same-pr|rbok-same-pr:0.0|$same_pr_workdir") \
bash "$SANITIZED_ROOT/scripts/brief_agents.sh" \
  "$TEST_TMP/test.config.sh" rbok-same-pr 5006 \
  summary="Same-PR rebase dispatch fixture" scope_files="lib/foo.sh" validation="bash tests.sh" \
  > "$same_pr_brief" 2>/dev/null \
|| {
  PATH="$TEST_TMP/bin:$PATH" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  bash "$SANITIZED_ROOT/scripts/brief_agents.sh" \
    "$TEST_TMP/test.config.sh" rbok-same-pr 5006 \
    summary="Same-PR rebase dispatch fixture" scope_files="lib/foo.sh" validation="bash tests.sh" \
    repo="$same_pr_workdir" \
    > "$same_pr_brief"
}

set +e
same_pr_output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  bash "$SANITIZED_ROOT/scripts/dispatch_ticket.sh" "$TEST_TMP/test.config.sh" rbok-same-pr 5006 "$same_pr_brief" --portfolio "$TEST_TMP/portfolio-same-pr.config.sh" --dry-run 2>&1
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
  auth-status)
    # #816: the identity guard reads the active login via the provider
    # adapter (gh auth status on the github backend).
    printf 'github.com\n  Logged in to github.com account %s (keyring)\n' "\${POLICY_GH_ACTIVE_LOGIN:-}"
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
# REPO_URL pins the canonical clone URL the #683 workdir-origin preflight
# compares against; without it the canonical falls back to GH_REPO and the
# fixture's local-path origin would refuse on a trivial mismatch.
REPO_URL="$TEST_TMP/origin.git"
AGENT_SESSION_PREFIX=""
AGENT_REPO_PREFIX="$TEST_TMP/repos/"
SUPERVISOR_REPO=""
export AGENT_WORKDIR_TEMPLATE="$TEST_TMP/repos/%s"
USE_WORKTREES=0
export REQUIRE_ACCEPTANCE_PROOF="\${REQUIRE_ACCEPTANCE_PROOF:-0}"
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

# ---------------------------------------------------------------------------
# Issue #376 — orchestrator-side dispatch routing-surface guard.
#
# A brief whose body addresses a different agent than the dispatched
# pane MUST be refused before the staging copy is written and before
# tmux send-keys runs. The fixture mirrors the live Wave-23 leak that
# motivated the issue: filename `dispatch-claude-5404.md` (claude
# pane), body `# Dispatch — ordo agent: cross-agent` (different agent),
# pinned cwd points at the cross-agent workdir.
# ---------------------------------------------------------------------------

router_state_dir="$TEST_TMP/state-router"
router_log_dir="$TEST_TMP/logs-router"
mkdir -p "$router_log_dir" "$TEST_TMP/repos/cross-agent"
git -C "$TEST_TMP/repos/cross-agent" init -q
git -C "$TEST_TMP/repos/cross-agent" config user.email "cross@test.local"
git -C "$TEST_TMP/repos/cross-agent" config user.name "Cross Agent"

cat > "$TEST_TMP/router-mismatch.config.sh" <<EOF
#!/usr/bin/env bash
PROJECT="dispatch-test"
GH_REPO="RBOKproject/ORDO"
GH_CONFIG_DIR="$TEST_TMP/gh"
DEFAULT_BRANCH="main"
# REPO_URL pins the canonical clone URL the #683 workdir-origin preflight
# compares against; without it the canonical falls back to GH_REPO and the
# fixture's local-path origin would refuse on a trivial mismatch — shadowing
# the dispatch_router contract this fixture is exercising.
REPO_URL="$TEST_TMP/origin.git"
AGENT_SESSION_PREFIX=""
AGENT_REPO_PREFIX="$TEST_TMP/repos/"
SUPERVISOR_REPO=""
export AGENT_WORKDIR_TEMPLATE="$TEST_TMP/repos/%s"
USE_WORKTREES=0
export REQUIRE_ACCEPTANCE_PROOF="\${REQUIRE_ACCEPTANCE_PROOF:-0}"
EOF

router_mismatch_prompt="$TEST_TMP/dispatch-claude-5404.md"
sed -e "s|agent: claude|agent: cross-agent|" \
    -e "s|cd $TEST_TMP/repos/claude|cd $TEST_TMP/repos/cross-agent|g" \
    "$generated_prompt" > "$router_mismatch_prompt"

# Sanity check: the synthesized brief actually claims the wrong agent
# and pinned cwd. A future template tweak that drops the `agent:` token
# would otherwise silently skip the body-agent assertion below.
grep -q 'agent: cross-agent' "$router_mismatch_prompt" \
  || fail "router fixture should rewrite body agent to cross-agent"
grep -q "cd $TEST_TMP/repos/cross-agent" "$router_mismatch_prompt" \
  || fail "router fixture should rewrite pinned cwd to cross-agent"

set +e
router_output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  ORCH_LOG_DIR="$router_log_dir" \
  ORCH_STATE_BASE="$router_state_dir" \
  ORCH_CONTEXT_PROOF=0 \
  ORCH_CONTEXT_PROOF_WAIT_SEC=0 \
  bash "$SANITIZED_ROOT/scripts/dispatch_ticket.sh" \
    "$TEST_TMP/router-mismatch.config.sh" claude 5404 "$router_mismatch_prompt" --dry-run 2>&1
)
router_status=$?
set -e

[[ "$router_status" -eq 81 ]] \
  || fail "router-mismatch dispatch should exit 81 (route_mismatch_refused), got $router_status: $router_output"
[[ "$router_output" == *"DISPATCH_ROUTE_MISMATCH"* ]] \
  || fail "router-mismatch should print DISPATCH_ROUTE_MISMATCH on stderr, got: $router_output"
[[ "$router_output" == *"body_agent=cross-agent"* ]] \
  || fail "router-mismatch should surface body_agent=cross-agent in details, got: $router_output"
[[ "$router_output" == *"pinned_cwd=$TEST_TMP/repos/cross-agent"* ]] \
  || fail "router-mismatch should surface pinned_cwd in details, got: $router_output"

router_log="$router_log_dir/dispatch-test.log"
grep -q 'DISPATCH ROUTE_MISMATCH agent=claude ticket=#5404' "$router_log" \
  || fail "router-mismatch should be audit-logged, log: $(cat "$router_log" 2>/dev/null)"
grep -q 'reason=route_mismatch_refused' "$router_log" \
  || fail "router-mismatch audit must record reason=route_mismatch_refused"

# The refusal must happen BEFORE the staged copy under /tmp, so a stale
# cross-agent brief does not survive on disk for a future dispatch to
# pick up by mistake. (The /tmp filename lives outside the worktree so
# the evidence-path guard at line 720 of dispatch_ticket.sh would have
# accepted it; the route guard's job is to refuse earlier.)
[[ ! -e /tmp/dispatch-claude-5404.md ]] \
  || fail "router-mismatch must refuse before staging the brief at /tmp"

# And it must happen BEFORE tmux send-keys, so no buffer-paste reaches
# the pane. The shared tmux mock logs every invocation — the only
# acceptable entries for this fixture are the up-front probes
# (`list-panes`/`has-session`). A `load-buffer` or `send-keys` line
# would prove the guard fired too late.
if [[ -s "$TEST_TMP/logs/tmux.log" ]]; then
  if grep -E 'load-buffer|paste-buffer|send-keys' "$TEST_TMP/logs/tmux.log" \
       | grep -F '5404' >/dev/null 2>&1; then
    fail "router-mismatch must refuse before tmux send-keys, tmux log: $(cat "$TEST_TMP/logs/tmux.log")"
  fi
fi

# AC#376-3: a clean dispatch under the same fixture proceeds — proves
# the guard does not over-refuse when surfaces actually agree. We use
# the original generated_prompt which addresses claude and pins the
# claude workdir.
clean_router_prompt="$TEST_TMP/dispatch-claude-5405.md"
cp "$generated_prompt" "$clean_router_prompt"
set +e
clean_router_output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  ORCH_LOG_DIR="$router_log_dir" \
  ORCH_STATE_BASE="$router_state_dir" \
  ORCH_CONTEXT_PROOF=0 \
  ORCH_CONTEXT_PROOF_WAIT_SEC=0 \
  bash "$SANITIZED_ROOT/scripts/dispatch_ticket.sh" \
    "$TEST_TMP/router-mismatch.config.sh" claude 5405 "$clean_router_prompt" --dry-run 2>&1
)
clean_router_status=$?
set -e
[[ "$clean_router_status" -eq 0 ]] \
  || fail "matched-routing dispatch should succeed, got $clean_router_status: $clean_router_output"
grep -q 'DISPATCH ROUTE_OK agent=claude ticket=#5405' "$router_log" \
  || fail "matched-routing dispatch should audit ROUTE_OK"

rm -f /tmp/dispatch-claude-5404.md /tmp/dispatch-claude-5405.md "$router_mismatch_prompt" "$clean_router_prompt"

# ---------------------------------------------------------------------------
# Issue #476 — post-submission pane liveness probe.
#
# agent_pane_ready validates the pane is in $WORKDIR with the CLI alive
# BEFORE the brief is pasted, but Codex can still exit status 0 right
# after the prompt is delivered (state-db lock or post-init crash leaves
# the pane dead with no agent running). A dead pane post-submit must
# be refused with exit 79 and reason pane-dead-after-submit instead of
# being recorded as a successful "submitted" assignment. The probe is
# opt-outable via ORCH_POST_SUBMIT_PANE_LIVENESS=0 for legacy fixtures
# or degraded tmux hosts.
# ---------------------------------------------------------------------------

mkdir -p "$TEST_TMP/bin-dead-pane" "$TEST_TMP/logs-dead-pane"
cat > "$TEST_TMP/bin-dead-pane/tmux" <<EOF
#!/bin/sh
set -eu
printf '%s\n' "\$*" >> "$TEST_TMP/logs-dead-pane/tmux.log"
case "\${1:-}" in
  has-session)
    exit 0
    ;;
  list-panes)
    # Issue #476: when the dispatcher probes pane liveness post-submit
    # with -F '#{pane_dead}\t...', report a dead pane. orch_tmux_probe
    # uses -F '#{session_name}:#{window_index}.#{pane_index}' which has
    # no pane_dead token and must stay quiet so the probe succeeds.
    fmt_has_pane_dead=0
    for arg in "\$@"; do
      case "\$arg" in
        *pane_dead*) fmt_has_pane_dead=1 ;;
      esac
    done
    if [ "\$fmt_has_pane_dead" = "1" ]; then
      printf '1\t0\t12345\n'
    fi
    exit 0
    ;;
  capture-pane)
    printf '%s\n' "working on dispatch"
    exit 0
    ;;
  display-message)
    fmt=""
    batched=0
    for arg in "\$@"; do
      case "\$arg" in
        *'#{pane_current_command}'*'#{pane_current_path}'*) batched=1 ;;
        '#{pane_current_path}'|'#{pane_current_command}') fmt=\$arg ;;
      esac
    done
    last_workdir=\$(awk '/^respawn-pane / { for (i=1;i<=NF;i++) if (\$i=="-c") last=\$(i+1) } END { print last }' "$TEST_TMP/logs-dead-pane/tmux.log" 2>/dev/null || true)
    if [ "\$batched" = "1" ]; then
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
chmod +x "$TEST_TMP/bin-dead-pane/tmux"

dead_pane_state_dir="$TEST_TMP/state-dead-pane"
dead_pane_log_dir="$TEST_TMP/logs-dead-pane"

set +e
dead_pane_output=$(
  PATH="$TEST_TMP/bin-dead-pane:$TEST_TMP/bin:$PATH" \
  ORCH_LOG_DIR="$dead_pane_log_dir" \
  ORCH_STATE_BASE="$dead_pane_state_dir" \
  ORCH_CONTEXT_PROOF=0 \
  ORCH_CONTEXT_PROOF_WAIT_SEC=0 \
  bash "$SANITIZED_ROOT/scripts/dispatch_ticket.sh" \
    "$TEST_TMP/test.config.sh" claude 5476 "$generated_prompt" 2>&1
)
dead_pane_status=$?
set -e

[[ "$dead_pane_status" -eq 79 ]] \
  || fail "post-submit dead pane should exit 79 (dispatch-not-consumed), got $dead_pane_status: $dead_pane_output"
[[ "$dead_pane_output" == *"pane-dead-after-submit"* ]] \
  || fail "dead pane refusal should surface pane-dead-after-submit on stderr, got: $dead_pane_output"
[[ "$dead_pane_output" == *"pane_dead=1"* ]] \
  || fail "dead pane refusal should include pane_dead=1 detail, got: $dead_pane_output"
grep -Eq 'DISPATCH PANE_DEAD_POST_SUBMIT agent=claude ticket=#5476 pane=claude:0(\.0)? reason=pane-dead-after-submit' "$dead_pane_log_dir/dispatch-test.log" \
  || fail "dead pane refusal should be audit-logged with reason=pane-dead-after-submit, log: $(cat "$dead_pane_log_dir/dispatch-test.log" 2>/dev/null)"

# The assignment must NOT be promoted to "submitted" — the dispatch
# was refused. A "failed" entry (or none yet) is acceptable.
dead_pane_ledger="$dead_pane_state_dir/dispatch-test/assignments.json"
if [[ -s "$dead_pane_ledger" ]]; then
  if jq -e '.claude.status == "submitted"' "$dead_pane_ledger" >/dev/null 2>&1; then
    fail "dead pane dispatch must not promote assignment to submitted: $(cat "$dead_pane_ledger")"
  fi
fi

# A dispatch-not-consumed blocker must be recorded with the new reason
# so the orchestrator's blocker triage routes the agent for recovery.
dead_pane_blockers="$dead_pane_state_dir/dispatch-test/dispatch_blockers.json"
[[ -s "$dead_pane_blockers" ]] \
  || fail "dead pane refusal should write a dispatch_blockers.json entry"
jq -e '
  .open
  | to_entries
  | map(select(.value.reason == "pane-dead-after-submit"
        and .value.code == "dispatch-not-consumed"
        and .value.ticket == "5476"))
  | length > 0
' "$dead_pane_blockers" >/dev/null \
  || fail "dead pane refusal should record an open dispatch-not-consumed blocker with reason=pane-dead-after-submit: $(cat "$dead_pane_blockers")"

rm -f /tmp/dispatch-claude-5476.md

# Opt-out path: ORCH_POST_SUBMIT_PANE_LIVENESS=0 disables the probe so
# legacy callers / degraded tmux hosts still complete normally even
# when the mock would otherwise report pane_dead=1.
set +e
dead_pane_optout_output=$(
  PATH="$TEST_TMP/bin-dead-pane:$TEST_TMP/bin:$PATH" \
  ORCH_LOG_DIR="$dead_pane_log_dir" \
  ORCH_STATE_BASE="$TEST_TMP/state-dead-pane-optout" \
  ORCH_CONTEXT_PROOF=0 \
  ORCH_CONTEXT_PROOF_WAIT_SEC=0 \
  ORCH_POST_SUBMIT_PANE_LIVENESS=0 \
  bash "$SANITIZED_ROOT/scripts/dispatch_ticket.sh" \
    "$TEST_TMP/test.config.sh" claude 5477 "$generated_prompt" 2>&1
)
dead_pane_optout_status=$?
set -e

[[ "$dead_pane_optout_status" -eq 0 ]] \
  || fail "post-submit pane liveness opt-out should still succeed, got $dead_pane_optout_status: $dead_pane_optout_output"
! grep -q 'DISPATCH PANE_DEAD_POST_SUBMIT agent=claude ticket=#5477' "$dead_pane_log_dir/dispatch-test.log" \
  || fail "opt-out path must not emit PANE_DEAD_POST_SUBMIT audit for ticket #5477"

rm -f /tmp/dispatch-claude-5477.md

printf 'ok - dispatch prompt canonical validation and bypass\n'
