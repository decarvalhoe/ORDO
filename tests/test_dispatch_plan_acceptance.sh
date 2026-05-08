#!/usr/bin/env bash
# tests/test_dispatch_plan_acceptance.sh
#
# Regression coverage for issue #265: dispatch_plan must not classify a
# bounded issue as `atomize` just because its body contains an "Acceptance
# Criteria" (or similar) checklist.
#
# Fixtures cover:
#   - acceptance-criteria-only body (no atomization);
#   - true subtask body (still atomization);
#   - mixed body (acceptance + subtasks; only subtasks count);
#   - mixed body with enough real subtasks to atomize;
#   - explicit dispatch:single-pr label override on a subtask body;
#   - explicit ORDO-DISPATCHABLE-PARENT body marker on a subtask body;
#   - acceptance + Definition of Done sections together;
#   - Validation / Risks / Notes / Preuves attendues sections.

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
  lib/log_bounds.sh \
  lib/config_check.sh \
  lib/config_resolver.sh \
  lib/dispatch_plan_headers.sh \
  lib/dry_run.sh \
  lib/github_identity.sh \
  lib/process_safety.sh
do
  tr -d '\r' < "$ROOT/$rel" > "$SANITIZED_ROOT/$rel"
done
chmod +x "$SANITIZED_ROOT/scripts/dispatch_plan.sh"

cat > "$TEST_TMP/config.sh" <<EOF
PROJECT="plan-acceptance-test"
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
    printf '%s\n' '[]'
    ;;
  *"issue list"* )
    cat <<'JSON'
[
  {"number":300,"title":"Acceptance criteria only","labels":[{"name":"priority:P1"}],"assignees":[],"body":"## Task\n\nAdd a thing.\n\n## Acceptance Criteria\n\n- [ ] item one\n- [ ] item two\n- [ ] item three\n- [ ] item four","updatedAt":"2026-05-08T00:00:00Z","url":"https://example.test/300"},
  {"number":301,"title":"True subtasks","labels":[{"name":"priority:P2"}],"assignees":[],"body":"## Subtasks\n\n- [ ] subtask one\n- [ ] subtask two\n- [ ] subtask three","updatedAt":"2026-05-08T00:00:00Z","url":"https://example.test/301"},
  {"number":302,"title":"Mixed acceptance + small subtasks","labels":[{"name":"priority:P2"}],"assignees":[],"body":"## Acceptance Criteria\n\n- [ ] acceptance one\n- [ ] acceptance two\n- [ ] acceptance three\n- [ ] acceptance four\n\n## Subtasks\n\n- [ ] do the thing\n- [ ] do the other thing","updatedAt":"2026-05-08T00:00:00Z","url":"https://example.test/302"},
  {"number":303,"title":"Mixed acceptance + enough subtasks","labels":[{"name":"priority:P2"}],"assignees":[],"body":"## Acceptance Criteria\n\n- [ ] crit one\n- [ ] crit two\n\n## Subtasks\n\n- [ ] real one\n- [ ] real two\n- [ ] real three","updatedAt":"2026-05-08T00:00:00Z","url":"https://example.test/303"},
  {"number":304,"title":"Single-PR via label","labels":[{"name":"priority:P1"},{"name":"dispatch:single-pr"}],"assignees":[],"body":"## Subtasks\n\n- [ ] would normally atomize\n- [ ] would normally atomize\n- [ ] would normally atomize\n- [ ] would normally atomize","updatedAt":"2026-05-08T00:00:00Z","url":"https://example.test/304"},
  {"number":305,"title":"Single-PR via body marker","labels":[{"name":"priority:P1"}],"assignees":[],"body":"<!-- ORDO-DISPATCHABLE-PARENT -->\n\n## Subtasks\n\n- [ ] would normally atomize\n- [ ] would normally atomize\n- [ ] would normally atomize\n- [ ] would normally atomize","updatedAt":"2026-05-08T00:00:00Z","url":"https://example.test/305"},
  {"number":306,"title":"Every recognized non-atomization header","labels":[{"name":"priority:P3"}],"assignees":[],"body":"## Task\n\nDeliver a bounded fix.\n\n## Acceptance Criteria\n\n- [ ] acc one\n- [ ] acc two\n\n## Definition of Done\n\n- [ ] dod one\n- [ ] dod two\n\n## Definition of Ready\n\n- [ ] dor one\n\n## Verification\n\n- [ ] verif one\n\n## Verification Criteria\n\n- [ ] vc one\n\n## Validation Criteria\n\n- [ ] vc two\n\n## Critères d'acceptation\n\n- [ ] crit one\n- [ ] crit two","updatedAt":"2026-05-08T00:00:00Z","url":"https://example.test/306"},
  {"number":307,"title":"Atomized child with acceptance section","labels":[{"name":"priority:P1"},{"name":"ordo:atomized"},{"name":"ordo:child"}],"assignees":[],"body":"## ORDO Trace\n\n- Parent issue: #300\n\n## Acceptance Criteria\n\n- [ ] still ready\n- [ ] still ready\n- [ ] still ready","updatedAt":"2026-05-08T00:00:00Z","url":"https://example.test/307"}
]
JSON
    ;;
  *"issue view"* )
    printf '%s\n' '{"state":"OPEN","assignees":[]}'
    ;;
  * )
    printf '%s\n' '{}'
    ;;
esac
EOF
chmod +x "$TEST_TMP/bin/gh"

# Disable shipped gate so the planner does not consult merged PRs for these
# fixtures (they intentionally focus on the atomization heuristic only).
output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  GH_MOCK_LOG="$TEST_TMP/logs/gh.log" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  DISPATCH_PLAN_SHIPPED_GATE=0 \
  bash "$SANITIZED_ROOT/scripts/dispatch_plan.sh" "$TEST_TMP/config.sh" --json
)

count_for() {
  local issue=$1
  jq -r --argjson n "$issue" '
    map(select(.issue == $n)) | .[0]
    | "status=\(.status) tasks=\(.atomize_tasks) signals=\(.signals|join(","))"
  ' <<< "$output"
}

# 300: acceptance criteria only -> ready, atomize_tasks=0, no needs-atomization
got=$(count_for 300)
[[ "$got" == "status=ready tasks=0 "* ]] || \
  fail "issue 300 (acceptance only) should be ready with 0 atomize_tasks: $got"
[[ "$got" != *"needs-atomization"* ]] || \
  fail "issue 300 (acceptance only) must not carry needs-atomization signal: $got"

# 301: true subtasks -> atomize, atomize_tasks=3
got=$(count_for 301)
[[ "$got" == "status=atomize tasks=3 "* ]] || \
  fail "issue 301 (subtasks) should atomize with 3 tasks: $got"
[[ "$got" == *"needs-atomization"* ]] || \
  fail "issue 301 (subtasks) should carry needs-atomization signal: $got"

# 302: mixed acceptance (4) + 2 subtasks -> ready (2 < min 3)
got=$(count_for 302)
[[ "$got" == "status=ready tasks=2 "* ]] || \
  fail "issue 302 (mixed; only 2 real subtasks) should be ready with 2 atomize_tasks: $got"
[[ "$got" != *"needs-atomization"* ]] || \
  fail "issue 302 should not carry needs-atomization signal: $got"

# 303: mixed acceptance (2) + 3 subtasks -> atomize, atomize_tasks=3
got=$(count_for 303)
[[ "$got" == "status=atomize tasks=3 "* ]] || \
  fail "issue 303 (mixed; 3 real subtasks) should atomize with 3 atomize_tasks: $got"

# 304: dispatch:single-pr label overrides task count -> ready with 0
got=$(count_for 304)
[[ "$got" == "status=ready tasks=0 "* ]] || \
  fail "issue 304 (label override) should be ready with 0 atomize_tasks: $got"
[[ "$got" == *"dispatchable-parent"* ]] || \
  fail "issue 304 should carry dispatchable-parent signal: $got"

# 305: ORDO-DISPATCHABLE-PARENT body marker -> ready with 0
got=$(count_for 305)
[[ "$got" == "status=ready tasks=0 "* ]] || \
  fail "issue 305 (body marker) should be ready with 0 atomize_tasks: $got"
[[ "$got" == *"dispatchable-parent"* ]] || \
  fail "issue 305 should carry dispatchable-parent signal: $got"

# 306: every checklist sits under a recognized non-atomization header
# (English + French defaults from lib/dispatch_plan_headers.sh) -> ready
got=$(count_for 306)
[[ "$got" == "status=ready tasks=0 "* ]] || \
  fail "issue 306 (acc/dod/dor/verification/validation-criteria/criteres-acceptation only) should be ready with 0 atomize_tasks: $got"

# 307: atomized child stays ready even with acceptance-style checklist
got=$(count_for 307)
[[ "$got" == "status=ready tasks=0 "* ]] || \
  fail "issue 307 (atomized child + acceptance) should be ready with 0 atomize_tasks: $got"
[[ "$got" == *"atomized-child"* ]] || \
  fail "issue 307 should still carry atomized-child signal: $got"

# Atomize dry-run should NOT propose child issues for acceptance-only or
# dispatchable-parent fixtures.
atomize_output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  GH_MOCK_LOG="$TEST_TMP/logs/gh.log" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  DISPATCH_PLAN_SHIPPED_GATE=0 \
  bash "$SANITIZED_ROOT/scripts/dispatch_plan.sh" "$TEST_TMP/config.sh" --atomize --dry-run 2>&1
)

! grep -q '\[parent #300\]' <<< "$atomize_output" || \
  fail "atomize dry-run must not propose children for acceptance-only #300: $atomize_output"
! grep -q '\[parent #304\]' <<< "$atomize_output" || \
  fail "atomize dry-run must not propose children for label-overridden #304: $atomize_output"
! grep -q '\[parent #305\]' <<< "$atomize_output" || \
  fail "atomize dry-run must not propose children for marker-overridden #305: $atomize_output"
! grep -q '\[parent #306\]' <<< "$atomize_output" || \
  fail "atomize dry-run must not propose children for non-atomization sections #306: $atomize_output"
grep -q '\[parent #301\] subtask one' <<< "$atomize_output" || \
  fail "atomize dry-run should still emit children for true subtasks #301: $atomize_output"
grep -q '\[parent #303\] real one' <<< "$atomize_output" || \
  fail "atomize dry-run should still emit children for the real subtasks of mixed #303: $atomize_output"
! grep -q '\[parent #303\] crit one' <<< "$atomize_output" || \
  fail "atomize dry-run must not turn acceptance criteria into children for mixed #303: $atomize_output"

printf 'ok - dispatch_plan distinguishes acceptance criteria from atomization tasks (#265)\n'
