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
  lib/dry_run.sh \
  lib/process_safety.sh
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
  *"pr view 501"* )
    printf '%s\n' '{"number":501,"state":"MERGED","assignees":[{"login":"shipper"}],"title":"feat(17): ship UI gate"}'
    ;;
  *"pr view"* )
    exit 1
    ;;
  *"issue view 50"* )
    printf '%s\n' '{"number":50,"state":"CLOSED","assignees":[{"login":"alice"}],"title":"Closed work"}'
    ;;
  *"issue view 42"* )
    exit 1
    ;;
  *"issue view 10"* )
    printf '%s\n' '{"number":10,"state":"OPEN","assignees":[],"title":"Frontend routing fix"}'
    ;;
  *"issue view 11"* )
    printf '%s\n' '{"number":11,"state":"OPEN","assignees":[{"login":"bob"}],"title":"Backend blocked work"}'
    ;;
  *"issue view 17"* )
    printf '%s\n' '{"number":17,"state":"OPEN","assignees":[],"title":"Frontend already shipped"}'
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

# --priority-set: resolve allowlisted tickets, emit a found/missing table on
# stderr, and refuse non-allowlisted dispatch while any allowlisted ready
# ticket exists. Covers missing numbers, closed issues, assigned issues, and
# found PRs (issue #107).
priority_stderr="$TEST_TMP/logs/priority.stderr"
priority_json=$(
  PATH="$TEST_TMP/bin:$PATH" \
  GH_MOCK_LOG="$TEST_TMP/logs/gh.log" \
  GH_MOCK_BODY="$TEST_TMP/logs/child-body.md" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  bash "$SANITIZED_ROOT/scripts/dispatch_plan.sh" "$TEST_TMP/config.sh" \
    --priority-set "10,11,17,42,50,99,501" --json 2>"$priority_stderr"
)

grep -q '^priority-set: 10,11,17,42,50,99,501 repo=example/repo' "$priority_stderr" \
  || fail "priority-set header missing in stderr: $(cat "$priority_stderr")"
grep -qP '^#10\tfound\texample/repo\tissue\tOPEN\t-\tFrontend routing fix' "$priority_stderr" \
  || fail "priority-set table missing #10 found row: $(cat "$priority_stderr")"
grep -qP '^#11\tfound\texample/repo\tissue\tOPEN\tbob\tBackend blocked work' "$priority_stderr" \
  || fail "priority-set table missing #11 assigned row: $(cat "$priority_stderr")"
grep -qP '^#42\tmissing\texample/repo\t-\t-\t-\t-' "$priority_stderr" \
  || fail "priority-set table missing #42 missing row: $(cat "$priority_stderr")"
grep -qP '^#50\tfound\texample/repo\tissue\tCLOSED\talice\tClosed work' "$priority_stderr" \
  || fail "priority-set table missing closed/assigned #50 row: $(cat "$priority_stderr")"
grep -qP '^#501\tfound\texample/repo\tpr\tMERGED\tshipper' "$priority_stderr" \
  || fail "priority-set table missing PR #501 row: $(cat "$priority_stderr")"
grep -q 'priority-set: refusing non-allowlisted dispatch' "$priority_stderr" \
  || fail "priority-set should refuse non-allowlisted dispatch when ready ticket exists: $(cat "$priority_stderr")"

jq -e '
  (map(.issue) | sort) == [10,11,17,99]
' <<< "$priority_json" >/dev/null \
  || fail "priority-set filter should keep only allowlisted open issues: $priority_json"

# Override flag retains every candidate even when an allowlisted ready ticket
# exists. Existing fixture has 11 open issues (10-19, 99), so all should remain.
priority_override_stderr="$TEST_TMP/logs/priority-override.stderr"
priority_override_json=$(
  PATH="$TEST_TMP/bin:$PATH" \
  GH_MOCK_LOG="$TEST_TMP/logs/gh.log" \
  GH_MOCK_BODY="$TEST_TMP/logs/child-body.md" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  bash "$SANITIZED_ROOT/scripts/dispatch_plan.sh" "$TEST_TMP/config.sh" \
    --priority-set "10,99" --priority-set-override --json 2>"$priority_override_stderr"
)

grep -q 'priority-set: override active' "$priority_override_stderr" \
  || fail "priority-set override should announce override on stderr: $(cat "$priority_override_stderr")"
jq -e 'length == 11 and any(.[]; .issue == 12)' <<< "$priority_override_json" >/dev/null \
  || fail "priority-set override should keep non-allowlisted issues: $priority_override_json"

# When no allowlisted ticket is ready (all blocked/missing), the queue is not
# refused — every candidate stays.
priority_idle_stderr="$TEST_TMP/logs/priority-idle.stderr"
priority_idle_json=$(
  PATH="$TEST_TMP/bin:$PATH" \
  GH_MOCK_LOG="$TEST_TMP/logs/gh.log" \
  GH_MOCK_BODY="$TEST_TMP/logs/child-body.md" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  bash "$SANITIZED_ROOT/scripts/dispatch_plan.sh" "$TEST_TMP/config.sh" \
    --priority-set "11,42" --json 2>"$priority_idle_stderr"
)

grep -q 'priority-set: no allowlisted ready tickets' "$priority_idle_stderr" \
  || fail "priority-set should report idle state when no ready allowlisted tickets: $(cat "$priority_idle_stderr")"
jq -e 'length == 11' <<< "$priority_idle_json" >/dev/null \
  || fail "priority-set with no ready allowlist must not refuse other dispatch: $priority_idle_json"

printf 'ok - dispatch_plan prioritizes dependencies and atomization\n'
