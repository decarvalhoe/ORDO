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
args="$*"
printf '%s\n' "$args" >> "${GH_MOCK_LOG:-/dev/null}"

if [[ "$args" == *"issue list"* && "$args" == *"ORDO-ATOMIZE"* ]]; then
  printf '%s\n' '[]'
  exit 0
fi

case "$args" in
  *"pr list"* )
    if [[ "$args" == *"--state merged"* && "$args" == *"17"* ]]; then
      cat <<'JSON'
[
  {"number":501,"title":"feat(17): ship UI gate","body":"Completes #17 from the previous wave.","url":"https://example.test/pull/501","mergedAt":"2026-05-06T00:00:00Z","headRefName":"feat/issue-17-ui-gate"}
]
JSON
    else
      printf '%s\n' '[]'
    fi
    ;;
  *"issue list"* )
    cat <<'JSON'
[
  {"number":10,"title":"Frontend routing fix","labels":[{"name":"priority:P1"}],"assignees":[],"body":"Ready issue","updatedAt":"2026-05-06T00:00:00Z","url":"https://example.test/10"},
  {"number":11,"title":"Backend blocked work","labels":[{"name":"priority:P0"}],"assignees":[],"body":"Blocked by: #99","updatedAt":"2026-05-06T00:00:00Z","url":"https://example.test/11"},
  {"number":12,"title":"Large parent feature","labels":[{"name":"size:xl"}],"assignees":[],"body":"Parent scope stays here\n\n- [ ] child one\n- [ ] child two\n- [ ] child three","updatedAt":"2026-05-06T00:00:00Z","url":"https://example.test/12"},
  {"number":13,"title":"EPIC: Broad parent","labels":[{"name":"priority:P2"}],"assignees":[],"body":"No checklist yet","updatedAt":"2026-05-06T00:00:00Z","url":"https://example.test/13"},
  {"number":14,"title":"[INFRA] Deploy circuit breaker","labels":[{"name":"priority:P2"}],"assignees":[],"body":"CI/deploy resilience","updatedAt":"2026-05-06T00:00:00Z","url":"https://example.test/14"},
  {"number":15,"title":"[META] Consolidation parent","labels":[{"name":"priority:P2"}],"assignees":[],"body":"Consolidates several bugs","updatedAt":"2026-05-06T00:00:00Z","url":"https://example.test/15"},
  {"number":16,"title":"External provider confirmation","labels":[{"name":"P2"},{"name":"blocked"}],"assignees":[],"body":"Waiting for provider confirmation","updatedAt":"2026-05-06T00:00:00Z","url":"https://example.test/16"},
  {"number":17,"title":"Frontend already shipped","labels":[{"name":"priority:P1"}],"assignees":[],"body":"Ready issue with merged work","updatedAt":"2026-05-06T00:00:00Z","url":"https://example.test/17"},
  {"number":18,"title":"[parent #12] atomized child by label","labels":[{"name":"priority:P1"},{"name":"ordo:atomized"},{"name":"ordo:child"}],"assignees":[],"body":"## ORDO Trace\n\n- Parent issue: #12\n\n## Child Objective\n\nBuild the extracted route.\n\n## Scope Inherited From Parent\n\n- [ ] parent checklist one\n- [ ] parent checklist two\n- [ ] parent checklist three","updatedAt":"2026-05-06T00:00:00Z","url":"https://example.test/18"},
  {"number":19,"title":"Atomized child by trace marker","labels":[{"name":"priority:P3"}],"assignees":[],"body":"<!-- ORDO-ATOMIZE:abc123 -->\n\n## Scope Inherited From Parent\n\n- [ ] parent checklist one\n- [ ] parent checklist two\n- [ ] parent checklist three","updatedAt":"2026-05-06T00:00:00Z","url":"https://example.test/19"},
  {"number":99,"title":"Dependency","labels":[],"assignees":[],"body":"","updatedAt":"2026-05-06T00:00:00Z","url":"https://example.test/99"}
]
JSON
    ;;
  *"issue view 99"* )
    printf '%s\n' '{"state":"OPEN"}'
    ;;
  *"issue create"* )
    body_file=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --body-file)
          body_file=$2
          shift 2
          ;;
        *)
          shift
          ;;
      esac
    done
    if [[ -n "$body_file" && -f "$body_file" ]]; then
      cat "$body_file" >> "${GH_MOCK_BODY:-/dev/null}"
    fi
    printf '%s\n' 'https://example.test/issues/120'
    ;;
  *"issue comment"*|*"issue edit"* )
    printf '%s\n' '{}'
    ;;
  * )
    printf '%s\n' '{}'
    ;;
esac
EOF
chmod +x "$TEST_TMP/bin/gh"

output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  GH_MOCK_LOG="$TEST_TMP/logs/gh.log" \
  GH_MOCK_BODY="$TEST_TMP/logs/child-body.md" \
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
[[ "$output" == *$'16\tP2\t100\tblocked\tany'*$'\t\t\t\t0\t\tpriority:P2,blocked,label-blocked,unassigned'* ]] || fail "missing label-blocked status: $output"
[[ "$output" == *$'17\tP1\t500\tshipped_suspect\tfrontend'*$'\t\t\t\t0\t\tpriority:P1,ready,stale-suspect,shipped-suspect,merged-pr:#501,unassigned'* ]] || \
  fail "missing shipped suspect status: $output"
[[ "$output" == *$'18\tP1\t800\tready\tany'*$'\t\t\t\t3\t\tpriority:P1,atomized-child,ready,unassigned'* ]] || \
  fail "atomized child label should be ready, not recursive atomize: $output"
[[ "$output" == *$'19\tP3\t400\tready\tany'*$'\t\t\t\t3\t\tpriority:P3,atomized-child,ready,unassigned'* ]] || \
  fail "atomized child trace should be ready, not recursive atomize: $output"

ready_output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  GH_MOCK_LOG="$TEST_TMP/logs/gh.log" \
  GH_MOCK_BODY="$TEST_TMP/logs/child-body.md" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  bash "$SANITIZED_ROOT/scripts/dispatch_plan.sh" "$TEST_TMP/config.sh" --ready-only --json
)

jq -e 'length == 5 and (map(select(.issue == 10 and .status == "ready")) | length == 1) and (map(select(.issue == 14 and .agent_hint == "devops")) | length == 1) and (map(select(.issue == 18 and .status == "ready" and (.signals | index("atomized-child")))) | length == 1) and (map(select(.issue == 19 and .status == "ready" and (.signals | index("atomized-child")))) | length == 1) and (map(select(.issue == 99 and .status == "ready")) | length == 1) and (map(select(.issue == 16)) | length == 0)' <<< "$ready_output" >/dev/null \
  || fail "ready-only JSON unexpected: $ready_output"

ready_with_shipped_output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  GH_MOCK_LOG="$TEST_TMP/logs/gh.log" \
  GH_MOCK_BODY="$TEST_TMP/logs/child-body.md" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  bash "$SANITIZED_ROOT/scripts/dispatch_plan.sh" "$TEST_TMP/config.sh" --ready-only --include-shipped-suspect --json
)

jq -e 'length == 6 and (map(select(.issue == 17 and .status == "shipped_suspect" and (.signals | index("merged-pr:#501")))) | length == 1)' <<< "$ready_with_shipped_output" >/dev/null \
  || fail "ready-only override should include shipped suspects: $ready_with_shipped_output"

: > "$TEST_TMP/logs/gh.log"
atomize_output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  GH_MOCK_LOG="$TEST_TMP/logs/gh.log" \
  GH_MOCK_BODY="$TEST_TMP/logs/child-body.md" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  bash "$SANITIZED_ROOT/scripts/dispatch_plan.sh" "$TEST_TMP/config.sh" --atomize --dry-run 2>&1
)

[[ "$atomize_output" == *'DRY-RUN: gh issue create --repo example/repo --title "[parent #12] child one"'* ]] || \
  fail "atomize dry-run missing child creation: $atomize_output"
[[ "$atomize_output" == *'trace=ORDO-ATOMIZE:'* ]] || \
  fail "atomize dry-run missing trace fingerprint: $atomize_output"
! grep -q 'ORDO-ATOMIZE' "$TEST_TMP/logs/gh.log" || \
  fail "atomize dry-run should not perform per-child existing checks by default"

rm -f "$TEST_TMP/logs/child-body.md"
atomize_live_output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  GH_MOCK_LOG="$TEST_TMP/logs/gh.log" \
  GH_MOCK_BODY="$TEST_TMP/logs/child-body.md" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  bash "$SANITIZED_ROOT/scripts/dispatch_plan.sh" "$TEST_TMP/config.sh" --atomize 2>&1
)

grep -q '<!-- ORDO-ATOMIZE:' "$TEST_TMP/logs/child-body.md" || \
  fail "atomized child body missing trace marker: $atomize_live_output"
grep -q 'Parent issue: #12' "$TEST_TMP/logs/child-body.md" || \
  fail "atomized child body missing parent link: $atomize_live_output"
grep -q -- '--add-label ordo:atomized' "$TEST_TMP/logs/gh.log" || \
  fail "atomized child should receive trace labels"
grep -q 'Trace: ORDO-ATOMIZE:' "$TEST_TMP/logs/gh.log" || \
  fail "parent comment should include trace id"

printf 'ok - dispatch_plan prioritizes dependencies and atomization\n'
