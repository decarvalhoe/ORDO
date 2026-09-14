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

mkdir -p "$SANITIZED_ROOT/lib" "$SANITIZED_ROOT/scripts" "$TEST_TMP/bin" "$TEST_TMP/logs"
TEST_REPO="${TEST_REPO:-example-org/example-repo}"

# pr_merge.sh mutates through the provider adapter (#816): every mutation is
# gated by ORCH_EXTERNAL_PR_MUTATIONS, so the scopes the script needs are
# authorised for the whole suite (the idempotency ledger lives under each
# scenario's ORCH_STATE_BASE). The gh stubs below answer the adapter's argv:
# `pr view N --repo R --json <pr fields>` (pr_get) gets one full PR object,
# `... --json number,headRefOid,statusCheckRollup` (checks_get) the rollup,
# `... --json number,files,changedFiles` (pr_files) the file list.
export ORCH_EXTERNAL_PR_MUTATIONS="pr_ready,pr_merge,pr_review,issue_comment,issue_close,issue_labels"

for rel in \
  scripts/post_merge_cleanup.sh \
  lib/agent_inventory.sh \
  lib/pr_merge.sh \
  lib/audit_log.sh \
  lib/ordo_provider_adapter.sh \
  lib/ordo_provider_adapter_github.sh \
  lib/ordo_provider_adapter_fake.sh \
  lib/ordo_contracts.sh \
  lib/external_mutation_gate.sh \
  lib/autonomous_pr_ops.sh \
  lib/log_bounds.sh \
  lib/config_check.sh \
  lib/config_resolver.sh \
  lib/dry_run.sh \
  lib/gh_body_helpers.sh \
  lib/github_identity.sh \
  lib/governance_check.sh \
  lib/process_safety.sh \
  lib/state_persist.sh
do
  tr -d '\r' < "$ROOT/$rel" > "$SANITIZED_ROOT/$rel"
done

chmod +x "$SANITIZED_ROOT/lib/pr_merge.sh"
chmod +x "$SANITIZED_ROOT/scripts/post_merge_cleanup.sh"

cat > "$TEST_TMP/test.config.sh" <<EOF
#!/usr/bin/env bash
PROJECT="pr-merge-test"
GH_REPO="$TEST_REPO"
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
    printf '%s\n' '{"number":88,"statusCheckRollup":[{"status":"IN_PROGRESS","conclusion":"","name":"ci"}]}'
    ;;
  *"pr view 88"* )
    printf '%s\n' '{"number":88,"state":"CLOSED","isDraft":false,"mergeStateStatus":"UNKNOWN","mergeable":"UNKNOWN"}'
    ;;
  # PR 42: CI passes, plain merge fails because of a missing required check.
  *"pr view 42"*statusCheckRollup* )
    printf '%s\n' '{"number":42,"statusCheckRollup":[{"status":"COMPLETED","conclusion":"SUCCESS","name":"ci"}]}'
    ;;
  *"pr view 42"* )
    printf '%s\n' '{"number":42,"state":"OPEN","isDraft":false,"mergeStateStatus":"BLOCKED","mergeable":"MERGEABLE"}'
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
GH_REPO="$TEST_REPO"
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
  *"pr view 117"*"number,files"* )
    printf '%s\n' '{"number":117,"files":[{"path":"docs/architecture.md"},{"path":"docs/runbook.md"}]}'
    ;;
  *"pr view 117"*statusCheckRollup* )
    printf '%s\n' '{"number":117,"statusCheckRollup":[]}'
    ;;
  *"pr view 117"* )
    printf '%s\n' '{"number":117,"state":"OPEN","isDraft":false,"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE"}'
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
[[ "$output" == *"merged (--squash, no-check policy: scope=docs-only"* ]] \
  || fail "expected merge audit line tagged with scope, got: $output"
[[ "$output" == *"merged (--squash, no-check policy: scope=docs-only"*"checks="* ]] \
  || fail "expected merge audit line to include checks evidence (#370), got: $output"
[[ "$output" != *"CI in_progress, wait"* ]] \
  || fail "no-check policy must skip the wait loop entirely, got: $output"

printf 'ok - pr_merge no-check policy reclassifies empty rollup on docs-only PR\n'

# Scenario E: same PR, same state, but policy disabled. Must time out at the
# 1-second budget instead of merging — proves the policy is truly opt-in and
# does NOT change behaviour when PR_MERGE_NO_CHECK_POLICY is unset.

cat > "$TEST_TMP/test.config.docs-off.sh" <<EOF
#!/usr/bin/env bash
PROJECT="pr-merge-test-docs-off"
GH_REPO="$TEST_REPO"
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
  *"pr view 118"*"number,files"* )
    printf '%s\n' '{"number":118,"files":[{"path":"docs/note.md"},{"path":"lib/pr_merge.sh"}]}'
    ;;
  *"pr view 118"*statusCheckRollup* )
    printf '%s\n' '{"number":118,"statusCheckRollup":[]}'
    ;;
  *"pr view 118"* )
    printf '%s\n' '{"number":118,"state":"OPEN","isDraft":false,"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE"}'
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
# not auto-close closing issue references. The merge helper should write merge evidence to
# the referenced issue and leave it open by default as a validation gate.

cat > "$TEST_TMP/test.config.gitflow.sh" <<EOF
#!/usr/bin/env bash
PROJECT="pr-merge-test-gitflow"
GH_REPO="$TEST_REPO"
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
  *"repo view $TEST_REPO"*defaultBranchRef* )
    printf '%s\n' '{"defaultBranchRef":{"name":"main"}}'
    ;;
  *"pr view 119"*statusCheckRollup* )
    printf '%s\n' '{"number":119,"statusCheckRollup":[{"status":"COMPLETED","conclusion":"SUCCESS","name":"ci"}]}'
    ;;
  *"pr view 119"* )
    # One PR object for every pr_get: open until the merge was requested,
    # then merged with the evidence the reconciliation comment reports.
    if [[ -f "$TEST_TMP/logs/merged-119" ]]; then
      printf '%s\n' '{"number":119,"title":"Fix GitFlow reconcile","body":"Closes #116","url":"https://example.test/pull/119","baseRefName":"develop","headRefName":"feat/gitflow","state":"MERGED","isDraft":false,"mergeStateStatus":"UNKNOWN","mergeable":"UNKNOWN","mergedAt":"2026-05-07T00:00:00Z","mergeCommit":{"oid":"abc123"}}'
    else
      printf '%s\n' '{"number":119,"title":"Fix GitFlow reconcile","body":"Closes #116","url":"https://example.test/pull/119","baseRefName":"develop","headRefName":"feat/gitflow","state":"OPEN","isDraft":false,"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE"}'
    fi
    ;;
  *"pr merge 119"*--squash* )
    : > "$TEST_TMP/logs/merged-119"
    exit 0
    ;;
  *"run list"* )
    # No workflow runs readable on this fixture: the deploy gate must be
    # skipped ("unable to read runs"), as the legacy stub's non-array
    # answer used to do.
    printf '%s\n' 'HTTP 404: workflow runs are not available for this repository' >&2
    exit 1
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
[[ "$output" == *"merged (--squash"*"checks=ci=SUCCESS"* ]] \
  || fail "expected merge audit line with checks evidence (#370), got: $output"
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
GH_REPO="$TEST_REPO"
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
  *"repo view $TEST_REPO"*defaultBranchRef* )
    printf '%s\n' '{"defaultBranchRef":{"name":"main"}}'
    ;;
  *"pr view 120"*statusCheckRollup* )
    printf '%s\n' '{"number":120,"statusCheckRollup":[{"status":"COMPLETED","conclusion":"SUCCESS","name":"ci"}]}'
    ;;
  *"pr view 120"* )
    if [[ -f "$TEST_TMP/logs/merged-120" ]]; then
      printf '%s\n' '{"number":120,"title":"Close reconciled issue","body":"Fixes #120","url":"https://example.test/pull/120","baseRefName":"develop","headRefName":"feat/gitflow-close","state":"MERGED","isDraft":false,"mergeStateStatus":"UNKNOWN","mergeable":"UNKNOWN","mergedAt":"2026-05-07T00:01:00Z","mergeCommit":{"oid":"def456"}}'
    else
      printf '%s\n' '{"number":120,"title":"Close reconciled issue","body":"Fixes #120","url":"https://example.test/pull/120","baseRefName":"develop","headRefName":"feat/gitflow-close","state":"OPEN","isDraft":false,"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE"}'
    fi
    ;;
  *"pr merge 120"*--squash* )
    : > "$TEST_TMP/logs/merged-120"
    exit 0
    ;;
  *"run list"* )
    # No workflow runs readable on this fixture: the deploy gate must be
    # skipped ("unable to read runs"), as the legacy stub's non-array
    # answer used to do.
    printf '%s\n' 'HTTP 404: workflow runs are not available for this repository' >&2
    exit 1
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
grep -q 'reconciliation mode is `close`' "$TEST_TMP/logs/gitflow-close-comment.md" \
  || fail "close mode comment should explain explicit close policy"
grep -q "issue close 120 --repo $TEST_REPO --reason completed" "$TEST_TMP/logs/gh-gitflow-close.log" \
  || fail "close mode must close the referenced issue"

printf 'ok - pr_merge can explicitly close reconciled GitFlow issue refs\n'

# ---------------------------------------------------------------------------
# #370 regression scenarios — block autonomous merges when ORDO policy
# checks are failing, even when GitHub branch protection would accept the
# merge. The autonomous unblock on 2026-05-08 merged ORDO PRs (#284, #334,
# #335, #363, #364, #365, #366) with `validate=FAILURE` because the gate
# decision was not pinned to the current head SHA, the merge audit line did
# not record check evidence, and there was no operator-pause control.
# ---------------------------------------------------------------------------

# Scenario I (#370): PR with validate=FAILURE must NEVER be merged, even
# when `gh pr merge --squash` would accept it. The poll loop must classify
# the rollup as fail and the audit line must include head SHA + check
# names + conclusions + a structured gate reason.

cat > "$TEST_TMP/test.config.failgate.sh" <<EOF
#!/usr/bin/env bash
PROJECT="pr-merge-test-failgate"
GH_REPO="$TEST_REPO"
GH_CONFIG_DIR="$TEST_TMP/gh"
DEFAULT_BRANCH="main"
AGENT_WORKDIR_TEMPLATE="$TEST_TMP/worktrees/%s"
PR_MERGE_CI_INTERVAL_SEC=1
PR_MERGE_CI_TIMEOUT_SEC=1
EOF

cat > "$TEST_TMP/bin/gh.failgate" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "\$*" >> "$TEST_TMP/logs/gh-failgate.log"
case "\$*" in
  *"pr view 142"*statusCheckRollup* )
    printf '%s\n' '{"number":142,"headRefOid":"abc1234567890def0000000000000000000000a","statusCheckRollup":[{"status":"COMPLETED","conclusion":"FAILURE","name":"validate"},{"status":"COMPLETED","conclusion":"SUCCESS","name":"docs-impact-gate"}]}'
    ;;
  *"pr view 142"* )
    printf '%s\n' '{"number":142,"headRefOid":"abc1234567890def0000000000000000000000a","state":"OPEN","isDraft":false,"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE"}'
    ;;
  *"pr merge 142"*--squash* )
    # GitHub branch protection is weaker than ORDO policy: would accept.
    exit 0
    ;;
  * )
    printf '%s\n' '{}'
    ;;
esac
EOF
chmod +x "$TEST_TMP/bin/gh.failgate"
cp "$TEST_TMP/bin/gh.failgate" "$TEST_TMP/bin/gh"

set +e
output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  bash "$SANITIZED_ROOT/lib/pr_merge.sh" "$TEST_TMP/test.config.failgate.sh" 142 2>&1
)
status=$?
set -e

[[ "$status" -eq 2 ]] || fail "expected exit 2 (CI fail) for validate=FAILURE PR, got $status: $output"
[[ "$output" == *"CI GATE FAILED"* ]] || fail "expected CI GATE FAILED audit line, got: $output"
[[ "$output" == *"head=abc123456789"* ]] \
  || fail "expected head SHA in CI gate failure audit (#370), got: $output"
[[ "$output" == *"validate=FAILURE"* ]] \
  || fail "expected failed check name+conclusion in audit (#370), got: $output"
[[ "$output" == *"reason=ci-fail"* ]] \
  || fail "expected structured gate reason in audit (#370), got: $output"
! grep -q 'pr merge 142 .*--squash' "$TEST_TMP/logs/gh-failgate.log" \
  || fail "ORDO policy must refuse merge even when gh pr merge would accept (#370)"

printf 'ok - pr_merge refuses validate=FAILURE PR with head SHA + check evidence in audit (#370)\n'

# Scenario J (#370): poll loop sees a passing rollup at first sample, but a
# late-completing check flips to FAILURE before the final `gh pr merge`
# fires. The poll-loop status alone is not load-bearing — the final
# pre-merge re-verify must catch the fresh FAILURE and refuse with exit 11.

cat > "$TEST_TMP/test.config.stalepoll.sh" <<EOF
#!/usr/bin/env bash
PROJECT="pr-merge-test-stalepoll"
GH_REPO="$TEST_REPO"
GH_CONFIG_DIR="$TEST_TMP/gh"
DEFAULT_BRANCH="main"
AGENT_WORKDIR_TEMPLATE="$TEST_TMP/worktrees/%s"
PR_MERGE_CI_INTERVAL_SEC=1
PR_MERGE_CI_TIMEOUT_SEC=5
EOF

# State-tracking stub: through the provider adapter the poll-loop sample and
# the final pre-merge re-verify are the same checks_get read, so the stub
# counts them — the first rollup read (poll loop) is green, the next one
# (final re-verify) has flipped to FAILURE.
cat > "$TEST_TMP/bin/gh.stalepoll" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "\$*" >> "$TEST_TMP/logs/gh-stalepoll.log"
case "\$*" in
  *"pr view 143"*statusCheckRollup* )
    count_file="$TEST_TMP/logs/stalepoll-checks-count"
    count=0
    [[ -f "\$count_file" ]] && count=\$(cat "\$count_file")
    count=\$((count + 1))
    printf '%s\n' "\$count" > "\$count_file"
    if [[ "\$count" -le 1 ]]; then
      # Poll loop sample: rollup looks green.
      printf '%s\n' '{"number":143,"headRefOid":"feedface0000000000000000000000000000beef","statusCheckRollup":[{"status":"COMPLETED","conclusion":"SUCCESS","name":"validate"}]}'
    else
      # Final pre-merge re-verify: rollup has flipped to FAILURE.
      printf '%s\n' '{"number":143,"headRefOid":"feedface0000000000000000000000000000beef","statusCheckRollup":[{"status":"COMPLETED","conclusion":"FAILURE","name":"validate"}]}'
    fi
    ;;
  *"pr view 143"* )
    printf '%s\n' '{"number":143,"headRefOid":"feedface0000000000000000000000000000beef","state":"OPEN","isDraft":false,"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE"}'
    ;;
  *"pr merge 143"*--squash* )
    # GitHub would accept; ORDO must refuse.
    exit 0
    ;;
  * )
    printf '%s\n' '{}'
    ;;
esac
EOF
chmod +x "$TEST_TMP/bin/gh.stalepoll"
cp "$TEST_TMP/bin/gh.stalepoll" "$TEST_TMP/bin/gh"

set +e
output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  bash "$SANITIZED_ROOT/lib/pr_merge.sh" "$TEST_TMP/test.config.stalepoll.sh" 143 2>&1
)
status=$?
set -e

[[ "$status" -eq 11 ]] || fail "expected exit 11 (final re-verify refused) for stale poll, got $status: $output"
[[ "$output" == *"POLICY GATE REFUSED"* ]] \
  || fail "expected POLICY GATE REFUSED audit on stale poll (#370), got: $output"
[[ "$output" == *"reason=stale-poll-result"* ]] \
  || fail "expected stale-poll-result reason (#370), got: $output"
[[ "$output" == *"validate=FAILURE"* ]] \
  || fail "expected fresh check evidence in audit (#370), got: $output"
[[ "$output" == *"head=feedface0000"* ]] \
  || fail "expected head SHA in final-refuse audit (#370), got: $output"
! grep -q 'pr merge 143 .*--squash' "$TEST_TMP/logs/gh-stalepoll.log" \
  || fail "stale-poll re-verify must refuse before invoking gh pr merge (#370)"

printf 'ok - pr_merge final re-verify catches stale poll result (#370)\n'

# Scenario K (#370): PR_MERGE_HOLD=1 pauses every merge before any gh
# mutation. Used as an operator kill-switch when autonomous merge must be
# paused while dispatch / fix / rebase work continues unaffected.

cat > "$TEST_TMP/test.config.hold.sh" <<EOF
#!/usr/bin/env bash
PROJECT="pr-merge-test-hold"
GH_REPO="$TEST_REPO"
GH_CONFIG_DIR="$TEST_TMP/gh"
DEFAULT_BRANCH="main"
AGENT_WORKDIR_TEMPLATE="$TEST_TMP/worktrees/%s"
PR_MERGE_CI_INTERVAL_SEC=1
PR_MERGE_CI_TIMEOUT_SEC=1
PR_MERGE_HOLD=1
EOF

cat > "$TEST_TMP/bin/gh.hold" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "\$*" >> "$TEST_TMP/logs/gh-hold.log"
# Any call here would be a violation — the kill-switch must short-circuit
# before pr_merge touches gh. Print a marker the assertion can detect.
printf '%s\n' "kill-switch-bypassed" >> "$TEST_TMP/logs/gh-hold-bypass.log"
printf '%s\n' '{}'
EOF
chmod +x "$TEST_TMP/bin/gh.hold"
cp "$TEST_TMP/bin/gh.hold" "$TEST_TMP/bin/gh"

set +e
output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  bash "$SANITIZED_ROOT/lib/pr_merge.sh" "$TEST_TMP/test.config.hold.sh" 144 2>&1
)
status=$?
set -e

[[ "$status" -eq 10 ]] || fail "expected exit 10 (merge-hold) when PR_MERGE_HOLD=1, got $status: $output"
[[ "$output" == *"MERGE HELD"* ]] \
  || fail "expected MERGE HELD audit line (#370), got: $output"
[[ "$output" == *"PR_MERGE_HOLD=1"* ]] \
  || fail "expected PR_MERGE_HOLD source in audit (#370), got: $output"
[ ! -f "$TEST_TMP/logs/gh-hold-bypass.log" ] \
  || fail "merge-hold must short-circuit before any gh mutation (#370)"

printf 'ok - pr_merge respects PR_MERGE_HOLD kill-switch env var (#370)\n'

# Scenario L (#370): autonomous-pr-ops kill-switch state file is the
# canonical operator-facing pause control. When the marker file is present,
# pr_merge must refuse with the same exit code as the env-var hold and name
# the kill-switch path in the audit so the operator can release it.

cat > "$TEST_TMP/test.config.killswitch.sh" <<EOF
#!/usr/bin/env bash
PROJECT="pr-merge-test-killswitch"
GH_REPO="$TEST_REPO"
GH_CONFIG_DIR="$TEST_TMP/gh"
DEFAULT_BRANCH="main"
AGENT_WORKDIR_TEMPLATE="$TEST_TMP/worktrees/%s"
PR_MERGE_CI_INTERVAL_SEC=1
PR_MERGE_CI_TIMEOUT_SEC=1
EOF

KILL_SWITCH_PATH="$TEST_TMP/state/auto_pr_ops_kill_switch.json"
mkdir -p "$(dirname "$KILL_SWITCH_PATH")"
printf '{"engaged_at":"2026-05-08T19:00:00Z","reason":"#370 unblock"}\n' > "$KILL_SWITCH_PATH"

cp "$TEST_TMP/bin/gh.hold" "$TEST_TMP/bin/gh"
rm -f "$TEST_TMP/logs/gh-hold-bypass.log"

set +e
output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  ORCH_AUTO_PR_OPS_KILL_SWITCH_PATH="$KILL_SWITCH_PATH" \
  bash "$SANITIZED_ROOT/lib/pr_merge.sh" "$TEST_TMP/test.config.killswitch.sh" 145 2>&1
)
status=$?
set -e

[[ "$status" -eq 10 ]] || fail "expected exit 10 (merge-hold) when kill-switch file is present, got $status: $output"
[[ "$output" == *"MERGE HELD"* ]] \
  || fail "expected MERGE HELD audit line for kill-switch (#370), got: $output"
[[ "$output" == *"kill-switch="* ]] \
  || fail "expected kill-switch path in audit (#370), got: $output"
[ ! -f "$TEST_TMP/logs/gh-hold-bypass.log" ] \
  || fail "kill-switch must short-circuit before any gh mutation (#370)"

rm -f "$KILL_SWITCH_PATH"

printf 'ok - pr_merge honours autonomous-pr-ops kill-switch state file (#370)\n'

# Scenario M (#370): empty status check rollup is NOT a free pass. Without
# the explicit no-check policy, an empty rollup must be treated as missing
# evidence and refused with exit 11 — never silently merged on the
# assumption "no checks ran = nothing failed". This pairs Scenario E
# (which asserts the legacy timeout behaviour) with explicit evidence
# semantics in the final pre-merge re-verify.

cat > "$TEST_TMP/test.config.empty.sh" <<EOF
#!/usr/bin/env bash
PROJECT="pr-merge-test-empty"
GH_REPO="$TEST_REPO"
GH_CONFIG_DIR="$TEST_TMP/gh"
DEFAULT_BRANCH="main"
AGENT_WORKDIR_TEMPLATE="$TEST_TMP/worktrees/%s"
PR_MERGE_CI_INTERVAL_SEC=1
PR_MERGE_CI_TIMEOUT_SEC=5
EOF

# State-tracking stub: the poll loop's rollup read sees a SUCCESS check (so
# it breaks out with status=pass), then the final pre-merge re-verify (the
# next checks_get read) sees an empty rollup. With no-check policy
# disabled, this must refuse.
cat > "$TEST_TMP/bin/gh.empty" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "\$*" >> "$TEST_TMP/logs/gh-empty.log"
case "\$*" in
  *"pr view 146"*statusCheckRollup* )
    count_file="$TEST_TMP/logs/empty-checks-count"
    count=0
    [[ -f "\$count_file" ]] && count=\$(cat "\$count_file")
    count=\$((count + 1))
    printf '%s\n' "\$count" > "\$count_file"
    if [[ "\$count" -le 1 ]]; then
      printf '%s\n' '{"number":146,"headRefOid":"deadbeef00000000000000000000000000000042","statusCheckRollup":[{"status":"COMPLETED","conclusion":"SUCCESS","name":"ci"}]}'
    else
      # Final pre-merge re-verify sees the rollup as empty — no evidence.
      printf '%s\n' '{"number":146,"headRefOid":"deadbeef00000000000000000000000000000042","statusCheckRollup":[]}'
    fi
    ;;
  *"pr view 146"* )
    printf '%s\n' '{"number":146,"headRefOid":"deadbeef00000000000000000000000000000042","state":"OPEN","isDraft":false,"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE"}'
    ;;
  *"pr merge 146"*--squash* )
    exit 0
    ;;
  * )
    printf '%s\n' '{}'
    ;;
esac
EOF
chmod +x "$TEST_TMP/bin/gh.empty"
cp "$TEST_TMP/bin/gh.empty" "$TEST_TMP/bin/gh"

set +e
output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  bash "$SANITIZED_ROOT/lib/pr_merge.sh" "$TEST_TMP/test.config.empty.sh" 146 2>&1
)
status=$?
set -e

[[ "$status" -eq 11 ]] || fail "expected exit 11 for empty rollup without no-check policy, got $status: $output"
[[ "$output" == *"POLICY GATE REFUSED"* ]] \
  || fail "expected POLICY GATE REFUSED audit for empty rollup (#370), got: $output"
[[ "$output" == *"reason=missing-evidence"* ]] \
  || fail "expected missing-evidence reason (#370), got: $output"
[[ "$output" == *"head=deadbeef0000"* ]] \
  || fail "expected head SHA in empty-rollup refuse audit (#370), got: $output"
! grep -q 'pr merge 146 .*--squash' "$TEST_TMP/logs/gh-empty.log" \
  || fail "empty rollup without no-check policy must refuse before gh pr merge (#370)"

printf 'ok - pr_merge refuses empty rollup without explicit no-check policy evidence (#370)\n'

# Scenario N (#370): head SHA changes between capture and the final
# pre-merge re-verify. A fresh push under a poll loop that watched the
# previous head must not be merged — refuse with exit 11 and an audit line
# that records both SHAs so operators can correlate with git history.

cat > "$TEST_TMP/test.config.headchange.sh" <<EOF
#!/usr/bin/env bash
PROJECT="pr-merge-test-headchange"
GH_REPO="$TEST_REPO"
GH_CONFIG_DIR="$TEST_TMP/gh"
DEFAULT_BRANCH="main"
AGENT_WORKDIR_TEMPLATE="$TEST_TMP/worktrees/%s"
PR_MERGE_CI_INTERVAL_SEC=1
PR_MERGE_CI_TIMEOUT_SEC=5
EOF

cat > "$TEST_TMP/bin/gh.headchange" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "\$*" >> "$TEST_TMP/logs/gh-headchange.log"
case "\$*" in
  *"pr view 147"*statusCheckRollup* )
    # The rollup read (final pre-merge re-verify) sees a NEW head SHA —
    # someone pushed after the initial pr_get capture.
    printf '%s\n' '{"number":147,"headRefOid":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","statusCheckRollup":[{"status":"COMPLETED","conclusion":"SUCCESS","name":"validate"}]}'
    ;;
  *"pr view 147"* )
    # Initial capture (pr_get) — original head SHA.
    printf '%s\n' '{"number":147,"headRefOid":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","state":"OPEN","isDraft":false,"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE"}'
    ;;
  *"pr merge 147"*--squash* )
    exit 0
    ;;
  * )
    printf '%s\n' '{}'
    ;;
esac
EOF
chmod +x "$TEST_TMP/bin/gh.headchange"
cp "$TEST_TMP/bin/gh.headchange" "$TEST_TMP/bin/gh"

set +e
output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  bash "$SANITIZED_ROOT/lib/pr_merge.sh" "$TEST_TMP/test.config.headchange.sh" 147 2>&1
)
status=$?
set -e

[[ "$status" -eq 11 ]] || fail "expected exit 11 for head SHA change, got $status: $output"
[[ "$output" == *"HEAD SHA CHANGED"* ]] \
  || fail "expected HEAD SHA CHANGED audit line (#370), got: $output"
[[ "$output" == *"was=aaaaaaaaaaaa"* ]] \
  || fail "expected previous SHA in audit (#370), got: $output"
[[ "$output" == *"now=bbbbbbbbbbbb"* ]] \
  || fail "expected new SHA in audit (#370), got: $output"
! grep -q 'pr merge 147 .*--squash' "$TEST_TMP/logs/gh-headchange.log" \
  || fail "head-SHA-changed must refuse before gh pr merge (#370)"

printf 'ok - pr_merge refuses merge when head SHA changes between capture and re-verify (#370)\n'

# Scenario O (#578): deploy-triggering merges must serialize behind the live
# deploy gate. After a successful squash merge into a deploy branch, pr_merge
# should keep control until the matching Deploy DEV run observed after the
# merge is completed successfully. This keeps wave/portfolio callers from
# starting the next merge while GitHub Actions is still replacing the pending
# deploy.

cat > "$TEST_TMP/test.config.deploy-gate.sh" <<EOF
#!/usr/bin/env bash
PROJECT="pr-merge-test-deploy-gate"
GH_REPO="$TEST_REPO"
GH_CONFIG_DIR="$TEST_TMP/gh"
DEFAULT_BRANCH="develop"
AGENT_WORKDIR_TEMPLATE="$TEST_TMP/worktrees/%s"
PR_MERGE_CI_INTERVAL_SEC=1
PR_MERGE_CI_TIMEOUT_SEC=5
PR_MERGE_DEPLOY_GATE=1
PR_MERGE_DEPLOY_GATE_INTERVAL_SEC=1
PR_MERGE_DEPLOY_GATE_TIMEOUT_SEC=5
PR_MERGE_DEPLOY_GATE_WORKFLOW_NAME="Deploy DEV"
EOF

cat > "$TEST_TMP/bin/gh.deploy-gate" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "\$*" >> "$TEST_TMP/logs/gh-deploy-gate.log"
case "\$*" in
  *"pr view 148"*statusCheckRollup* )
    printf '%s\n' '{"number":148,"headRefOid":"cafebabecafebabecafebabecafebabecafebabe","statusCheckRollup":[{"status":"COMPLETED","conclusion":"SUCCESS","name":"validate"}]}'
    ;;
  *"pr view 148"* )
    printf '%s\n' '{"number":148,"headRefOid":"cafebabecafebabecafebabecafebabecafebabe","headRefName":"feat/deploy-train","state":"OPEN","isDraft":false,"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE"}'
    ;;
  *"pr merge 148"*--squash* )
    date -u +'%Y-%m-%dT%H:%M:%SZ' > "$TEST_TMP/logs/deploy-post-created-at"
    exit 0
    ;;
  *"run list"* )
    count_file="$TEST_TMP/logs/deploy-gate-count"
    count=0
    [[ -f "\$count_file" ]] && count=\$(cat "\$count_file")
    count=\$((count + 1))
    printf '%s\n' "\$count" > "\$count_file"
    pre_created_at="2026-05-10T10:00:00Z"
    post_created_at=\$(cat "$TEST_TMP/logs/deploy-post-created-at" 2>/dev/null || date -u +'%Y-%m-%dT%H:%M:%SZ')
    if [[ "\$count" -eq 1 ]]; then
      printf '[{"databaseId":25622233539,"name":"Deploy DEV","workflowName":"Deploy DEV","status":"in_progress","conclusion":null,"headSha":"cafebabecafebabecafebabecafebabecafebabe","createdAt":"%s","url":"https://example.invalid/runs/25622233539"}]\n' "\$pre_created_at"
    elif [[ "\$count" -eq 2 ]]; then
      printf '[{"databaseId":25622233539,"name":"Deploy DEV","workflowName":"Deploy DEV","status":"completed","conclusion":"success","headSha":"cafebabecafebabecafebabecafebabecafebabe","createdAt":"%s","url":"https://example.invalid/runs/25622233539"}]\n' "\$pre_created_at"
    elif [[ "\$count" -eq 3 ]]; then
      printf '[{"databaseId":25622233540,"name":"Deploy DEV","workflowName":"Deploy DEV","status":"in_progress","conclusion":null,"headSha":"cafebabecafebabecafebabecafebabecafebabe","createdAt":"%s","url":"https://example.invalid/runs/25622233540"}]\n' "\$post_created_at"
    else
      printf '[{"databaseId":25622233540,"name":"Deploy DEV","workflowName":"Deploy DEV","status":"completed","conclusion":"success","headSha":"cafebabecafebabecafebabecafebabecafebabe","createdAt":"%s","url":"https://example.invalid/runs/25622233540"}]\n' "\$post_created_at"
    fi
    ;;
  * )
    printf '%s\n' '{}'
    ;;
esac
EOF
chmod +x "$TEST_TMP/bin/gh.deploy-gate"
cp "$TEST_TMP/bin/gh.deploy-gate" "$TEST_TMP/bin/gh"

cat > "$TEST_TMP/bin/sleep" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TEST_TMP/logs/sleep-deploy-gate.log"
exit 0
EOF
chmod +x "$TEST_TMP/bin/sleep"

set +e
output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  bash "$SANITIZED_ROOT/lib/pr_merge.sh" "$TEST_TMP/test.config.deploy-gate.sh" 148 2>&1
)
status=$?
set -e

[[ "$status" -eq 0 ]] || fail "expected exit 0 after deploy gate success, got $status: $output"
[[ "$output" == *"deploy gate pending"* ]] \
  || fail "expected pending deploy-gate audit line, got: $output"
[[ "$output" == *"deploy gate complete"* ]] \
  || fail "expected successful deploy-gate completion audit line, got: $output"
[[ "$(cat "$TEST_TMP/logs/deploy-gate-count")" -ge 2 ]] \
  || fail "expected pr_merge to poll Deploy DEV until success"
grep -q '^1$' "$TEST_TMP/logs/sleep-deploy-gate.log" \
  || fail "expected deploy gate wait to sleep between pending and success"

printf 'ok - pr_merge waits for live deploy gate success after deploy-triggering merge (#578)\n'

# Scenario P (#654): once the Deploy DEV gate is green for a merge SHA, the
# downstream DEV Critical Route Smoke workflow_run for that SAME SHA must
# also complete with a safe conclusion before the next merge is released.
# Reproduces the 2026-05-12 RBOK incident: Deploy DEV @ SHA1 succeeded but
# Smoke @ SHA1 was still in_progress (and later failed) — the merge train
# advanced anyway, masking a real route regression. After the fix, the
# gate holds the second merge candidate until smoke for SHA1 completes.

cat > "$TEST_TMP/test.config.smoke-gate.sh" <<EOF
#!/usr/bin/env bash
PROJECT="pr-merge-test-smoke-gate"
GH_REPO="$TEST_REPO"
GH_CONFIG_DIR="$TEST_TMP/gh"
DEFAULT_BRANCH="develop"
AGENT_WORKDIR_TEMPLATE="$TEST_TMP/worktrees/%s"
PR_MERGE_CI_INTERVAL_SEC=1
PR_MERGE_CI_TIMEOUT_SEC=5
PR_MERGE_DEPLOY_GATE=1
PR_MERGE_DEPLOY_GATE_INTERVAL_SEC=1
PR_MERGE_DEPLOY_GATE_TIMEOUT_SEC=10
PR_MERGE_DEPLOY_GATE_WORKFLOW_NAME="Deploy DEV"
PR_MERGE_DEPLOY_GATE_SMOKE_WORKFLOW_NAME="DEV Critical Route Smoke"
PR_MERGE_DEPLOY_GATE_SMOKE_INTERVAL_SEC=1
PR_MERGE_DEPLOY_GATE_SMOKE_TIMEOUT_SEC=10
EOF

cat > "$TEST_TMP/bin/gh.smoke-gate" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "\$*" >> "$TEST_TMP/logs/gh-smoke-gate.log"
case "\$*" in
  *"pr view 149"*statusCheckRollup* )
    printf '%s\n' '{"number":149,"headRefOid":"deadbeefdeadbeefdeadbeefdeadbeefdeadbeef","statusCheckRollup":[{"status":"COMPLETED","conclusion":"SUCCESS","name":"validate"}]}'
    ;;
  *"pr view 149"* )
    printf '%s\n' '{"number":149,"headRefOid":"deadbeefdeadbeefdeadbeefdeadbeefdeadbeef","headRefName":"feat/smoke-train","state":"OPEN","isDraft":false,"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE"}'
    ;;
  *"pr merge 149"*--squash* )
    date -u +'%Y-%m-%dT%H:%M:%SZ' > "$TEST_TMP/logs/smoke-post-created-at"
    exit 0
    ;;
  *"run list"* )
    count_file="$TEST_TMP/logs/smoke-gate-count"
    count=0
    [[ -f "\$count_file" ]] && count=\$(cat "\$count_file")
    count=\$((count + 1))
    printf '%s\n' "\$count" > "\$count_file"
    pre_sha="9430549430549430549430549430549430549430"
    post_sha="8411d738411d738411d738411d738411d738411d7"
    pre_created_at="2026-05-12T04:50:00Z"
    smoke_pre_created_at="2026-05-12T04:52:04Z"
    post_created_at=\$(cat "$TEST_TMP/logs/smoke-post-created-at" 2>/dev/null || date -u +'%Y-%m-%dT%H:%M:%SZ')
    # Sequencing (relative to pr_merge's gh call ordering):
    #   1: pre-merge Deploy DEV — completed/success for pre_sha
    #   2: pre-merge Smoke filtered to pre_sha — in_progress (held)
    #   3: pre-merge Smoke filtered to pre_sha — completed/success (released)
    #   4: post-merge Deploy DEV scoped to post_sha — completed/success
    #   5: post-merge Smoke filtered to post_sha — completed/success
    # All run list responses include the relevant workflow rows; the
    # jq filter inside pr_merge_latest_workflow_run handles selection.
    case "\$count" in
      1)
        printf '[{"databaseId":25713810038,"name":"Deploy DEV","workflowName":"Deploy DEV","status":"completed","conclusion":"success","headSha":"'\$pre_sha'","createdAt":"%s","url":"https://example.invalid/runs/25713810038"}]\n' "\$pre_created_at"
        ;;
      2)
        printf '[{"databaseId":25714150073,"name":"DEV Critical Route Smoke","workflowName":"DEV Critical Route Smoke","status":"in_progress","conclusion":null,"headSha":"'\$pre_sha'","createdAt":"%s","url":"https://example.invalid/runs/25714150073"}]\n' "\$smoke_pre_created_at"
        ;;
      3)
        printf '[{"databaseId":25714150073,"name":"DEV Critical Route Smoke","workflowName":"DEV Critical Route Smoke","status":"completed","conclusion":"success","headSha":"'\$pre_sha'","createdAt":"%s","url":"https://example.invalid/runs/25714150073"}]\n' "\$smoke_pre_created_at"
        ;;
      4)
        printf '[{"databaseId":25714204382,"name":"Deploy DEV","workflowName":"Deploy DEV","status":"completed","conclusion":"success","headSha":"'\$post_sha'","createdAt":"%s","url":"https://example.invalid/runs/25714204382"}]\n' "\$post_created_at"
        ;;
      *)
        printf '[{"databaseId":25714460304,"name":"DEV Critical Route Smoke","workflowName":"DEV Critical Route Smoke","status":"completed","conclusion":"success","headSha":"'\$post_sha'","createdAt":"%s","url":"https://example.invalid/runs/25714460304"}]\n' "\$post_created_at"
        ;;
    esac
    ;;
  * )
    printf '%s\n' '{}'
    ;;
esac
EOF
chmod +x "$TEST_TMP/bin/gh.smoke-gate"
cp "$TEST_TMP/bin/gh.smoke-gate" "$TEST_TMP/bin/gh"

cat > "$TEST_TMP/bin/sleep" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TEST_TMP/logs/sleep-smoke-gate.log"
exit 0
EOF
chmod +x "$TEST_TMP/bin/sleep"

set +e
output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  bash "$SANITIZED_ROOT/lib/pr_merge.sh" "$TEST_TMP/test.config.smoke-gate.sh" 149 2>&1
)
status=$?
set -e

[[ "$status" -eq 0 ]] || fail "expected exit 0 after smoke gate success, got $status: $output"
[[ "$output" == *"deploy gate complete (pre-merge)"* ]] \
  || fail "expected deploy gate to complete before smoke gate, got: $output"
[[ "$output" == *"smoke gate pending (pre-merge)"* ]] \
  || fail "expected pending smoke-gate audit line during the held window, got: $output"
[[ "$output" == *"smoke gate complete (pre-merge)"*"workflow=\"DEV Critical Route Smoke\""* ]] \
  || fail "expected smoke gate completion audit line, got: $output"
[[ "$output" == *"held_pr=#149"* ]] \
  || fail "smoke gate audit must name the held PR (#654), got: $output"
[[ "$output" == *"held_sha=943054943054"* ]] \
  || fail "smoke gate audit must name the held SHA (#654), got: $output"
[[ "$output" == *"release=safe-conclusion"* ]] \
  || fail "smoke gate audit must record the release condition (#654), got: $output"

printf 'ok - pr_merge waits for downstream smoke gate before releasing next merge (#654)\n'

# Scenario Q (#654): failing smoke for the held SHA must refuse the merge,
# not silently release. Demonstrates the "failing" arm of the gate: if the
# critical smoke for the prior merge SHA reports a non-safe conclusion,
# pr_merge exits 12 with held_pr / held_sha / conclusion / release evidence
# so dashboards can name the train block without parsing free-form text.

cat > "$TEST_TMP/test.config.smoke-fail.sh" <<EOF
#!/usr/bin/env bash
PROJECT="pr-merge-test-smoke-fail"
GH_REPO="$TEST_REPO"
GH_CONFIG_DIR="$TEST_TMP/gh"
DEFAULT_BRANCH="develop"
AGENT_WORKDIR_TEMPLATE="$TEST_TMP/worktrees/%s"
PR_MERGE_CI_INTERVAL_SEC=1
PR_MERGE_CI_TIMEOUT_SEC=5
PR_MERGE_DEPLOY_GATE=1
PR_MERGE_DEPLOY_GATE_INTERVAL_SEC=1
PR_MERGE_DEPLOY_GATE_TIMEOUT_SEC=5
PR_MERGE_DEPLOY_GATE_WORKFLOW_NAME="Deploy DEV"
PR_MERGE_DEPLOY_GATE_SMOKE_WORKFLOW_NAME="DEV Critical Route Smoke"
PR_MERGE_DEPLOY_GATE_SMOKE_INTERVAL_SEC=1
PR_MERGE_DEPLOY_GATE_SMOKE_TIMEOUT_SEC=5
EOF

cat > "$TEST_TMP/bin/gh.smoke-fail" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "\$*" >> "$TEST_TMP/logs/gh-smoke-fail.log"
case "\$*" in
  *"pr view 150"*statusCheckRollup* )
    printf '%s\n' '{"number":150,"headRefOid":"feedfacefeedfacefeedfacefeedfacefeedface","statusCheckRollup":[{"status":"COMPLETED","conclusion":"SUCCESS","name":"validate"}]}'
    ;;
  *"pr view 150"* )
    printf '%s\n' '{"number":150,"headRefOid":"feedfacefeedfacefeedfacefeedfacefeedface","headRefName":"feat/smoke-train-fail","state":"OPEN","isDraft":false,"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE"}'
    ;;
  *"pr merge 150"*--squash* )
    printf '%s\n' "MERGE WAS CALLED" > "$TEST_TMP/logs/smoke-fail-merge-called"
    exit 0
    ;;
  *"run list"* )
    count_file="$TEST_TMP/logs/smoke-fail-count"
    count=0
    [[ -f "\$count_file" ]] && count=\$(cat "\$count_file")
    count=\$((count + 1))
    printf '%s\n' "\$count" > "\$count_file"
    pre_sha="9430549430549430549430549430549430549430"
    pre_created_at="2026-05-12T04:50:00Z"
    smoke_created_at="2026-05-12T04:52:04Z"
    case "\$count" in
      1)
        printf '[{"databaseId":25713810038,"name":"Deploy DEV","workflowName":"Deploy DEV","status":"completed","conclusion":"success","headSha":"'\$pre_sha'","createdAt":"%s","url":"https://example.invalid/runs/25713810038"}]\n' "\$pre_created_at"
        ;;
      *)
        printf '[{"databaseId":25714150073,"name":"DEV Critical Route Smoke","workflowName":"DEV Critical Route Smoke","status":"completed","conclusion":"failure","headSha":"'\$pre_sha'","createdAt":"%s","url":"https://example.invalid/runs/25714150073"}]\n' "\$smoke_created_at"
        ;;
    esac
    ;;
  * )
    printf '%s\n' '{}'
    ;;
esac
EOF
chmod +x "$TEST_TMP/bin/gh.smoke-fail"
cp "$TEST_TMP/bin/gh.smoke-fail" "$TEST_TMP/bin/gh"

set +e
output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  bash "$SANITIZED_ROOT/lib/pr_merge.sh" "$TEST_TMP/test.config.smoke-fail.sh" 150 2>&1
)
status=$?
set -e

[[ "$status" -eq 12 ]] || fail "expected exit 12 when smoke for held SHA fails, got $status: $output"
[[ "$output" == *"smoke gate FAILED (pre-merge)"* ]] \
  || fail "expected FAILED smoke gate audit line, got: $output"
[[ "$output" == *"held_pr=#150"* ]] \
  || fail "FAILED smoke gate audit must name held PR (#654), got: $output"
[[ "$output" == *"held_sha=943054943054"* ]] \
  || fail "FAILED smoke gate audit must name held SHA (#654), got: $output"
[[ "$output" == *"conclusion=failure"* ]] \
  || fail "FAILED smoke gate audit must record observed conclusion (#654), got: $output"
[[ "$output" == *"release=blocker"* ]] \
  || fail "FAILED smoke gate audit must record blocker release condition (#654), got: $output"
[[ ! -f "$TEST_TMP/logs/smoke-fail-merge-called" ]] \
  || fail "pr_merge must NOT call gh pr merge when smoke gate refuses (#654), got: $output"

printf 'ok - pr_merge refuses next merge when downstream smoke gate fails for prior SHA (#654)\n'

# Scenario R (#654): dry-run / live-safe gate proof. When --dry-run is set
# alongside the smoke workflow name, pr_merge must announce that it WOULD
# wait for the smoke workflow without invoking any gh mutation. This gives
# operators a non-destructive smoke check before flipping the gate live.

cat > "$TEST_TMP/test.config.smoke-dryrun.sh" <<EOF
#!/usr/bin/env bash
PROJECT="pr-merge-test-smoke-dryrun"
GH_REPO="$TEST_REPO"
GH_CONFIG_DIR="$TEST_TMP/gh"
DEFAULT_BRANCH="develop"
AGENT_WORKDIR_TEMPLATE="$TEST_TMP/worktrees/%s"
PR_MERGE_CI_INTERVAL_SEC=1
PR_MERGE_CI_TIMEOUT_SEC=5
PR_MERGE_DEPLOY_GATE=1
PR_MERGE_DEPLOY_GATE_INTERVAL_SEC=1
PR_MERGE_DEPLOY_GATE_TIMEOUT_SEC=5
PR_MERGE_DEPLOY_GATE_WORKFLOW_NAME="Deploy DEV"
PR_MERGE_DEPLOY_GATE_SMOKE_WORKFLOW_NAME="DEV Critical Route Smoke"
EOF

cat > "$TEST_TMP/bin/gh.smoke-dryrun" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "\$*" >> "$TEST_TMP/logs/gh-smoke-dryrun.log"
case "\$*" in
  *"pr view 151"*statusCheckRollup* )
    printf '%s\n' '{"number":151,"headRefOid":"abcdefabcdefabcdefabcdefabcdefabcdefabcd","statusCheckRollup":[{"status":"COMPLETED","conclusion":"SUCCESS","name":"validate"}]}'
    ;;
  *"pr view 151"* )
    printf '%s\n' '{"number":151,"headRefOid":"abcdefabcdefabcdefabcdefabcdefabcdefabcd","headRefName":"feat/smoke-dryrun","state":"OPEN","isDraft":false,"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE"}'
    ;;
  *"pr merge 151"*--squash* )
    printf '%s\n' "MERGE WAS CALLED" > "$TEST_TMP/logs/smoke-dryrun-merge-called"
    exit 0
    ;;
  *"run list"* )
    printf '[]\n'
    ;;
  * )
    printf '%s\n' '{}'
    ;;
esac
EOF
chmod +x "$TEST_TMP/bin/gh.smoke-dryrun"
cp "$TEST_TMP/bin/gh.smoke-dryrun" "$TEST_TMP/bin/gh"

set +e
output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  bash "$SANITIZED_ROOT/lib/pr_merge.sh" "$TEST_TMP/test.config.smoke-dryrun.sh" 151 --dry-run 2>&1
)
status=$?
set -e

[[ "$status" -eq 0 ]] || fail "expected exit 0 for dry-run smoke gate preview, got $status: $output"
[[ "$output" == *"would wait for DEV Critical Route Smoke on develop"* ]] \
  || fail "expected dry-run note announcing the smoke gate would wait (#654), got: $output"
[[ "$output" == *"would wait for Deploy DEV on develop"* ]] \
  || fail "expected dry-run note announcing the deploy gate would wait (#654), got: $output"
[[ ! -f "$TEST_TMP/logs/smoke-dryrun-merge-called" ]] \
  || fail "dry-run must NOT invoke gh pr merge (#654), got: $output"

printf 'ok - pr_merge dry-run announces the smoke gate without mutating gh (#654)\n'
