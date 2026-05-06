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

mkdir -p "$SANITIZED_ROOT/scripts" "$SANITIZED_ROOT/lib" "$TEST_TMP/bin" "$TEST_TMP/logs"

for rel in \
  scripts/dispatch_plan.sh \
  lib/audit_log.sh \
  lib/config_check.sh \
  lib/config_resolver.sh \
  lib/dry_run.sh
do
  tr -d '\r' < "$ROOT/$rel" > "$SANITIZED_ROOT/$rel"
done
chmod +x "$SANITIZED_ROOT/scripts/dispatch_plan.sh"

cat > "$TEST_TMP/config.sh" <<EOF
PROJECT="plan-test"
GH_REPO="example/repo"
GH_CONFIG_DIR="$TEST_TMP/gh"
DEFAULT_BRANCH="main"
AGENT_REPO_PREFIX="$TEST_TMP/repos/"
export AGENT_WORKDIR_TEMPLATE="$TEST_TMP/repos/%s"
EOF

cat > "$TEST_TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"issue list"* )
    cat <<'JSON'
[
  {"number":10,"title":"Frontend routing fix","labels":[{"name":"priority:P1"}],"assignees":[],"body":"Ready issue","updatedAt":"2026-05-06T00:00:00Z","url":"https://example.test/10"},
  {"number":11,"title":"Backend blocked work","labels":[{"name":"priority:P0"}],"assignees":[],"body":"Blocked by: #99","updatedAt":"2026-05-06T00:00:00Z","url":"https://example.test/11"},
  {"number":12,"title":"Large parent feature","labels":[{"name":"size:xl"}],"assignees":[],"body":"Parent scope stays here\n\n- [ ] child one\n- [ ] child two\n- [ ] child three","updatedAt":"2026-05-06T00:00:00Z","url":"https://example.test/12"},
  {"number":13,"title":"EPIC: Broad parent","labels":[{"name":"priority:P2"}],"assignees":[],"body":"No checklist yet","updatedAt":"2026-05-06T00:00:00Z","url":"https://example.test/13"},
  {"number":14,"title":"[INFRA] Deploy circuit breaker","labels":[{"name":"priority:P2"}],"assignees":[],"body":"CI/deploy resilience","updatedAt":"2026-05-06T00:00:00Z","url":"https://example.test/14"},
  {"number":15,"title":"[META] Consolidation parent","labels":[{"name":"priority:P2"}],"assignees":[],"body":"Consolidates several bugs","updatedAt":"2026-05-06T00:00:00Z","url":"https://example.test/15"},
  {"number":99,"title":"Dependency","labels":[],"assignees":[],"body":"","updatedAt":"2026-05-06T00:00:00Z","url":"https://example.test/99"}
]
JSON
    ;;
  *"issue view 99"* )
    printf '%s\n' '{"state":"OPEN"}'
    ;;
  *"issue create"* )
    printf '%s\n' 'https://example.test/new-child'
    ;;
  * )
    printf '%s\n' '{}'
    ;;
esac
EOF
chmod +x "$TEST_TMP/bin/gh"

output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  bash "$SANITIZED_ROOT/scripts/dispatch_plan.sh" "$TEST_TMP/config.sh" --tsv
)

[[ "$output" == *$'issue\tpriority\tscore\tstatus'* ]] || fail "missing header: $output"
[[ "$output" == *$'10\tP1\t800\tready\tfrontend'* ]] || fail "missing ready issue: $output"
[[ "$output" == *$'11\tP0\t500\tblocked\tbackend\t\t99\t#99:OPEN'* ]] || fail "missing blocked dependency: $output"
[[ "$output" == *$'12\tP3\t250\tatomize\tany'* ]] || fail "missing atomize status: $output"
[[ "$output" == *$'13\tP2\t550\tatomize\tany'* ]] || fail "missing epic atomize status: $output"
[[ "$output" == *$'14\tP2\t600\tready\tdevops'* ]] || fail "missing devops hint: $output"
[[ "$output" == *$'15\tP2\t550\tatomize\tany'* ]] || fail "missing meta atomize status: $output"

ready_output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  bash "$SANITIZED_ROOT/scripts/dispatch_plan.sh" "$TEST_TMP/config.sh" --ready-only --json
)

jq -e 'length == 3 and (map(select(.issue == 10 and .status == "ready")) | length == 1) and (map(select(.issue == 14 and .agent_hint == "devops")) | length == 1) and (map(select(.issue == 99 and .status == "ready")) | length == 1)' <<< "$ready_output" >/dev/null \
  || fail "ready-only JSON unexpected: $ready_output"

atomize_output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  bash "$SANITIZED_ROOT/scripts/dispatch_plan.sh" "$TEST_TMP/config.sh" --atomize --dry-run 2>&1
)

[[ "$atomize_output" == *'DRY-RUN: gh issue create --repo example/repo --title "[parent #12] child one"'* ]] || \
  fail "atomize dry-run missing child creation: $atomize_output"

printf 'ok - dispatch_plan prioritizes dependencies and atomization\n'
