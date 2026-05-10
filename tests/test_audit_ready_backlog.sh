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

# shellcheck source=../lib/test_sanitize.sh
source "$ROOT/lib/test_sanitize.sh"
sanitize_toolkit_copy "$SANITIZED_ROOT" \
  scripts/audit_state.sh

mkdir -p "$SANITIZED_ROOT/scripts" "$TEST_TMP/bin" "$TEST_TMP/gh" \
  "$TEST_TMP/logs" "$TEST_TMP/repos/agent-1"

cat > "$TEST_TMP/config.sh" <<EOF
PROJECT="audit-ready"
GH_REPO="example/repo"
GH_CONFIG_DIR="$TEST_TMP/gh"
DEFAULT_BRANCH="main"
export AGENT_WORKDIR_TEMPLATE="$TEST_TMP/repos/%s"
AGENT_PANES=(
  "agent-1|audit-ready:0.0|$TEST_TMP/repos/agent-1"
)
EOF

cat > "$TEST_TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"pr list"*|*"run list"*|*"issue list"* )
    printf '%s\n' '[]'
    ;;
  * )
    printf '%s\n' '[]'
    ;;
esac
EOF
chmod +x "$TEST_TMP/bin/gh"

cat > "$SANITIZED_ROOT/scripts/dispatch_plan.sh" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *"--ready-only"* && "$*" == *"--json"* ]]; then
  cat <<'JSON'
[
  {"issue":602,"title":"Ready audit regression","status":"ready","priority":"P0"},
  {"issue":603,"title":"Second ready item","status":"ready","priority":"P1"}
]
JSON
else
  printf '%s\n' '[]'
fi
EOF
chmod +x "$SANITIZED_ROOT/scripts/dispatch_plan.sh"

set +e
output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  bash "$SANITIZED_ROOT/scripts/audit_state.sh" "$TEST_TMP/config.sh" 2>&1
)
status=$?
set -e

[[ "$status" -eq 0 ]] || fail "audit_state should run, got status=$status output=$output"
[[ "$output" == *"dispatch_plan --ready-only ready issues = 2"* ]] \
  || fail "audit backlog should be sourced from ready-only dispatch_plan rows: $output"
[[ "$output" == *"AUDIT END project=audit-ready backlog=2"* ]] \
  || fail "audit end should log backlog=2 from ready queue: $output"
[[ "$output" != *"AUDIT END project=audit-ready backlog=0"* ]] \
  || fail "audit end must not report zero when ready-only dispatch_plan has rows: $output"

printf 'ok - audit backlog uses dispatch_plan ready queue\n'
