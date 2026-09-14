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

mkdir -p "$SANITIZED_ROOT/scripts" "$SANITIZED_ROOT/lib" "$TEST_TMP/bin" "$TEST_TMP/repos"

for rel in \
  scripts/pr_block_signals.sh \
  lib/agent_inventory.sh \
  lib/check_rollup_summary.sh \
  lib/config_resolver.sh \
  lib/process_safety.sh \
  lib/external_mutation_gate.sh \
  lib/ordo_contracts.sh \
  lib/ordo_provider_adapter.sh \
  lib/ordo_provider_adapter_github.sh \
  lib/ordo_provider_adapter_fake.sh
do
  tr -d '\r' < "$ROOT/$rel" > "$SANITIZED_ROOT/$rel"
done
chmod +x "$SANITIZED_ROOT/scripts/pr_block_signals.sh"

repo="$TEST_TMP/repos/agent-one"
git init -q "$repo"
git -C "$repo" config user.email test@example.invalid
git -C "$repo" config user.name "Test Agent"
printf 'ok\n' > "$repo/file.txt"
git -C "$repo" add file.txt
git -C "$repo" commit -q -m 'init'
git -C "$repo" branch -M main
git -C "$repo" remote add origin "$repo"
git -C "$repo" update-ref refs/remotes/origin/main HEAD
git -C "$repo" checkout -q -b feat/blocked
git -C "$repo" checkout -q main
printf 'base drift\n' > "$repo/base.txt"
git -C "$repo" add base.txt
git -C "$repo" commit -q -m 'base drift'
git -C "$repo" update-ref refs/remotes/origin/main HEAD
git -C "$repo" checkout -q feat/blocked

cat > "$TEST_TMP/config.sh" <<EOF
PROJECT="signals-test"
DEFAULT_BRANCH="main"
GH_REPO="example/repo"
GH_CONFIG_DIR="$TEST_TMP/gh"
export AGENT_WORKDIR_TEMPLATE="$TEST_TMP/repos/%s"
AGENT_PANES=(
  "agent-one|agent-one:0.0|$repo"
)
EOF

local_head_full=$(git -C "$repo" rev-parse HEAD)

# Scenario A: PR 77 has a fake (different) headRefOid -> remote-rebased-local-stale.
# Scenario B: PR 78 is green on a non-owned branch.
cat > "$TEST_TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"pr list"* )
    printf '%s\n' '[{"number":77},{"number":78},{"number":79},{"number":80}]'
    ;;
  *"pr view 77"* )
    printf '%s\n' '{"number":77,"headRefName":"feat/blocked","headRefOid":"abcdef123456789012345678901234567890abcd","isDraft":false,"mergeStateStatus":"BLOCKED","mergeable":"MERGEABLE","reviewDecision":"REVIEW_REQUIRED","autoMergeRequest":{"enabledAt":"2026-01-01T00:00:00Z"},"statusCheckRollup":[{"status":"COMPLETED","conclusion":"FAILURE","name":"ci"},{"status":"QUEUED","conclusion":"","name":"deploy"}]}'
    ;;
  *"pr view 78"* )
    printf '%s\n' '{"number":78,"headRefName":"feat/green","headRefOid":"987654321abcdef0987654321abcdef098765432","isDraft":false,"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","reviewDecision":"APPROVED","autoMergeRequest":null,"statusCheckRollup":[{"__typename":"StatusContext","state":"SUCCESS","context":"ci"}]}'
    ;;
  * )
    printf '%s\n' '{}'
    ;;
esac
EOF
chmod +x "$TEST_TMP/bin/gh"

# Append a 79 view that returns headRefOid matching local HEAD -> genuine needs-rebase.
cat >> "$TEST_TMP/bin/gh" <<EOF

# overwrite to inject scenario for PR 79
EOF

cat > "$TEST_TMP/bin/gh" <<EOF
#!/usr/bin/env bash
case "\$*" in
  *"pr checks"*|*"--watch"* )
    printf '%s\n' 'blocking gh pr checks watch is forbidden in snapshot polling tests' >&2
    exit 99
    ;;
esac

case "\$*" in
  *"pr list"* )
    printf '%s\n' '[{"number":77},{"number":78},{"number":79},{"number":80},{"number":81},{"number":82},{"number":83},{"number":84}]'
    ;;
  *"api repos/example/repo/branches/protected/protection"* )
    printf '%s\n' '{"required_status_checks":{"contexts":["ci/protected"]}}'
    ;;
  *"api repos/example/repo/branches/main/protection"* )
    printf '%s\n' '{"required_status_checks":{"contexts":[]}}'
    ;;
  *"workflow list"* )
    if [ "\${GH_ACTIVE_WORKFLOWS:-1}" = "0" ]; then
      printf '%s\n' '[]'
    else
      printf '%s\n' '[{"name":"CI","state":"active"}]'
    fi
    ;;
  *"run list"*"--commit deadbeefcafe"* )
    printf '%s\n' '[{"databaseId":8001,"name":"Deploy gate / dev","status":"in_progress","conclusion":"","headSha":"deadbeefcafe","url":"https://example.test/runs/8001"}]'
    ;;
  *"run list"*"--commit beadfeedcafe"* )
    printf '%s\n' '[{"databaseId":8101,"name":"lint","status":"queued","conclusion":"","headSha":"beadfeedcafe","url":"https://example.test/runs/8101"}]'
    ;;
  *"run list"*"--commit f00dbabe"* )
    printf '%s\n' '[]'
    ;;
  *"run list"*"--commit cafe0000"* )
    printf '%s\n' '[]'
    ;;
  *"run list"*"--commit feed0000"* )
    printf '%s\n' '[]'
    ;;
  *"pr view 82"*files* )
    printf '%s\n' '{"files":[{"path":"scripts/ci.sh"}]}'
    ;;
  *"pr view 83"*files* )
    printf '%s\n' '{"files":[{"path":"docs/runbook.md"}]}'
    ;;
  *"pr view 84"*files* )
    printf '%s\n' '{"files":[{"path":"scripts/ci.sh"}]}'
    ;;
  *"pr view 77"* )
    printf '%s\n' '{"number":77,"headRefName":"feat/blocked","headRefOid":"abcdef123456789012345678901234567890abcd","isDraft":false,"mergeStateStatus":"BLOCKED","mergeable":"MERGEABLE","reviewDecision":"REVIEW_REQUIRED","autoMergeRequest":{"enabledAt":"2026-01-01T00:00:00Z"},"statusCheckRollup":[{"status":"COMPLETED","conclusion":"FAILURE","name":"ci"},{"status":"QUEUED","conclusion":"","name":"deploy"}]}'
    ;;
  *"pr view 78"* )
    printf '%s\n' '{"number":78,"headRefName":"feat/green","headRefOid":"987654321abcdef0987654321abcdef098765432","isDraft":false,"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","reviewDecision":"APPROVED","autoMergeRequest":null,"statusCheckRollup":[{"__typename":"StatusContext","state":"SUCCESS","context":"ci"}]}'
    ;;
  *"pr view 79"* )
    printf '%s\n' '{"number":79,"headRefName":"feat/blocked","headRefOid":"$local_head_full","isDraft":false,"mergeStateStatus":"BEHIND","mergeable":"MERGEABLE","reviewDecision":"APPROVED","autoMergeRequest":null,"statusCheckRollup":[{"__typename":"StatusContext","state":"SUCCESS","context":"ci"}]}'
    ;;
  *"pr view 80"* )
    printf '%s\n' '{"number":80,"headRefName":"feat/deploy-wait","headRefOid":"deadbeefcafe","isDraft":false,"mergeStateStatus":"BLOCKED","mergeable":"MERGEABLE","reviewDecision":"APPROVED","autoMergeRequest":null,"statusCheckRollup":[{"status":"COMPLETED","conclusion":"SUCCESS","name":"ci","detailsUrl":"https://example.test/checks/ci-80"},{"status":"IN_PROGRESS","conclusion":"","name":"Deploy gate / dev","detailsUrl":"https://example.test/checks/deploy-80"}]}'
    ;;
  *"pr view 81"* )
    printf '%s\n' '{"number":81,"headRefName":"feat/two-pending","headRefOid":"beadfeedcafe","isDraft":false,"mergeStateStatus":"BLOCKED","mergeable":"MERGEABLE","reviewDecision":"APPROVED","autoMergeRequest":null,"statusCheckRollup":[{"status":"QUEUED","conclusion":"","name":"lint","detailsUrl":"https://example.test/checks/lint-81"},{"__typename":"StatusContext","state":"PENDING","context":"unit","targetUrl":"https://example.test/checks/unit-81"}]}'
    ;;
  *"pr view 82"* )
    printf '%s\n' '{"number":82,"headRefName":"feat/required-context-missing","headRefOid":"f00dbabe","baseRefName":"protected","isDraft":false,"mergeStateStatus":"BLOCKED","mergeable":"MERGEABLE","reviewDecision":"APPROVED","autoMergeRequest":null,"statusCheckRollup":[]}'
    ;;
  *"pr view 83"* )
    printf '%s\n' '{"number":83,"headRefName":"feat/docs-only","headRefOid":"cafe0000","baseRefName":"main","isDraft":false,"mergeStateStatus":"BLOCKED","mergeable":"MERGEABLE","reviewDecision":"APPROVED","autoMergeRequest":null,"statusCheckRollup":[]}'
    ;;
  *"pr view 84"* )
    printf '%s\n' '{"number":84,"headRefName":"feat/workflow-not-triggered","headRefOid":"feed0000","baseRefName":"main","isDraft":false,"mergeStateStatus":"BLOCKED","mergeable":"MERGEABLE","reviewDecision":"APPROVED","autoMergeRequest":null,"statusCheckRollup":[]}'
    ;;
  * )
    printf '%s\n' '{}'
    ;;
esac
EOF
chmod +x "$TEST_TMP/bin/gh"

output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  PR_SIGNAL_BASE_FETCH=0 \
  bash "$SANITIZED_ROOT/scripts/pr_block_signals.sh" "$TEST_TMP/config.sh" --tsv
)

[[ "$output" == *$'pr\tbranch\thead\tagent'* ]] || fail "missing header: $output"
# Header now carries ci_aggregate + ci_failed_names (#346) — assert all
# columns are in place.
[[ "$output" == *$'pr\tbranch\thead\tagent\tmerge_state\tmergeable\treview\tci_aggregate\tci_fail\tci_pending\tbase_current\tci_failed_names\tci_actionable_state\tnext_action\tsignals'* ]] || \
  fail "missing extended header columns (#346): $output"
# Row 77: failed CI matrix → ci_aggregate=failed_or_cancelled, ci_failed_names=ci.
[[ "$output" == *$'77\tfeat/blocked\tabcdef12\tagent-one\tBLOCKED\tMERGEABLE\tREVIEW_REQUIRED\tfailed_or_cancelled\t1\t1\t0\tci\tchecks_failed\tfix_or_rerun_failed_checks\t'* ]] || fail "missing row: $output"
[[ "$output" == *"merge-blocked"* ]] || fail "missing merge-blocked signal: $output"
[[ "$output" == *"review-required"* ]] || fail "missing review-required signal: $output"
[[ "$output" == *"ci-failed"* ]] || fail "missing ci-failed signal: $output"
[[ "$output" == *"ci-pending"* ]] || fail "missing ci-pending signal: $output"
[[ "$output" == *"auto-merge-armed"* ]] || fail "missing auto-merge signal: $output"
[[ "$output" == *"remote-rebased-local-stale"* ]] || fail "missing remote-rebased-local-stale signal: $output"
# Row 78: all green → ci_aggregate=success, ci_failed_names empty.
[[ "$output" == *$'78\tfeat/green\t98765432\t\tCLEAN\tMERGEABLE\tAPPROVED\tsuccess\t0\t0\t\t\tchecks_passed\tmerge_when_other_gates_clear\tci-pass,merge-ready'* ]] || \
  fail "missing green signal row: $output"
[[ "$output" == *"deploy-gate-external-wait"* ]] || fail "missing deploy-gate-external-wait signal: $output"

json_output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  PR_SIGNAL_BASE_FETCH=0 \
  bash "$SANITIZED_ROOT/scripts/pr_block_signals.sh" "$TEST_TMP/config.sh" --json
)

printf '%s' "$json_output" | jq -e '
  (map(select(.pr == "77"))[0].signals | index("remote-rebased-local-stale") and index("auto-merge-armed")) and
  ((map(select(.pr == "77"))[0].signals | index("needs-rebase")) | not) and
  (map(select(.pr == "78"))[0].signals | index("ci-pass") and index("merge-ready")) and
  (map(select(.pr == "79"))[0].signals | index("needs-rebase")) and
  ((map(select(.pr == "79"))[0].signals | index("remote-rebased-local-stale")) | not) and
  (map(select(.pr == "80"))[0].ci_status == "pending") and
  (map(select(.pr == "80"))[0].ci_pending == 1) and
  (map(select(.pr == "80"))[0].ci_pending_urls == ["https://example.test/checks/deploy-80"]) and
  (map(select(.pr == "81"))[0].ci_status == "pending") and
  (map(select(.pr == "81"))[0].ci_pending == 2) and
  ((map(select(.pr == "81"))[0].ci_pending_urls | sort) == ["https://example.test/checks/lint-81","https://example.test/checks/unit-81"]) and
  (map(select(.pr == "81"))[0].ci_actionable_state == "checks_pending") and
  (map(select(.pr == "81"))[0].next_action == "wait_for_checks") and
  (map(select(.pr == "82"))[0].ci_status == "unknown") and
  (map(select(.pr == "82"))[0].ci_actionable_state == "required_context_missing") and
  (map(select(.pr == "82"))[0].next_action == "record_blocker_issue_with_required_context") and
  (map(select(.pr == "82"))[0].ci_required_contexts == ["ci/protected"]) and
  (map(select(.pr == "82"))[0].ci_changed_paths == ["scripts/ci.sh"]) and
  (map(select(.pr == "83"))[0].ci_actionable_state == "checks_missing_due_path_filter") and
  (map(select(.pr == "83"))[0].next_action == "apply_no_check_policy_or_confirm_branch_protection") and
  (map(select(.pr == "84"))[0].ci_actionable_state == "workflow_not_triggered") and
  (map(select(.pr == "84"))[0].next_action == "rerun_or_trigger_workflow")
' >/dev/null \
  || fail "unexpected JSON output: $json_output"

no_workflow_json_output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  GH_ACTIVE_WORKFLOWS=0 \
  PR_SIGNAL_BASE_FETCH=0 \
  bash "$SANITIZED_ROOT/scripts/pr_block_signals.sh" "$TEST_TMP/config.sh" --json
)

printf '%s' "$no_workflow_json_output" | jq -e '
  (map(select(.pr == "84"))[0].ci_actionable_state == "no_checks_expected") and
  (map(select(.pr == "84"))[0].next_action == "no_ci_action_required")
' >/dev/null \
  || fail "unexpected no-workflow JSON output: $no_workflow_json_output"

printf 'ok - pr_block_signals reports silent merge blockers and green PRs\n'
