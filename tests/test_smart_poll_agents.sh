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
  lib/config_check.sh \
  lib/config_resolver.sh \
  lib/quota_detect.sh
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

printf 'ok - smart_poll quota autodetect honors cooldown\n'
