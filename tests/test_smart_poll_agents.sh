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

mkdir -p "$SANITIZED_ROOT/scripts" "$SANITIZED_ROOT/lib" "$SANITIZED_ROOT/config" "$TEST_TMP/bin" "$TEST_TMP/logs"

for rel in \
  scripts/smart_poll_agents.sh \
  lib/agent_inventory.sh \
  lib/audit_log.sh \
  lib/log_bounds.sh \
  lib/config_check.sh \
  lib/config_resolver.sh \
  lib/process_safety.sh \
  lib/quota_detect.sh \
  lib/state_persist.sh \
  lib/external_mutation_gate.sh \
  lib/ordo_contracts.sh \
  lib/ordo_provider_adapter.sh \
  lib/ordo_provider_adapter_github.sh \
  lib/ordo_provider_adapter_fake.sh
do
  tr -d '\r' < "$ROOT/$rel" > "$SANITIZED_ROOT/$rel"
done

tr -d '\r' < "$ROOT/config/quota_patterns.txt" > "$SANITIZED_ROOT/config/quota_patterns.txt"
chmod +x "$SANITIZED_ROOT/scripts/smart_poll_agents.sh"

cat > "$TEST_TMP/test.config.sh" <<EOF
#!/usr/bin/env bash
PROJECT="quota-smart-poll-test"
GH_REPO="RBOKproject/ORDO"
GH_CONFIG_DIR="$TEST_TMP/gh"
DEFAULT_BRANCH="develop"
AGENT_SESSION_PREFIX=""
AGENT_REPO_PREFIX="$TEST_TMP/repos/"
AGENT_WORKDIR_TEMPLATE="$TEST_TMP/repos/%s"
AGENTS=(claude)
SMART_POLL_TRIGGER_IDLE=99
SMART_POLL_TRIGGER_COMMITTED=99
SMART_POLL_TIMEOUT_SEC=0
SMART_POLL_INTERVAL_SEC=0
SMART_POLL_DEBOUNCE_SEC=0
EOF

mkdir -p "$TEST_TMP/repos/claude/.git"

cat > "$SANITIZED_ROOT/scripts/cli_swap.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "\$*" >> "$TEST_TMP/logs/cli_swap.log"
exit 0
EOF
chmod +x "$SANITIZED_ROOT/scripts/cli_swap.sh"

cat > "$TEST_TMP/bin/tmux" <<EOF
#!/usr/bin/env bash
set -euo pipefail
case "\${1:-}" in
  has-session)
    exit 0
    ;;
  capture-pane)
    printf '%s\n' 'rate limit exceeded'
    ;;
esac
exit 0
EOF
chmod +x "$TEST_TMP/bin/tmux"

cat > "$TEST_TMP/bin/git" <<EOF
#!/usr/bin/env bash
set -euo pipefail
case "\$*" in
  *"rev-parse --short develop"*)
    printf '%s\n' 'abc123'
    ;;
  *"branch --show-current"*)
    printf '%s\n' 'feature/quota'
    ;;
  *"rev-list --count develop..feature/quota"*)
    printf '%s\n' '1'
    ;;
  *"status --porcelain"*)
    exit 0
    ;;
esac
exit 0
EOF
chmod +x "$TEST_TMP/bin/git"

cat > "$TEST_TMP/bin/gh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
if [ "\${1:-}" = "pr" ] && [ "\${2:-}" = "list" ]; then
  printf '%s\n' '[{"headRefName":"feature/quota"}]'
fi
EOF
chmod +x "$TEST_TMP/bin/gh"

set +e
output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  TK="$SANITIZED_ROOT" \
  bash "$SANITIZED_ROOT/scripts/smart_poll_agents.sh" "$TEST_TMP/test.config.sh" 2>&1
)
status=$?
set -e

[[ "$status" -eq 1 ]] || fail "expected smart poll timeout after one pass, got $status: $output"
grep -q "$TEST_TMP/test.config.sh claude auto" "$TEST_TMP/logs/cli_swap.log" || fail "expected smart_poll to trigger cli_swap auto on quota match"

rm -f "$TEST_TMP/logs/cli_swap.log"
mkdir -p "$TEST_TMP/state/quota-smart-poll-test"
date +%s > "$TEST_TMP/state/quota-smart-poll-test/quota-swap-claude.ts"

set +e
output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  TK="$SANITIZED_ROOT" \
  bash "$SANITIZED_ROOT/scripts/smart_poll_agents.sh" "$TEST_TMP/test.config.sh" 2>&1
)
status=$?
set -e

[[ "$status" -eq 1 ]] || fail "expected smart poll timeout with cooldown too, got $status: $output"
[[ ! -f "$TEST_TMP/logs/cli_swap.log" ]] || fail "expected cooldown to suppress repeated cli_swap"

cat > "$TEST_TMP/submitted.config.sh" <<EOF
#!/usr/bin/env bash
PROJECT="submitted-smart-poll-test"
GH_REPO="RBOKproject/ORDO"
GH_CONFIG_DIR="$TEST_TMP/gh"
DEFAULT_BRANCH="develop"
AGENT_SESSION_PREFIX=""
AGENT_REPO_PREFIX="$TEST_TMP/repos/"
AGENT_WORKDIR_TEMPLATE="$TEST_TMP/repos/%s"
AGENTS=(claude)
SMART_POLL_IDLE_MODE=git
SMART_POLL_TRIGGER_IDLE=1
SMART_POLL_TRIGGER_COMMITTED=1
SMART_POLL_TIMEOUT_SEC=0
SMART_POLL_INTERVAL_SEC=0
SMART_POLL_DEBOUNCE_SEC=0
SMART_POLL_IGNORE_OPEN_PR_BRANCHES=1
SMART_POLL_VERBOSE=1
SMART_POLL_AUTOSWAP=0
EOF

set +e
output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  TK="$SANITIZED_ROOT" \
  bash "$SANITIZED_ROOT/scripts/smart_poll_agents.sh" "$TEST_TMP/submitted.config.sh" 2>&1
)
status=$?
set -e

[[ "$status" -eq 1 ]] || fail "expected submitted branch to timeout instead of trigger, got $status: $output"
[[ "$output" == *"committed=0 submitted=1"* ]] || fail "expected submitted branch to be excluded from committed trigger: $output"
[[ "$output" == *"claude:0.0=ibp"* ]] || fail "expected submitted state marker in poll log: $output"

mkdir -p "$TEST_TMP/state/quota-smart-poll-test/poll-registry"
cat > "$TEST_TMP/fake_smart_poll_agents.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
child=
term() {
  if [ -n "${child:-}" ]; then
    kill "$child" 2>/dev/null || true
  fi
  exit 0
}
trap term TERM
sleep 60 &
child=$!
wait "$child"
EOF
chmod +x "$TEST_TMP/fake_smart_poll_agents.sh"
"$TEST_TMP/fake_smart_poll_agents.sh" &
old_poll_pid=$!

cat > "$TEST_TMP/state/quota-smart-poll-test/poll-registry/old.env" <<EOF
pid=$old_poll_pid
project=quota-smart-poll-test
wave_id=old-wave
start_ts=$(date +%s)
timeout_sec=900
observe=1
policy=replace
EOF

set +e
output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  TK="$SANITIZED_ROOT" \
  bash "$SANITIZED_ROOT/scripts/smart_poll_agents.sh" "$TEST_TMP/test.config.sh" 2>&1
)
status=$?
set -e

[[ "$status" -eq 1 ]] || fail "expected smart poll timeout after replacing prior poll, got $status: $output"
[[ "$output" == *"POLL stale-poll action=term"* ]] || fail "expected prior poll to receive clean shutdown: $output"
sleep 0.1
if kill -0 "$old_poll_pid" 2>/dev/null; then
  kill "$old_poll_pid" 2>/dev/null || true
  fail "expected prior poll pid $old_poll_pid to be stopped"
fi
[[ ! -f "$TEST_TMP/state/quota-smart-poll-test/poll-registry/old.env" ]] || fail "expected old registry entry to be removed"

dead_pid=999999
while kill -0 "$dead_pid" 2>/dev/null; do
  dead_pid=$((dead_pid - 1))
done
cat > "$TEST_TMP/state/quota-smart-poll-test/poll-registry/stale.env" <<EOF
pid=$dead_pid
project=quota-smart-poll-test
wave_id=stale-wave
start_ts=$(( $(date +%s) - 2000 ))
timeout_sec=900
observe=1
policy=replace
EOF

set +e
output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  TK="$SANITIZED_ROOT" \
  bash "$SANITIZED_ROOT/scripts/smart_poll_agents.sh" "$TEST_TMP/test.config.sh" 2>&1
)
status=$?
set -e

[[ "$status" -eq 1 ]] || fail "expected smart poll timeout after stale cleanup, got $status: $output"
[[ "$output" == *"POLL stale-poll action=remove-dead"* ]] || fail "expected stale dead poll cleanup audit: $output"
[[ ! -f "$TEST_TMP/state/quota-smart-poll-test/poll-registry/stale.env" ]] || fail "expected stale registry entry to be removed"

cat > "$TEST_TMP/final-local.config.sh" <<EOF
#!/usr/bin/env bash
PROJECT="final-report-local-test"
GH_REPO="RBOKproject/ORDO"
GH_CONFIG_DIR="$TEST_TMP/gh"
DEFAULT_BRANCH="develop"
AGENT_SESSION_PREFIX=""
AGENT_REPO_PREFIX="$TEST_TMP/repos/"
AGENT_WORKDIR_TEMPLATE="$TEST_TMP/repos/%s"
AGENTS=(claude)
SMART_POLL_TRIGGER_IDLE=99
SMART_POLL_TRIGGER_COMMITTED=99
SMART_POLL_TIMEOUT_SEC=0
SMART_POLL_INTERVAL_SEC=0
SMART_POLL_DEBOUNCE_SEC=0
SMART_POLL_AUTOSWAP=0
SMART_POLL_VERBOSE=1
EOF

cat > "$TEST_TMP/bin/tmux" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  has-session)
    exit 0
    ;;
  capture-pane)
    cat <<'PANE'
Work complete.
3199 status: pr
branch: feat/issue-3199
files changed: frontend/app/routes.ts, tests/routes.test.ts
validation: npm test passed
PANE
    ;;
esac
exit 0
EOF
chmod +x "$TEST_TMP/bin/tmux"

local_head_full="1111111111111111111111111111111111111111"
cat > "$TEST_TMP/bin/git" <<EOF
#!/usr/bin/env bash
set -euo pipefail
case "\$*" in
  *"rev-parse --short develop"*)
    printf '%s\n' 'base123'
    ;;
  *"branch --show-current"*)
    printf '%s\n' 'feat/issue-3199'
    ;;
  *"rev-list --count develop..feat/issue-3199"*)
    printf '%s\n' '1'
    ;;
  *"status --porcelain"*)
    exit 0
    ;;
  *"rev-parse HEAD"*)
    printf '%s\n' "$local_head_full"
    ;;
  *"rev-parse --short HEAD"*)
    printf '%s\n' '1111111'
    ;;
  *"rev-parse --verify refs/remotes/origin/feat/issue-3199"*)
    exit 1
    ;;
  *"diff --name-only develop..HEAD"*)
    printf '%s\n' 'frontend/app/routes.ts' 'tests/routes.test.ts'
    ;;
esac
exit 0
EOF
chmod +x "$TEST_TMP/bin/git"

cat > "$TEST_TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = "pr" ] && [ "${2:-}" = "list" ]; then
  printf '%s\n' '[]'
fi
EOF
chmod +x "$TEST_TMP/bin/gh"

set +e
output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  TK="$SANITIZED_ROOT" \
  bash "$SANITIZED_ROOT/scripts/smart_poll_agents.sh" "$TEST_TMP/final-local.config.sh" 2>&1
)
status=$?
set -e

[[ "$status" -eq 1 ]] || fail "expected local final-report poll timeout after one pass, got $status: $output"
[[ "$output" == *"FINAL_REPORT_HANDOFF_REQUIRED agent=claude issue=3199 handoff_state=local_commit_no_push branch=feat/issue-3199 head=1111111"* ]] \
  || fail "expected local commit/no-push final report handoff event: $output"
[[ "$output" == *"files=frontend/app/routes.ts,tests/routes.test.ts"* ]] \
  || fail "expected handoff event to include changed files: $output"
[[ "$output" == *"validation=npm_test_passed"* ]] \
  || fail "expected handoff event to include normalized validation: $output"
grep -q '"issue":3199' "$TEST_TMP/state/final-report-local-test/final-report-handoffs.jsonl" \
  || fail "expected local final report handoff JSONL evidence"
grep -q 'action=queue_push_pr' "$TEST_TMP/state/final-report-local-test/ORCH_TASKS.md" \
  || fail "expected local final report to queue push/PR operator task"
[[ -f "$TEST_TMP/state/final-report-local-test/orch.run_now" ]] \
  || fail "expected local final report to request next loop tick"

cat > "$TEST_TMP/final-pushed.config.sh" <<EOF
#!/usr/bin/env bash
PROJECT="final-report-pushed-test"
GH_REPO="RBOKproject/ORDO"
GH_CONFIG_DIR="$TEST_TMP/gh"
DEFAULT_BRANCH="develop"
AGENT_SESSION_PREFIX=""
AGENT_REPO_PREFIX="$TEST_TMP/repos/"
AGENT_WORKDIR_TEMPLATE="$TEST_TMP/repos/%s"
AGENTS=(claude)
SMART_POLL_TRIGGER_IDLE=99
SMART_POLL_TRIGGER_COMMITTED=99
SMART_POLL_TIMEOUT_SEC=0
SMART_POLL_INTERVAL_SEC=0
SMART_POLL_DEBOUNCE_SEC=0
SMART_POLL_AUTOSWAP=0
SMART_POLL_VERBOSE=1
EOF

cat > "$TEST_TMP/bin/tmux" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  has-session)
    exit 0
    ;;
  capture-pane)
    cat <<'PANE'
Validation complete.
#3435 status: pr
branch: fix/issue-3435-critical-route-smoke
files changed: backend/tests/test_critical_routes.py
validation: pytest backend/tests/test_critical_routes.py passed
PANE
    ;;
esac
exit 0
EOF
chmod +x "$TEST_TMP/bin/tmux"

pushed_head_full="2222222222222222222222222222222222222222"
cat > "$TEST_TMP/bin/git" <<EOF
#!/usr/bin/env bash
set -euo pipefail
case "\$*" in
  *"rev-parse --short develop"*)
    printf '%s\n' 'base123'
    ;;
  *"branch --show-current"*)
    printf '%s\n' 'fix/issue-3435-critical-route-smoke'
    ;;
  *"rev-list --count develop..fix/issue-3435-critical-route-smoke"*)
    printf '%s\n' '1'
    ;;
  *"status --porcelain"*)
    exit 0
    ;;
  *"rev-parse HEAD"*)
    printf '%s\n' "$pushed_head_full"
    ;;
  *"rev-parse --short HEAD"*)
    printf '%s\n' '2222222'
    ;;
  *"rev-parse --verify refs/remotes/origin/fix/issue-3435-critical-route-smoke"*)
    printf '%s\n' "$pushed_head_full"
    ;;
  *"diff --name-only develop..HEAD"*)
    printf '%s\n' 'backend/tests/test_critical_routes.py'
    ;;
esac
exit 0
EOF
chmod +x "$TEST_TMP/bin/git"

set +e
output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  TK="$SANITIZED_ROOT" \
  bash "$SANITIZED_ROOT/scripts/smart_poll_agents.sh" "$TEST_TMP/final-pushed.config.sh" 2>&1
)
status=$?
set -e

[[ "$status" -eq 1 ]] || fail "expected pushed final-report poll timeout after one pass, got $status: $output"
[[ "$output" == *"FINAL_REPORT_HANDOFF_REQUIRED agent=claude issue=3435 handoff_state=pushed_no_pr branch=fix/issue-3435-critical-route-smoke head=2222222"* ]] \
  || fail "expected pushed branch/no-PR final report handoff event: $output"
[[ "$output" == *"action=queue_pr"* ]] \
  || fail "expected pushed branch/no-PR final report to queue PR handoff: $output"
grep -q '"issue":3435' "$TEST_TMP/state/final-report-pushed-test/final-report-handoffs.jsonl" \
  || fail "expected pushed final report handoff JSONL evidence"
grep -q 'action=queue_pr' "$TEST_TMP/state/final-report-pushed-test/ORCH_TASKS.md" \
  || fail "expected pushed final report to queue PR operator task"
[[ -f "$TEST_TMP/state/final-report-pushed-test/orch.run_now" ]] \
  || fail "expected pushed final report to request next loop tick"

printf 'ok - smart_poll quota autodetect, poll registry cleanup, and final report handoffs work\n'
