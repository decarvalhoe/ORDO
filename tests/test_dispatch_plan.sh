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
  lib/log_bounds.sh \
  lib/config_check.sh \
  lib/config_resolver.sh \
  lib/dispatch_plan_headers.sh \
  lib/dry_run.sh \
  lib/github_identity.sh \
  lib/label_helpers.sh \
  lib/process_safety.sh \
  lib/external_mutation_gate.sh \
  lib/ordo_contracts.sh \
  lib/ordo_provider_adapter.sh \
  lib/ordo_provider_adapter_github.sh \
  lib/ordo_provider_adapter_fake.sh
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
  *"label list"* )
    if [[ "${GH_MOCK_LABEL_MODE:-default}" == "missing-p3" ]]; then
      cat <<'JSON'
[
  {"name":"priority:P0"},
  {"name":"priority:P1"},
  {"name":"ordo:atomized"},
  {"name":"ordo:child"}
]
JSON
    else
      cat <<'JSON'
[
  {"name":"priority:P0"},
  {"name":"priority:P1"},
  {"name":"priority:P2"},
  {"name":"priority:P3"},
  {"name":"priority:P4"},
  {"name":"ordo:atomized"},
  {"name":"ordo:child"}
]
JSON
    fi
    ;;
  *"pr list"* )
    if [[ "$args" == *"--state open"* ]]; then
      cat <<'JSON'
[
  {"number":701,"title":"feat: pending frontend profile work","url":"https://example.test/pull/701","headRefName":"feat/pending-profile","statusCheckRollup":[{"name":"validate","state":"PENDING"}],"isDraft":false},
  {"number":702,"title":"feat: already green backend work","url":"https://example.test/pull/702","headRefName":"feat/green-backend","statusCheckRollup":[{"name":"validate","state":"SUCCESS"}],"isDraft":false},
  {"number":703,"title":"feat(30): cover ready issue with open PR","body":"Closes #30","url":"https://example.test/pull/703","headRefName":"feat/issue-30-open-pr","statusCheckRollup":[{"name":"validate","state":"SUCCESS"}],"isDraft":false}
]
JSON
    elif [[ "$args" == *"--state merged"* && "$args" == *" 17 "* ]]; then
      cat <<'JSON'
[
  {"number":501,"title":"feat(17): ship UI gate","body":"Closes #17 from the previous wave.","url":"https://example.test/pull/501","mergedAt":"2026-05-06T00:00:00Z","headRefName":"feat/issue-17-ui-gate"}
]
JSON
    elif [[ "$args" == *"--state merged"* && "$args" == *" 44 "* ]]; then
      cat <<'JSON'
[
  {"number":505,"title":"refactor: unrelated subsystem","body":"Refactor unrelated subsystem.\n\nPrerequisites: #44 must be live before this lands. See also #99.","url":"https://example.test/pull/505","mergedAt":"2026-05-07T00:00:00Z","headRefName":"refactor/unrelated"}
]
JSON
    elif [[ "$args" == *"--state merged"* && "$args" == *" 21 "* ]]; then
      cat <<'JSON'
[
  {"number":502,"title":"feat(21): wire stale parent path","body":"Closes #21","url":"https://example.test/pull/502","mergedAt":"2026-05-06T12:00:00Z","headRefName":"feat/issue-21-stale-parent"}
]
JSON
    elif [[ "$args" == *"--state merged"* && "$args" == *" 31 "* ]]; then
      cat <<'JSON'
[
  {"number":503,"title":"feat(31): previous active backlog evidence","body":"Closes #31","url":"https://example.test/pull/503","mergedAt":"2026-05-06T12:30:00Z","headRefName":"feat/issue-31-active-backlog-label"}
]
JSON
    elif [[ "$args" == *"--state merged"* && "$args" == *" 32 "* ]]; then
      cat <<'JSON'
[
  {"number":504,"title":"feat(32): previous launch backlog evidence","body":"Closes #32","url":"https://example.test/pull/504","mergedAt":"2026-05-06T13:00:00Z","headRefName":"feat/issue-32-launch-backlog"}
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
  {"number":20,"title":"Stale parent via comment","labels":[{"name":"priority:P2"}],"assignees":[],"body":"Maintainer commented work was already shipped, no checklist remains","updatedAt":"2026-05-06T00:00:00Z","url":"https://example.test/20"},
  {"number":21,"title":"Parent shipped but follow-ups remain","labels":[{"name":"priority:P1"}],"assignees":[],"body":"Parent that ships scope via PR while keeping unchecked tasks\n\n- [ ] followup task A\n- [ ] followup task B\n- [ ] followup task C","updatedAt":"2026-05-06T00:00:00Z","url":"https://example.test/21"},
  {"number":22,"title":"Source refs checklist parent","labels":[],"assignees":[],"body":"Parent checklist with source issue references\n\n- [ ] Preserve source issue ref #201 in child A\n- [ ] Preserve source issue ref #202 in child B\n- [ ] Preserve source issue ref #203 in child C","updatedAt":"2026-05-06T00:00:00Z","url":"https://example.test/22"},
  {"number":23,"title":"[parent #30] Build export worker","labels":[{"name":"priority:P2"}],"assignees":[],"body":"Parent issue: #30\n\nGenerated by: `dispatch_plan --atomize`\n\nBuild the export worker.","updatedAt":"2026-05-06T00:00:00Z","url":"https://example.test/23"},
  {"number":24,"title":"[parent #30] Verify completion after all sibling issues are closed","labels":[{"name":"priority:P1"}],"assignees":[],"body":"Parent issue: #30\n\nGenerated by: `dispatch_plan --atomize`\n\nVerify completion after all sibling issues are closed with links to merge evidence.","updatedAt":"2026-05-06T00:00:00Z","url":"https://example.test/24"},
  {"number":25,"title":"[parent #31] Verify field-level validation","labels":[{"name":"priority:P2"}],"assignees":[],"body":"Parent issue: #31\n\nGenerated by: `dispatch_plan --atomize`\n\nVerify field-level validation for this child.","updatedAt":"2026-05-06T00:00:00Z","url":"https://example.test/25"},
  {"number":26,"title":"[parent #31] Build field-level validation","labels":[{"name":"priority:P2"}],"assignees":[],"body":"Parent issue: #31\n\nGenerated by: `dispatch_plan --atomize`\n\nBuild field-level validation.","updatedAt":"2026-05-06T00:00:00Z","url":"https://example.test/26"},
  {"number":27,"title":"Ready profile UI overlap","labels":[{"name":"priority:P1"}],"assignees":[],"body":"Ready while CI is pending.\n\nScope files:\n- frontend/profile/page.tsx\n- frontend/profile/*.test.tsx","updatedAt":"2026-05-06T00:00:00Z","url":"https://example.test/27"},
  {"number":28,"title":"Ready billing worker safe","labels":[{"name":"priority:P1"}],"assignees":[],"body":"Ready while CI is pending.\n\nScope files:\n- backend/billing/worker.py\n- docs/billing.md","updatedAt":"2026-05-06T00:00:00Z","url":"https://example.test/28"},
  {"number":29,"title":"Ready needs scope declaration","labels":[{"name":"priority:P2"}],"assignees":[],"body":"Ready work without explicit ownership files.","updatedAt":"2026-05-06T00:00:00Z","url":"https://example.test/29"},
  {"number":30,"title":"Ready covered by open PR","labels":[{"name":"priority:P1"}],"assignees":[],"body":"Ready issue that already has an open PR.","updatedAt":"2026-05-06T00:00:00Z","url":"https://example.test/30"},
  {"number":31,"title":"Active backlog by label","labels":[{"name":"priority:P1"},{"name":"dispatch:active-backlog"}],"assignees":[],"body":"Open launch backlog should stay dispatchable despite historical merged PR evidence.","updatedAt":"2026-05-06T00:00:00Z","url":"https://example.test/31"},
  {"number":32,"title":"Active backlog by policy","labels":[{"name":"priority:P1"}],"assignees":[],"body":"Open launch backlog with one remaining task.\n\n- [ ] finish active launch follow-up","updatedAt":"2026-05-06T00:00:00Z","url":"https://example.test/32"},
  {"number":33,"title":"Explicitly shipped active backlog","labels":[{"name":"priority:P1"},{"name":"dispatch:active-backlog"},{"name":"status:shipped"}],"assignees":[],"body":"Maintainer explicitly labelled this open issue as shipped.","updatedAt":"2026-05-06T00:00:00Z","url":"https://example.test/33"},
  {"number":44,"title":"Mentioned as PR prerequisite","labels":[{"name":"priority:P1"}],"assignees":[],"body":"Standalone ready issue. A merged PR references it as a prerequisite but does not close it.","updatedAt":"2026-05-06T00:00:00Z","url":"https://example.test/44"},
  {"number":99,"title":"Dependency","labels":[],"assignees":[],"body":"","updatedAt":"2026-05-06T00:00:00Z","url":"https://example.test/99"}
]
JSON
    ;;
  # The provider adapter (#816) reads files (pr_files) and the rollup
  # (checks_get) per PR: both come from `gh pr view N --json ...`.
  *"pr view 701"* )
    printf '%s\n' '{"number":701,"files":[{"path":"frontend/profile/page.tsx"},{"path":"frontend/profile/form.tsx"},{"path":"docs/shared-ci.md"}],"statusCheckRollup":[{"__typename":"StatusContext","context":"validate","state":"PENDING"}]}'
    ;;
  *"pr view 702"* )
    printf '%s\n' '{"number":702,"files":[{"path":"backend/green.py"}],"statusCheckRollup":[{"__typename":"StatusContext","context":"validate","state":"SUCCESS"}]}'
    ;;
  *"pr view 703"* )
    printf '%s\n' '{"number":703,"files":[],"statusCheckRollup":[{"__typename":"StatusContext","context":"validate","state":"SUCCESS"}]}'
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
  *"issue view 20"*comments* )
    comment_created_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    cat <<JSON
{"comments":[
  {"body":"Heads up — this was shipped in PR #777 already, can probably close.","createdAt":"${comment_created_at}","url":"https://example.test/20#issuecomment-1","author":{"login":"maintainer"}}
]}
JSON
    ;;
  *"issue view 20"* )
    printf '%s\n' '{"number":20,"state":"OPEN","assignees":[],"title":"Stale parent via comment"}'
    ;;
  *"issue view 21"*comments* )
    printf '%s\n' '{"comments":[]}'
    ;;
  *"issue view 21"* )
    printf '%s\n' '{"number":21,"state":"OPEN","assignees":[],"title":"Parent shipped but follow-ups remain"}'
    ;;
  *"issue view 31"* )
    printf '%s\n' '{"number":31,"state":"OPEN","assignees":[],"title":"Active backlog by label"}'
    ;;
  *"issue view 32"* )
    printf '%s\n' '{"number":32,"state":"OPEN","assignees":[],"title":"Active backlog by policy"}'
    ;;
  *"issue view 33"* )
    printf '%s\n' '{"number":33,"state":"OPEN","assignees":[],"title":"Explicitly shipped active backlog"}'
    ;;
  *"issue view 44"* )
    printf '%s\n' '{"number":44,"state":"OPEN","assignees":[],"title":"Mentioned as PR prerequisite"}'
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
  *"issue comment"* )
    # The provider adapter (#816) sends bodies by file: log the content so
    # the trace-id assertion below can see it.
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
      cat "$body_file" >> "${GH_MOCK_LOG:-/dev/null}"
    fi
    printf '%s\n' 'https://example.test/issues/12#issuecomment-1'
    ;;
  *"issue edit"* )
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
[[ "$output" == *$'12\t\t250\tatomize\tany'* ]] || fail "missing atomize status without synthetic priority label: $output"
[[ "$output" == *$'13\tP2\t550\tatomize\tany'* ]] || fail "missing epic atomize status: $output"
[[ "$output" == *$'14\tP2\t600\tready\tdevops'* ]] || fail "missing devops hint: $output"
[[ "$output" == *$'15\tP2\t550\tatomize\tany'* ]] || fail "missing meta atomize status: $output"
[[ "$output" == *$'16\tP2\t100\tblocked\tany'*$'\t\t\t\t0\t\tpriority:P2,blocked,label-blocked,unassigned'* ]] || fail "missing label-blocked status: $output"
[[ "$output" == *$'17\tP1\t500\tshipped_suspect\tfrontend'*$'\t\t\t\t0\t\tpriority:P1,ready,stale-suspect,shipped-suspect,merged-pr:#501,unassigned'* ]] || \
  fail "missing shipped suspect status: $output"
[[ "$output" == *$'18\tP1\t800\tready\tany'*$'\t\t\t\t3\t12\tpriority:P1,atomized-child,parent:#12,ready,unassigned'* ]] || \
  fail "atomized child label should be ready, not recursive atomize: $output"
[[ "$output" == *$'19\tP3\t400\tready\tany'*$'\t\t\t\t3\t\tpriority:P3,atomized-child,ready,unassigned'* ]] || \
  fail "atomized child trace should be ready, not recursive atomize: $output"
[[ "$output" == *$'20\tP2\t300\tshipped_suspect\tany'*$'shipped-comment:#777,comment-by:maintainer,unassigned'* ]] || \
  fail "missing shipped_suspect via comment status (#118): $output"
[[ "$output" == *$'21\tP1\t450\tstale_parent\tany'*$'stale-suspect,shipped-suspect,merged-pr:#502,stale-parent,followup-available,unassigned'* ]] || \
  fail "missing stale_parent status with followup signal (#118): $output"
[[ "$output" == *$'22\t\t250\tatomize\tany'*$'\t\t\t\t3\t\tneeds-atomization,unassigned\tSource refs checklist parent'* ]] || \
  fail "checklist tasks with source issue refs should count toward atomization (#134): $output"
[[ "$output" != *'priority:P3,needs-atomization,unassigned'* ]] || \
  fail "unlabeled issues must not emit a missing priority:P3 label signal: $output"
[[ "$output" == *$'23\tP2\t600\tready\tany'*$'\t\t\t\t0\t30\tpriority:P2,atomized-child,parent:#30,ready,unassigned'* ]] || \
  fail "implementation sibling should remain ready: $output"
[[ "$output" == *$'24\tP1\t300\tblocked\tany'*$'\t\t\tsibling:#23:OPEN\t0\t30\tpriority:P1,atomized-child,parent:#30,semantic-dependency:all-siblings-complete,blocked_by_sibling,blocked_by_sibling:#23,blocked,unassigned'* ]] || \
  fail "downstream verification sibling should be blocked by open implementation sibling (#103): $output"
[[ "$output" == *$'25\tP2\t600\tready\tany'*$'\t\t\t\t0\t31\tpriority:P2,atomized-child,parent:#31,ready,unassigned'* ]] || \
  fail "ordinary child verification wording should stay ready when confidence is low (#103): $output"
[[ "$output" == *$'30\tP1\t300\tblocked\tany'*$'open_pr:#703'* ]] || \
  fail "issue with open PR should be blocked and carry open_pr signal (#582): $output"
[[ "$output" == *$'32\tP1\t500\tstale_parent\tany'*$'priority:P1,ready,stale-suspect,shipped-suspect,merged-pr:#504,stale-parent,followup-available,unassigned'* ]] || \
  fail "policy-disabled active backlog issue should still show stale_parent by default: $output"
[[ "$output" == *$'33\tP1\t500\tshipped_suspect\t'*$'priority:P1,explicit-shipped-label,shipped-suspect,unassigned'* ]] || \
  fail "explicit shipped label should keep issue out of active-backlog dispatch (#569): $output"
[[ "$output" == *$'44\tP1\t800\tready\t'*$'priority:P1,ready,unassigned'* ]] || \
  fail "bare PR mention (Prerequisites: #N) must not flag shipped_suspect (#778): $output"
row_44=$(printf '%s\n' "$output" | awk -F'\t' '$1 == "44"')
[[ "$row_44" != *'shipped_suspect'* ]] || \
  fail "bare PR mention regression: #44 wrongly flagged shipped_suspect (#778): $row_44"
[[ "$row_44" != *'merged-pr:#505'* ]] || \
  fail "bare PR mention regression: closing-keyword default should ignore PR #505 mention of #44 (#778): $row_44"

ready_output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  GH_MOCK_LOG="$TEST_TMP/logs/gh.log" \
  GH_MOCK_BODY="$TEST_TMP/logs/child-body.md" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  bash "$SANITIZED_ROOT/scripts/dispatch_plan.sh" "$TEST_TMP/config.sh" --ready-only --json
)

jq -e 'length == 13 and (map(select(.issue == 10 and .status == "ready")) | length == 1) and (map(select(.issue == 14 and .agent_hint == "devops")) | length == 1) and (map(select(.issue == 18 and .status == "ready" and (.signals | index("atomized-child")))) | length == 1) and (map(select(.issue == 19 and .status == "ready" and (.signals | index("atomized-child")))) | length == 1) and (map(select(.issue == 23 and .status == "ready")) | length == 1) and (map(select(.issue == 25 and .status == "ready" and ((.signals | index("blocked_by_sibling")) | not))) | length == 1) and (map(select(.issue == 26 and .status == "ready")) | length == 1) and (map(select(.issue == 27 and .status == "ready")) | length == 1) and (map(select(.issue == 28 and .status == "ready")) | length == 1) and (map(select(.issue == 29 and .status == "ready")) | length == 1) and (map(select(.issue == 31 and .status == "ready" and (.signals | index("active-backlog")) and (.signals | index("shipped-advisory")) and (.signals | index("merged-pr:#503")))) | length == 1) and (map(select(.issue == 44 and .status == "ready" and ((.signals | index("shipped-suspect")) | not) and ((.signals | index("merged-pr:#505")) | not))) | length == 1) and (map(select(.issue == 99 and .status == "ready")) | length == 1) and (map(select(.issue == 16)) | length == 0) and (map(select(.issue == 20)) | length == 0) and (map(select(.issue == 21)) | length == 0) and (map(select(.issue == 24)) | length == 0) and (map(select(.issue == 30)) | length == 0) and (map(select(.issue == 32)) | length == 0) and (map(select(.issue == 33)) | length == 0)' <<< "$ready_output" >/dev/null \
  || fail "ready-only JSON unexpected: $ready_output"

ci_overlap_json=$(
  PATH="$TEST_TMP/bin:$PATH" \
  GH_MOCK_LOG="$TEST_TMP/logs/gh.log" \
  GH_MOCK_BODY="$TEST_TMP/logs/child-body.md" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  bash "$SANITIZED_ROOT/scripts/dispatch_plan.sh" "$TEST_TMP/config.sh" --ci-overlap --json
)

jq -e '
  (map(select(.issue == 27 and .classification == "blocked_by_files" and .parallel_safe == false and (.overlap_prs | index("#701")) and (.overlap_files | index("frontend/profile/page.tsx")) and .blocked_reason == "pending_pr_file_overlap")) | length == 1)
  and (map(select(.issue == 28 and .classification == "parallel_safe" and .parallel_safe == true and (.overlap_prs | length == 0) and (.brief_note | contains("Forbidden while CI pending: frontend/profile/page.tsx,frontend/profile/form.tsx,docs/shared-ci.md")))) | length == 1)
  and (map(select(.issue == 29 and .classification == "needs_human_decision" and .parallel_safe == false and .blocked_reason == "missing_scope_files")) | length == 1)
' <<< "$ci_overlap_json" >/dev/null \
  || fail "ci-overlap JSON should classify overlap, parallel-safe, and missing-scope issues: $ci_overlap_json"

ci_overlap_tsv=$(
  PATH="$TEST_TMP/bin:$PATH" \
  GH_MOCK_LOG="$TEST_TMP/logs/gh.log" \
  GH_MOCK_BODY="$TEST_TMP/logs/child-body.md" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  bash "$SANITIZED_ROOT/scripts/dispatch_plan.sh" "$TEST_TMP/config.sh" --ci-overlap --tsv
)

[[ "$ci_overlap_tsv" == *$'issue\tstatus\tclassification\tparallel_safe\tscope_files\toverlap_prs\toverlap_files\tblocked_reason\tsuggested_next_action\tbrief_note\ttitle'* ]] || \
  fail "ci-overlap TSV missing expected header: $ci_overlap_tsv"
[[ "$ci_overlap_tsv" == *$'27\tready\tblocked_by_files\tfalse\tfrontend/profile/page.tsx,frontend/profile/*.test.tsx\t#701\tfrontend/profile/page.tsx\tpending_pr_file_overlap\twait_for_ci_or_rescope_away_from_pending_files'* ]] || \
  fail "ci-overlap TSV missing blocked overlap row: $ci_overlap_tsv"
[[ "$ci_overlap_tsv" == *$'28\tready\tparallel_safe\ttrue\tbackend/billing/worker.py,docs/billing.md\t\t\t\tdispatch_with_ci_overlap_brief\tForbidden while CI pending: frontend/profile/page.tsx,frontend/profile/form.tsx,docs/shared-ci.md'* ]] || \
  fail "ci-overlap TSV missing parallel-safe brief row: $ci_overlap_tsv"

ready_with_shipped_output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  GH_MOCK_LOG="$TEST_TMP/logs/gh.log" \
  GH_MOCK_BODY="$TEST_TMP/logs/child-body.md" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  bash "$SANITIZED_ROOT/scripts/dispatch_plan.sh" "$TEST_TMP/config.sh" --ready-only --include-shipped-suspect --json
)

jq -e 'length == 18
  and (map(select(.issue == 17 and .status == "shipped_suspect" and (.signals | index("merged-pr:#501")))) | length == 1)
  and (map(select(.issue == 20 and .status == "shipped_suspect" and (.signals | index("shipped-comment:#777")) and (.signals | index("comment-by:maintainer")))) | length == 1)
  and (map(select(.issue == 21 and .status == "stale_parent" and (.signals | index("stale-parent")) and (.signals | index("followup-available")) and (.signals | index("merged-pr:#502")))) | length == 1)
  and (map(select(.issue == 31 and .status == "ready" and (.signals | index("active-backlog")) and (.signals | index("shipped-advisory")) and (.signals | index("merged-pr:#503")))) | length == 1)
  and (map(select(.issue == 32 and .status == "stale_parent" and (.signals | index("stale-parent")) and (.signals | index("merged-pr:#504")))) | length == 1)
  and (map(select(.issue == 33 and .status == "shipped_suspect" and (.signals | index("explicit-shipped-label")))) | length == 1)' \
  <<< "$ready_with_shipped_output" >/dev/null \
  || fail "ready-only override should include shipped/stale suspects (#118): $ready_with_shipped_output"

active_backlog_label_json=$(
  PATH="$TEST_TMP/bin:$PATH" \
  GH_MOCK_LOG="$TEST_TMP/logs/gh.log" \
  GH_MOCK_BODY="$TEST_TMP/logs/child-body.md" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  bash "$SANITIZED_ROOT/scripts/dispatch_plan.sh" "$TEST_TMP/config.sh" --ready-only --json
)

jq -e '
  (map(select(.issue == 31 and .status == "ready" and (.signals | index("active-backlog")) and (.signals | index("shipped-advisory")) and (.signals | index("merged-pr:#503")))) | length == 1)
' <<< "$active_backlog_label_json" >/dev/null \
  || fail "active-backlog label should keep open issue ready while preserving advisory shipped evidence (#569): $active_backlog_label_json"

active_backlog_policy_json=$(
  PATH="$TEST_TMP/bin:$PATH" \
  GH_MOCK_LOG="$TEST_TMP/logs/gh.log" \
  GH_MOCK_BODY="$TEST_TMP/logs/child-body.md" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  DISPATCH_PLAN_ACTIVE_BACKLOG=1 \
  bash "$SANITIZED_ROOT/scripts/dispatch_plan.sh" "$TEST_TMP/config.sh" --ready-only --json
)

jq -e '
  (map(select(.issue == 17 and .status == "ready" and (.signals | index("active-backlog")) and (.signals | index("shipped-advisory")) and (.signals | index("merged-pr:#501")))) | length == 1)
  and (map(select(.issue == 20 and .status == "ready" and (.signals | index("active-backlog")) and (.signals | index("shipped-advisory")) and (.signals | index("shipped-comment:#777")))) | length == 1)
  and (map(select(.issue == 32 and .status == "ready" and .atomize_tasks == 1 and (.signals | index("active-backlog")) and (.signals | index("shipped-advisory")) and (.signals | index("merged-pr:#504")) and ((.signals | index("stale-parent")) | not))) | length == 1)
  and (map(select(.issue == 33)) | length == 0)
' <<< "$active_backlog_policy_json" >/dev/null \
  || fail "active-backlog policy should keep open launch backlog ready while shipped/stale evidence is advisory (#569): $active_backlog_policy_json"

priority_label_stderr="$TEST_TMP/logs/priority-label-preflight.stderr"
priority_label_json=$(
  PATH="$TEST_TMP/bin:$PATH" \
  GH_MOCK_LABEL_MODE=missing-p3 \
  GH_MOCK_LOG="$TEST_TMP/logs/gh.log" \
  GH_MOCK_BODY="$TEST_TMP/logs/child-body.md" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  DISPATCH_PLAN_REQUIRED_PRIORITY_LABELS="priority:P0,priority:P1,priority:P3" \
  bash "$SANITIZED_ROOT/scripts/dispatch_plan.sh" "$TEST_TMP/config.sh" --ready-only --json 2>"$priority_label_stderr"
)

jq -e 'type == "array"' <<< "$priority_label_json" >/dev/null \
  || fail "priority label preflight must not fail dispatch output: $priority_label_json"
grep -q '^label-preflight: missing label priority:P3 repo=example/repo project=plan-test$' "$priority_label_stderr" \
  || fail "priority label preflight should report missing configured label: $(cat "$priority_label_stderr")"

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
[[ "$atomize_output" == *'DRY-RUN: gh issue create --repo example/repo --title "[followup #21] followup task A"'* ]] || \
  fail "atomize dry-run should emit [followup #N] children for stale parents (#118): $atomize_output"
[[ "$atomize_output" == *'DRY-RUN: gh issue create --repo example/repo --title "[parent #22] Preserve source issue ref #201 in child A"'* ]] || \
  fail "atomize dry-run should preserve source issue refs in checklist task titles (#134): $atomize_output"
[[ "$atomize_output" == *'trace=ORDO-ATOMIZE:'* ]] || \
  fail "atomize dry-run missing trace fingerprint: $atomize_output"
! grep -q 'ORDO-ATOMIZE' "$TEST_TMP/logs/gh.log" || \
  fail "atomize dry-run should not perform per-child existing checks by default"

rm -f "$TEST_TMP/logs/child-body.md"
# The child creation, its labels and the parent comment run through the
# provider adapter (#816), which gates them like every other external
# mutation: the live scenario authorises those scopes explicitly.
atomize_live_output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  GH_MOCK_LOG="$TEST_TMP/logs/gh.log" \
  GH_MOCK_BODY="$TEST_TMP/logs/child-body.md" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  ORCH_EXTERNAL_PR_MUTATIONS="issue_create,issue_labels,issue_comment" \
  bash "$SANITIZED_ROOT/scripts/dispatch_plan.sh" "$TEST_TMP/config.sh" --atomize 2>&1
)

grep -q '<!-- ORDO-ATOMIZE:' "$TEST_TMP/logs/child-body.md" || \
  fail "atomized child body missing trace marker: $atomize_live_output"
grep -q 'Parent issue: #12' "$TEST_TMP/logs/child-body.md" || \
  fail "atomized child body missing parent link: $atomize_live_output"
grep -q 'Parent issue: #21' "$TEST_TMP/logs/child-body.md" || \
  fail "stale-parent followup body missing parent #21 link (#118): $atomize_live_output"
grep -q 'Parent issue: #22' "$TEST_TMP/logs/child-body.md" || \
  fail "source-ref atomized child body missing parent #22 link (#134): $atomize_live_output"
grep -q 'Preserve source issue ref #201 in child A' "$TEST_TMP/logs/child-body.md" || \
  fail "source issue ref should be preserved in generated child body (#134): $atomize_live_output"
grep -q '## Stale Parent Evidence' "$TEST_TMP/logs/child-body.md" || \
  fail "stale-parent followup body missing Stale Parent Evidence section (#118): $atomize_live_output"
grep -q 'pr:#502@https://example.test/pull/502' "$TEST_TMP/logs/child-body.md" || \
  fail "stale-parent followup body missing PR evidence line (#118): $atomize_live_output"
grep -q 'follow-up extracted from stale parent' "$TEST_TMP/logs/child-body.md" || \
  fail "stale-parent followup body missing generator note (#118): $atomize_live_output"
grep -q 'do NOT redo work already shipped' "$TEST_TMP/logs/child-body.md" || \
  fail "stale-parent followup body missing already_aligned guidance (#118): $atomize_live_output"
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
# exists. Existing fixture has 22 open issues, so all should remain.
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
jq -e 'length == 26 and any(.[]; .issue == 12) and any(.[]; .issue == 22) and any(.[]; .issue == 24 and .status == "blocked") and any(.[]; .issue == 28 and .status == "ready") and any(.[]; .issue == 30 and .status == "blocked" and (.signals | index("open_pr:#703"))) and any(.[]; .issue == 44 and .status == "ready")' <<< "$priority_override_json" >/dev/null \
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
jq -e 'length == 26' <<< "$priority_idle_json" >/dev/null \
  || fail "priority-set with no ready allowlist must not refuse other dispatch: $priority_idle_json"

# Legacy mention mode opt-in: the same fixture used to verify the closing-keyword
# default flags issue #44 as shipped_suspect when the operator selects the
# pre-#778 behavior via DISPATCH_PLAN_SHIPPED_MATCH_MODE=mention. Proves the
# new default is real (not a no-op) and that operators retain an audit knob.
mention_mode_output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  GH_MOCK_LOG="$TEST_TMP/logs/gh.log" \
  GH_MOCK_BODY="$TEST_TMP/logs/child-body.md" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  DISPATCH_PLAN_SHIPPED_MATCH_MODE=mention \
  bash "$SANITIZED_ROOT/scripts/dispatch_plan.sh" "$TEST_TMP/config.sh" --tsv
)

[[ "$mention_mode_output" == *$'44\tP1\t500\tshipped_suspect\t'*$'merged-pr:#505'* ]] || \
  fail "DISPATCH_PLAN_SHIPPED_MATCH_MODE=mention should restore legacy bare-mention flagging (#778): $mention_mode_output"

printf 'ok - dispatch_plan prioritizes dependencies and atomization\n'
