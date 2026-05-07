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
  lib/log_bounds.sh \
  lib/config_check.sh \
  lib/config_resolver.sh \
  lib/dry_run.sh \
  lib/gh_body_helpers.sh \
  lib/github_identity.sh \
  lib/governance_check.sh
do
  tr -d '\r' < "$ROOT/$rel" > "$SANITIZED_ROOT/$rel"
done

chmod +x "$SANITIZED_ROOT/lib/pr_merge.sh"

cat > "$TEST_TMP/test.config.sh" <<EOF
#!/usr/bin/env bash
PROJECT="pr-merge-test"
GH_REPO="RBOKproject/ORDO"
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
  # PR 88: closes mid-poll.
  *"pr view 88"*statusCheckRollup* )
    printf '%s\n' '{"statusCheckRollup":[{"status":"IN_PROGRESS","conclusion":"","name":"ci"}]}'
    ;;
  *"pr view 88"*state,mergeStateStatus,mergeable* )
    printf '%s\n' '{"state":"CLOSED","mergeStateStatus":"UNKNOWN","mergeable":"UNKNOWN"}'
    ;;
  *"pr view 88"*mergeStateStatus* )
    printf '%s\n' '{"mergeStateStatus":"UNKNOWN"}'
    ;;
  # PR 42: CI passes, plain merge fails because of a missing required check.
  *"pr view 42"*isDraft* )
    printf '%s\n' '{"isDraft":false}'
    ;;
  *"pr view 42"*statusCheckRollup* )
    printf '%s\n' '{"statusCheckRollup":[{"status":"COMPLETED","conclusion":"SUCCESS","name":"ci"}]}'
    ;;
  *"pr view 42"*state,mergeStateStatus,mergeable* )
    printf '%s\n' '{"state":"OPEN","mergeStateStatus":"BLOCKED","mergeable":"MERGEABLE"}'
    ;;
  *"pr view 42"*mergeStateStatus* )
    printf '%s\n' '{"mergeStateStatus":"BLOCKED"}'
    ;;
  *"pr view 42"*autoMergeRequest* )
    printf '%s\n' '{}'
    ;;
  *"pr merge 42"*--squash* )
    printf '%s\n' 'GraphQL: Required status check "ci" is expected. (mergePullRequest)' >&2
    exit 1
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

# Scenario A: PR closes mid-poll. Exit 8 with the closed-state audit line.
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

# Scenario B: plain merge refused by required status check + --no-admin-fallback.
# Asserts the audit line surfaces the gh stderr text AND the categorized
# refusal reason, instead of swallowing the failure into /dev/null.
set +e
output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  bash "$SANITIZED_ROOT/lib/pr_merge.sh" "$TEST_TMP/test.config.sh" 42 --no-admin-fallback 2>&1
)
status=$?
set -e

[[ "$status" -eq 4 ]] || fail "expected exit 4 for refused merge without admin fallback, got $status: $output"
[[ "$output" == *"MERGE FAILED"* ]] || fail "expected MERGE FAILED audit line, got: $output"
[[ "$output" == *"reason=missing-required-check"* ]] || fail "expected reason=missing-required-check in audit line, got: $output"
[[ "$output" == *"rc=1"* ]] || fail "expected rc=1 in audit line, got: $output"
[[ "$output" == *"Required status check"* ]] || fail "expected gh stderr text surfaced in audit line, got: $output"

printf 'ok - pr_merge surfaces gh stderr and refusal category on plain merge failure\n'

# Scenario C: classify_merge_refusal + truncate_stderr unit coverage on the
# common gh refusal phrases. Extract the helpers from pr_merge.sh and source
# them in isolation so the asserts cannot pass by accident.
{
  sed -n '/^classify_merge_refusal()/,/^}/p' "$SANITIZED_ROOT/lib/pr_merge.sh"
  sed -n '/^truncate_stderr()/,/^}/p' "$SANITIZED_ROOT/lib/pr_merge.sh"
} > "$TEST_TMP/classify_fn.sh"

# shellcheck disable=SC1090
source "$TEST_TMP/classify_fn.sh"

cases=(
  'GraphQL: Required status check "ci" is expected.|missing-required-check'
  'Pull Request is still a draft (mergePullRequest)|draft'
  'GraphQL: At least 1 approving review is required by reviewers with write access.|review-required'
  'Changes requested by a reviewer with write access.|review-required'
  'Required reviewer has not approved.|review-required'
  'protected branch hook declined|branch-protection'
  'Base branch policy prohibits the merge|branch-protection'
  'Resource not accessible by integration|permission-denied'
  'HTTP 403: Forbidden|permission-denied'
  'Pull request is not mergeable: the merge cannot be cleanly created|conflict'
  'Auto-merge is not allowed for this repository|auto-merge-disallowed'
  'This branch must be merged with a linear history|merge-method-disallowed'
  'Squash merging is disabled for this repository|merge-method-disallowed'
  '|unknown'
  'totally unrelated server hiccup|unknown'
)

for entry in "${cases[@]}"; do
  raw=${entry%|*}
  expected=${entry##*|}
  got=$(classify_merge_refusal "$raw")
  [[ "$got" == "$expected" ]] || fail "classify_merge_refusal('$raw') = '$got', expected '$expected'"
done

[[ "$(truncate_stderr '')" == "no stderr captured" ]] || fail "truncate_stderr empty fallback missing"
multi=$(printf 'one\ntwo\tthree\rfour' | tr -d '\0')
got=$(truncate_stderr "$multi")
[[ "$got" == *"one"* && "$got" == *"two"* && "$got" == *"three"* && "$got" == *"four"* ]] \
  || fail "truncate_stderr should preserve fragments separated by single spaces, got: '$got'"
[[ "$got" != *$'\n'* ]] || fail "truncate_stderr must collapse newlines, got: '$got'"

printf 'ok - classify_merge_refusal + truncate_stderr cover known gh refusal phrasings\n'

# Scenario D: risk-based no-check policy (#117).
# A docs-only PR with an empty status check rollup must NOT timeout when
# PR_MERGE_NO_CHECK_POLICY=1; pr_merge should reclassify CI as
# "not-applicable", squash-merge directly, and emit an audit line that names
# the scope so dashboards can distinguish it from a merge that ran the full
# CI gate. PR_MERGE_NO_CHECK_POLICY=0 (default) keeps the legacy behaviour
# and would have timed this scenario out at 1 second — covered by Scenario E.

cat > "$TEST_TMP/test.config.docs.sh" <<EOF
#!/usr/bin/env bash
PROJECT="pr-merge-test-docs"
GH_REPO="RBOKproject/ORDO"
GH_CONFIG_DIR="$TEST_TMP/gh"
DEFAULT_BRANCH="main"
AGENT_WORKDIR_TEMPLATE="$TEST_TMP/worktrees/%s"
PR_MERGE_CI_INTERVAL_SEC=1
PR_MERGE_CI_TIMEOUT_SEC=1
PR_MERGE_NO_CHECK_POLICY=1
EOF

cat > "$TEST_TMP/bin/gh.docs" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "\$*" >> "$TEST_TMP/logs/gh-docs.log"
case "\$*" in
  *"pr view 117"*isDraft* )
    printf '%s\n' '{"isDraft":false}'
    ;;
  *"pr view 117"*files* )
    printf '%s\n' '{"files":[{"path":"docs/architecture.md"},{"path":"docs/runbook.md"}]}'
    ;;
  *"pr view 117"*statusCheckRollup* )
    printf '%s\n' '{"statusCheckRollup":[]}'
    ;;
  *"pr view 117"*state,mergeStateStatus,mergeable* )
    printf '%s\n' '{"state":"OPEN","mergeStateStatus":"CLEAN","mergeable":"MERGEABLE"}'
    ;;
  *"pr view 117"*mergeStateStatus* )
    printf '%s\n' '{"mergeStateStatus":"CLEAN"}'
    ;;
  *"pr view 117"*autoMergeRequest* )
    printf '%s\n' '{}'
    ;;
  *"pr merge 117"*--squash* )
    exit 0
    ;;
  * )
    printf '%s\n' '{}'
    ;;
esac
EOF
chmod +x "$TEST_TMP/bin/gh.docs"

# Swap the gh stub for the docs-aware variant just for this scenario.
cp "$TEST_TMP/bin/gh.docs" "$TEST_TMP/bin/gh"

set +e
output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  bash "$SANITIZED_ROOT/lib/pr_merge.sh" "$TEST_TMP/test.config.docs.sh" 117 2>&1
)
status=$?
set -e

[[ "$status" -eq 0 ]] || fail "expected exit 0 for docs-only no-check policy merge, got $status: $output"
[[ "$output" == *"no-check policy eligible (scope=docs-only)"* ]] \
  || fail "expected no-check policy eligibility audit line, got: $output"
[[ "$output" == *"CI not-applicable"* ]] \
  || fail "expected 'CI not-applicable' audit line, got: $output"
[[ "$output" == *"merged (--squash, no-check policy: scope=docs-only)"* ]] \
  || fail "expected merge audit line tagged with scope, got: $output"
[[ "$output" != *"CI in_progress, wait"* ]] \
  || fail "no-check policy must skip the wait loop entirely, got: $output"

printf 'ok - pr_merge no-check policy reclassifies empty rollup on docs-only PR\n'

# Scenario E: same PR, same state, but policy disabled. Must time out at the
# 1-second budget instead of merging — proves the policy is truly opt-in and
# does NOT change behaviour when PR_MERGE_NO_CHECK_POLICY is unset.

cat > "$TEST_TMP/test.config.docs-off.sh" <<EOF
#!/usr/bin/env bash
PROJECT="pr-merge-test-docs-off"
GH_REPO="RBOKproject/ORDO"
GH_CONFIG_DIR="$TEST_TMP/gh"
DEFAULT_BRANCH="main"
AGENT_WORKDIR_TEMPLATE="$TEST_TMP/worktrees/%s"
PR_MERGE_CI_INTERVAL_SEC=1
PR_MERGE_CI_TIMEOUT_SEC=1
EOF

set +e
output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  bash "$SANITIZED_ROOT/lib/pr_merge.sh" "$TEST_TMP/test.config.docs-off.sh" 117 2>&1
)
status=$?
set -e

[[ "$status" -eq 3 ]] || fail "expected exit 3 (CI timeout) when policy is disabled, got $status: $output"
[[ "$output" == *"CI TIMEOUT"* ]] || fail "expected CI TIMEOUT audit line when policy is disabled, got: $output"
[[ "$output" != *"no-check policy"* ]] \
  || fail "policy must stay silent when disabled, got: $output"

printf 'ok - pr_merge keeps default wait-and-timeout behaviour when no-check policy is unset\n'

# Scenario F: code-touching PR with empty rollup + policy enabled. The policy
# must refuse to fire (scope=code) so we do NOT bypass CI for code changes.

cat > "$TEST_TMP/bin/gh.code" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "\$*" >> "$TEST_TMP/logs/gh-code.log"
case "\$*" in
  *"pr view 118"*isDraft* )
    printf '%s\n' '{"isDraft":false}'
    ;;
  *"pr view 118"*files* )
    printf '%s\n' '{"files":[{"path":"docs/note.md"},{"path":"lib/pr_merge.sh"}]}'
    ;;
  *"pr view 118"*statusCheckRollup* )
    printf '%s\n' '{"statusCheckRollup":[]}'
    ;;
  *"pr view 118"*state,mergeStateStatus,mergeable* )
    printf '%s\n' '{"state":"OPEN","mergeStateStatus":"CLEAN","mergeable":"MERGEABLE"}'
    ;;
  *"pr view 118"*mergeStateStatus* )
    printf '%s\n' '{"mergeStateStatus":"CLEAN"}'
    ;;
  *"pr view 118"*autoMergeRequest* )
    printf '%s\n' '{}'
    ;;
  *"pr merge 118"*--squash* )
    exit 0
    ;;
  * )
    printf '%s\n' '{}'
    ;;
esac
EOF
chmod +x "$TEST_TMP/bin/gh.code"
cp "$TEST_TMP/bin/gh.code" "$TEST_TMP/bin/gh"

set +e
output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  bash "$SANITIZED_ROOT/lib/pr_merge.sh" "$TEST_TMP/test.config.docs.sh" 118 2>&1
)
status=$?
set -e

[[ "$status" -eq 3 ]] || fail "expected exit 3 (CI timeout) for code-touching PR even with policy on, got $status: $output"
[[ "$output" == *"CI TIMEOUT"* ]] \
  || fail "expected CI TIMEOUT audit line for code-touching PR with policy on, got: $output"
[[ "$output" != *"no-check policy eligible"* ]] \
  || fail "policy must NOT fire when scope is code, got: $output"
[[ "$output" != *"merged (--squash, no-check policy"* ]] \
  || fail "policy must NOT bypass CI on code-touching PR, got: $output"

printf 'ok - pr_merge no-check policy refuses to fire when scope includes code\n'

# Scenario G: GitFlow post-merge issue reconciliation (#116).
# If a PR merges into a branch that is not the repository default, GitHub will
# not auto-close closing issue references. ORDO should write merge evidence to
# the referenced issue and leave it open by default as a validation gate.

cat > "$TEST_TMP/test.config.gitflow.sh" <<EOF
#!/usr/bin/env bash
PROJECT="pr-merge-test-gitflow"
GH_REPO="RBOKproject/ORDO"
GH_CONFIG_DIR="$TEST_TMP/gh"
DEFAULT_BRANCH="develop"
AGENT_WORKDIR_TEMPLATE="$TEST_TMP/worktrees/%s"
PR_MERGE_CI_INTERVAL_SEC=1
PR_MERGE_CI_TIMEOUT_SEC=1
PR_MERGE_ISSUE_RECONCILE=1
PR_MERGE_ISSUE_RECONCILE_MODE=gate
EOF

cat > "$TEST_TMP/bin/gh.gitflow" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "\$*" >> "$TEST_TMP/logs/gh-gitflow.log"
case "\$*" in
  *"repo view RBOKproject/ORDO"*defaultBranchRef* )
    printf '%s\n' '{"defaultBranchRef":{"name":"main"}}'
    ;;
  *"pr view 119"*isDraft* )
    printf '%s\n' '{"isDraft":false}'
    ;;
  *"pr view 119"*statusCheckRollup* )
    printf '%s\n' '{"statusCheckRollup":[{"status":"COMPLETED","conclusion":"SUCCESS","name":"ci"}]}'
    ;;
  *"pr view 119"*state,mergeStateStatus,mergeable* )
    printf '%s\n' '{"state":"OPEN","mergeStateStatus":"CLEAN","mergeable":"MERGEABLE"}'
    ;;
  *"pr view 119"*mergeStateStatus* )
    printf '%s\n' '{"mergeStateStatus":"CLEAN"}'
    ;;
  *"pr view 119"*autoMergeRequest* )
    printf '%s\n' '{}'
    ;;
  *"pr view 119"*closingIssuesReferences* )
    printf '%s\n' '{"number":119,"title":"Fix GitFlow reconcile","body":"Closes #116","url":"https://example.test/pull/119","baseRefName":"develop","mergedAt":"2026-05-07T00:00:00Z","mergeCommit":{"oid":"abc123"},"closingIssuesReferences":[{"number":116}]}'
    ;;
  *"pr merge 119"*--squash* )
    exit 0
    ;;
  *"issue comment 116"* )
    body_file=""
    while [[ \$# -gt 0 ]]; do
      case "\$1" in
        --body-file)
          body_file=\$2
          shift 2
          ;;
        *)
          shift
          ;;
      esac
    done
    [[ -n "\$body_file" ]] || exit 99
    cp "\$body_file" "$TEST_TMP/logs/gitflow-comment.md"
    printf '%s\n' '{"url":"https://example.test/issues/116#comment"}'
    ;;
  * )
    printf '%s\n' '{}'
    ;;
esac
EOF
chmod +x "$TEST_TMP/bin/gh.gitflow"
cp "$TEST_TMP/bin/gh.gitflow" "$TEST_TMP/bin/gh"

set +e
output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  bash "$SANITIZED_ROOT/lib/pr_merge.sh" "$TEST_TMP/test.config.gitflow.sh" 119 2>&1
)
status=$?
set -e

[[ "$status" -eq 0 ]] || fail "expected exit 0 for GitFlow merge reconciliation, got $status: $output"
[[ "$output" == *"merged (--squash)"* ]] || fail "expected merge audit line, got: $output"
[[ "$output" == *"issue_reconcile validation_gate issue=#116 base=develop default=main"* ]] \
  || fail "expected validation gate audit line, got: $output"
grep -q 'Merged into: develop' "$TEST_TMP/logs/gitflow-comment.md" \
  || fail "GitFlow comment missing base branch evidence"
grep -q 'Repository default branch: main' "$TEST_TMP/logs/gitflow-comment.md" \
  || fail "GitFlow comment missing repo default branch evidence"
grep -q 'Validation gate recorded' "$TEST_TMP/logs/gitflow-comment.md" \
  || fail "GitFlow comment should record validation gate outcome"
! grep -q 'issue close 116' "$TEST_TMP/logs/gh-gitflow.log" \
  || fail "gate mode must not close the issue"

printf 'ok - pr_merge records validation gate evidence for non-default GitFlow merges\n'

# Scenario H: explicit close mode. Closing remains opt-in, and still posts the
# evidence body first. This uses a keyword reference in the PR body to cover
# text extraction in addition to closingIssuesReferences.

cat > "$TEST_TMP/test.config.gitflow-close.sh" <<EOF
#!/usr/bin/env bash
PROJECT="pr-merge-test-gitflow-close"
GH_REPO="RBOKproject/ORDO"
GH_CONFIG_DIR="$TEST_TMP/gh"
DEFAULT_BRANCH="develop"
AGENT_WORKDIR_TEMPLATE="$TEST_TMP/worktrees/%s"
PR_MERGE_CI_INTERVAL_SEC=1
PR_MERGE_CI_TIMEOUT_SEC=1
PR_MERGE_ISSUE_RECONCILE=1
PR_MERGE_ISSUE_RECONCILE_MODE=close
EOF

cat > "$TEST_TMP/bin/gh.gitflow-close" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "\$*" >> "$TEST_TMP/logs/gh-gitflow-close.log"
case "\$*" in
  *"repo view RBOKproject/ORDO"*defaultBranchRef* )
    printf '%s\n' '{"defaultBranchRef":{"name":"main"}}'
    ;;
  *"pr view 120"*isDraft* )
    printf '%s\n' '{"isDraft":false}'
    ;;
  *"pr view 120"*statusCheckRollup* )
    printf '%s\n' '{"statusCheckRollup":[{"status":"COMPLETED","conclusion":"SUCCESS","name":"ci"}]}'
    ;;
  *"pr view 120"*state,mergeStateStatus,mergeable* )
    printf '%s\n' '{"state":"OPEN","mergeStateStatus":"CLEAN","mergeable":"MERGEABLE"}'
    ;;
  *"pr view 120"*mergeStateStatus* )
    printf '%s\n' '{"mergeStateStatus":"CLEAN"}'
    ;;
  *"pr view 120"*autoMergeRequest* )
    printf '%s\n' '{}'
    ;;
  *"pr view 120"*closingIssuesReferences* )
    printf '%s\n' '{"number":120,"title":"Close reconciled issue","body":"Fixes #120","url":"https://example.test/pull/120","baseRefName":"develop","mergedAt":"2026-05-07T00:01:00Z","mergeCommit":{"oid":"def456"},"closingIssuesReferences":[]}'
    ;;
  *"pr merge 120"*--squash* )
    exit 0
    ;;
  *"issue comment 120"* )
    body_file=""
    while [[ \$# -gt 0 ]]; do
      case "\$1" in
        --body-file)
          body_file=\$2
          shift 2
          ;;
        *)
          shift
          ;;
      esac
    done
    [[ -n "\$body_file" ]] || exit 99
    cp "\$body_file" "$TEST_TMP/logs/gitflow-close-comment.md"
    printf '%s\n' '{"url":"https://example.test/issues/120#comment"}'
    ;;
  *"issue close 120"* )
    printf '%s\n' '{"state":"CLOSED"}'
    ;;
  * )
    printf '%s\n' '{}'
    ;;
esac
EOF
chmod +x "$TEST_TMP/bin/gh.gitflow-close"
cp "$TEST_TMP/bin/gh.gitflow-close" "$TEST_TMP/bin/gh"

set +e
output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  bash "$SANITIZED_ROOT/lib/pr_merge.sh" "$TEST_TMP/test.config.gitflow-close.sh" 120 2>&1
)
status=$?
set -e

[[ "$status" -eq 0 ]] || fail "expected exit 0 for GitFlow close reconciliation, got $status: $output"
[[ "$output" == *"issue_reconcile closed issue=#120 base=develop default=main"* ]] \
  || fail "expected close audit line, got: $output"
# shellcheck disable=SC2016 # backticks are literal markdown in the expected comment body.
grep -q 'Closing this issue because the configured ORDO reconciliation mode is `close`' "$TEST_TMP/logs/gitflow-close-comment.md" \
  || fail "close mode comment should explain explicit close policy"
grep -q 'issue close 120 --repo RBOKproject/ORDO --reason completed' "$TEST_TMP/logs/gh-gitflow-close.log" \
  || fail "close mode must close the referenced issue"

printf 'ok - pr_merge can explicitly close reconciled GitFlow issue refs\n'
