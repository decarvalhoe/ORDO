#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP=$(mktemp -d)
SANITIZED_ROOT="$TEST_TMP/toolkit"
PROMPT_FILE="/tmp/dispatch-claude-autofix-pr-77.md"

cleanup() {
  rm -rf "$TEST_TMP"
  rm -f "$PROMPT_FILE"
}
trap cleanup EXIT

fail() {
  printf 'not ok - %s\n' "$*" >&2
  exit 1
}

mkdir -p "$SANITIZED_ROOT/scripts" "$SANITIZED_ROOT/lib" "$TEST_TMP/bin" "$TEST_TMP/logs"

for rel in \
  scripts/ci_autofix.sh \
  lib/audit_log.sh \
  lib/config_check.sh \
  lib/dry_run.sh \
  lib/state_persist.sh
do
  tr -d '\r' < "$ROOT/$rel" > "$SANITIZED_ROOT/$rel"
done

chmod +x "$SANITIZED_ROOT/scripts/ci_autofix.sh"

cat > "$TEST_TMP/test.config.sh" <<EOF
#!/usr/bin/env bash
PROJECT="ci-autofix-test"
GH_REPO="RBOKproject/orchestrator-toolkit"
GH_CONFIG_DIR="$TEST_TMP/gh"
DEFAULT_BRANCH="develop"
AGENT_SESSION_PREFIX=""
AGENT_WORKDIR_TEMPLATE="$TEST_TMP/worktrees/%s"
EOF

cat > "$TEST_TMP/bin/gh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "\$*" >> "$TEST_TMP/logs/gh.log"
case "\$*" in
  *"pr view 77"* )
    printf '%s\n' '{"title":"Fix CI on toolkit","headRefName":"feat/test-pr","baseRefName":"develop","changedFiles":2,"files":[{"path":"scripts/example.sh"},{"path":"README.md"}],"url":"https://github.com/RBOKproject/orchestrator-toolkit/pull/77"}'
    ;;
  *"pr checks 77"* )
    printf '%s\n' '[{"name":"lint","state":null,"bucket":"pass","link":"https://github.com/RBOKproject/orchestrator-toolkit/actions/runs/320/job/650","workflow":"CI"},{"name":"unit","state":"FAILURE","bucket":"fail","link":"https://github.com/RBOKproject/orchestrator-toolkit/actions/runs/321/job/654","workflow":"CI"}]'
    ;;
  *"run view 321 --log-failed"* )
    printf '%s\n' 'FAILED STEP: tests/test_demo.sh'
    printf '%s\n' 'Assertion failed in dispatch validation'
    ;;
  * )
    printf '%s\n' '{}'
    ;;
esac
EOF
chmod +x "$TEST_TMP/bin/gh"

cat > "$SANITIZED_ROOT/scripts/dispatch_ticket.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "\$*" >> "$TEST_TMP/logs/dispatch.log"
exit 0
EOF
chmod +x "$SANITIZED_ROOT/scripts/dispatch_ticket.sh"

set +e
dry_run_output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  bash "$SANITIZED_ROOT/scripts/ci_autofix.sh" "$TEST_TMP/test.config.sh" 77 claude --dry-run 2>&1
)
dry_run_status=$?
set -e

[[ "$dry_run_status" -eq 0 ]] || fail "ci_autofix dry-run exited $dry_run_status: $dry_run_output"
[[ -f "$PROMPT_FILE" ]] || fail "ci_autofix should generate a prompt file"
[[ "$dry_run_output" == *"DRY-RUN:"* ]] || fail "expected DRY-RUN output from ci_autofix"
grep -q "## Objectif" "$PROMPT_FILE" || fail "prompt missing canonical heading"
grep -q "Fix CI on toolkit" "$PROMPT_FILE" || fail "prompt missing PR title"
grep -q "FAILED STEP: tests/test_demo.sh" "$PROMPT_FILE" || fail "prompt missing failed log excerpt"
grep -q -- "--dry-run" "$TEST_TMP/logs/dispatch.log" || fail "dispatch call must relay --dry-run"
[[ ! -f "$TEST_TMP/state/ci-autofix-test/ci_autofix_retries.json" ]] || fail "dry-run must not persist retry state"

mkdir -p "$TEST_TMP/state/ci-autofix-test"
printf '{"77":3}\n' > "$TEST_TMP/state/ci-autofix-test/ci_autofix_retries.json"
: > "$TEST_TMP/logs/dispatch.log"

set +e
cap_output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  CI_AUTOFIX_MAX_RETRIES=3 \
  bash "$SANITIZED_ROOT/scripts/ci_autofix.sh" "$TEST_TMP/test.config.sh" 77 claude 2>&1
)
cap_status=$?
set -e

[[ "$cap_status" -ne 0 ]] || fail "ci_autofix should refuse once retry cap is reached"
[[ "$cap_output" == *"retry cap reached"* ]] || fail "expected retry-cap error, got: $cap_output"
[[ ! -s "$TEST_TMP/logs/dispatch.log" ]] || fail "retry-cap path must not dispatch"

printf 'ok - ci_autofix prompt generation, dry-run, and retry cap\n'
