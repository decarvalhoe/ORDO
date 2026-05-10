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

mkdir -p "$SANITIZED_ROOT/scripts" "$SANITIZED_ROOT/lib" "$TEST_TMP/bin" "$TEST_TMP/logs" "$TEST_TMP/gh" "$TEST_TMP/work/agent/.git"

for rel in \
  scripts/audit_state.sh \
  lib/agent_inventory.sh \
  lib/audit_log.sh \
  lib/log_bounds.sh \
  lib/config_check.sh \
  lib/config_resolver.sh \
  lib/process_safety.sh \
  lib/state_persist.sh
do
  tr -d '\r' < "$ROOT/$rel" > "$SANITIZED_ROOT/$rel"
done

chmod +x "$SANITIZED_ROOT/scripts/audit_state.sh"

cat > "$TEST_TMP/test.config.sh" <<EOF
#!/usr/bin/env bash
PROJECT="audit-poll-test"
GH_REPO="RBOKproject/ORDO"
GH_CONFIG_DIR="$TEST_TMP/gh"
DEFAULT_BRANCH="main"
AGENT_WORKDIR_TEMPLATE="$TEST_TMP/work/%s"
AGENT_PANES=("agent|agent-session:0.0|$TEST_TMP/work/agent")
EOF

cat > "$TEST_TMP/bin/git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  *"branch --show-current"*)
    printf '%s\n' 'main'
    ;;
  *"log -1 --format=%h %s"*)
    printf '%s\n' 'abc123 test head'
    ;;
  *"status --porcelain"*)
    exit 0
    ;;
  *"rev-list --count"*)
    printf '%s\n' '0'
    ;;
esac
EOF
chmod +x "$TEST_TMP/bin/git"

cat > "$TEST_TMP/bin/tmux" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  list-panes)
    exit 0
    ;;
  has-session)
    exit 1
    ;;
esac
exit 0
EOF
chmod +x "$TEST_TMP/bin/tmux"

cat > "$TEST_TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' '[]'
EOF
chmod +x "$TEST_TMP/bin/gh"

dead_pid=999999
while kill -0 "$dead_pid" 2>/dev/null; do
  dead_pid=$((dead_pid - 1))
done
mkdir -p "$TEST_TMP/state/audit-poll-test/poll-registry"
cat > "$TEST_TMP/state/audit-poll-test/poll-registry/stale.env" <<EOF
pid=$dead_pid
project=audit-poll-test
wave_id=old-wave
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
  bash "$SANITIZED_ROOT/scripts/audit_state.sh" "$TEST_TMP/test.config.sh" 2>&1
)
status=$?
set -e

[[ "$status" -eq 0 ]] || fail "expected audit_state to pass, got $status: $output"
[[ "$output" == *"=== smart poll registry ==="* ]] || fail "expected smart poll registry section: $output"
[[ "$output" == *"stale-poll pid=$dead_pid wave=old-wave"* ]] || fail "expected stale poll row: $output"
[[ "$output" == *"STALE_POLL project=audit-poll-test pid=$dead_pid wave=old-wave"* ]] || fail "expected stale poll audit signal: $output"

printf 'ok - audit_state reports smart poll registry staleness\n'
