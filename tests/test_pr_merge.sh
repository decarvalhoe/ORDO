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

mkdir -p "$SANITIZED_ROOT/lib" "$TEST_TMP/bin" "$TEST_TMP/logs"

for rel in \
  lib/pr_merge.sh \
  lib/audit_log.sh \
  lib/config_check.sh \
  lib/dry_run.sh \
  lib/governance_check.sh
do
  tr -d '\r' < "$ROOT/$rel" > "$SANITIZED_ROOT/$rel"
done

chmod +x "$SANITIZED_ROOT/lib/pr_merge.sh"

cat > "$TEST_TMP/test.config.sh" <<EOF
#!/usr/bin/env bash
PROJECT="pr-merge-test"
GH_REPO="RBOKproject/orchestrator-toolkit"
GH_CONFIG_DIR="$TEST_TMP/gh"
DEFAULT_BRANCH="develop"
AGENT_WORKDIR_TEMPLATE="$TEST_TMP/worktrees/%s"
PR_MERGE_CI_INTERVAL_SEC=0
PR_MERGE_CI_INTERVAL_SEC=1
PR_MERGE_CI_TIMEOUT_SEC=1
EOF

cat > "$TEST_TMP/bin/gh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "\$*" >> "$TEST_TMP/logs/gh.log"
case "\$*" in
  *"pr view 88"*statusCheckRollup* )
    printf '%s\n' '{"statusCheckRollup":[{"status":"IN_PROGRESS","conclusion":"","name":"ci"}]}'
    ;;
  *"pr view 88"*state,mergeStateStatus,mergeable* )
    printf '%s\n' '{"state":"CLOSED","mergeStateStatus":"UNKNOWN","mergeable":"UNKNOWN"}'
    ;;
  *"pr view 88"*mergeStateStatus* )
    printf '%s\n' '{"mergeStateStatus":"UNKNOWN"}'
    ;;
  * )
    printf '%s\n' '{}'
    ;;
esac
EOF
chmod +x "$TEST_TMP/bin/gh"

cat > "$TEST_TMP/bin/sleep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$TEST_TMP/bin/sleep"

set +e
output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  bash "$SANITIZED_ROOT/lib/pr_merge.sh" "$TEST_TMP/test.config.sh" 88 2>&1
)
status=$?
set -e

[[ "$status" -eq 8 ]] || fail "expected exit 8 for closed PR mid-poll, got $status: $output"
[[ "$output" == *"state=CLOSED mid-poll"* ]] || fail "expected closed mid-poll audit line, got: $output"

printf 'ok - pr_merge aborts immediately when PR closes mid-poll\n'
