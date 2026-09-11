#!/usr/bin/env bats
# tests/ordo_lib_fake_provider.bats — #816 proof: the migrated lib/ call
# sites run end to end against the fake provider adapter with NO `gh`
# binary on PATH.
#
# PATH is rebuilt from symlinks to every executable of the current PATH
# except `gh`, so a stray direct call would fail with "command not found"
# instead of being served by a mock. Fixtures come from
# tests/fixtures/adapters/fake/ (repo acme/widgets, PR 12, issue 7, run 100),
# copied per test and adjusted where a scenario needs a green rollup.

bats_require_minimum_version 1.5.0

load './helpers.bash'

setup() {
  setup_orch_test
  export ORDO_PROVIDER_ADAPTER=fake
  export ORDO_FAKE_ADAPTER_DIR="$BATS_TEST_TMPDIR/fake"
  export ORDO_FORGE_REPO="acme/widgets"
  export GH_REPO="acme/widgets"
  export GH_CONFIG_DIR="$BATS_TEST_TMPDIR/gh"
  unset ORCH_EXTERNAL_PR_MUTATIONS GH_TOKEN GITHUB_TOKEN ORDO_PROVIDER_IDEMPOTENCY_KEY
  cp -R "$TK/tests/fixtures/adapters/fake" "$ORDO_FAKE_ADAPTER_DIR"
  export NOGH_PATH
  NOGH_PATH=$(path_without_gh)
}

# Build a PATH directory holding every executable reachable today except gh.
path_without_gh() {
  local dir="$BATS_TEST_TMPDIR/nogh-bin" entry exe name
  mkdir -p "$dir"
  local IFS=:
  for entry in $PATH; do
    [ -d "$entry" ] || continue
    for exe in "$entry"/*; do
      name=${exe##*/}
      [ "$name" = gh ] && continue
      [ -e "$dir/$name" ] && continue
      [ -x "$exe" ] && ln -s "$exe" "$dir/$name" 2>/dev/null
    done
  done
  printf '%s\n' "$dir"
}

green_checks_fixture() {
  # PR 12's shipped rollup has a failing check; give it an all-green one.
  jq -c '.checks = [.checks[] | select(.name == "shellcheck")] | .summary = {"total":1,"passed":1,"failed":0,"pending":0,"state":"pass"}' \
    "$ORDO_FAKE_ADAPTER_DIR/checks_get/12.json" > "$ORDO_FAKE_ADAPTER_DIR/checks_get/12.tmp"
  mv "$ORDO_FAKE_ADAPTER_DIR/checks_get/12.tmp" "$ORDO_FAKE_ADAPTER_DIR/checks_get/12.json"
}

write_merge_config() {
  cat > "$BATS_TEST_TMPDIR/merge.config.sh" <<CFG
#!/usr/bin/env bash
PROJECT="$PROJECT"
GH_REPO="acme/widgets"
GH_CONFIG_DIR="$GH_CONFIG_DIR"
DEFAULT_BRANCH="main"
AGENT_WORKDIR_TEMPLATE="$BATS_TEST_TMPDIR/work/%s"
PR_MERGE_CI_INTERVAL_SEC=1
PR_MERGE_CI_TIMEOUT_SEC=3
PR_MERGE_POST_CLEANUP=0
CFG
}

run_pr_merge() {
  PATH="$NOGH_PATH" ORCH_LOG_DIR="$ORCH_LOG_DIR" ORCH_STATE_BASE="$ORCH_STATE_BASE" \
    run bash "$TK/lib/pr_merge.sh" "$BATS_TEST_TMPDIR/merge.config.sh" 12 "$@"
}

@test "the proof PATH really has no gh (#816)" {
  PATH="$NOGH_PATH" run bash -c 'command -v gh'
  [ "$status" -ne 0 ]
  PATH="$NOGH_PATH" run bash -c 'command -v jq && command -v bash && command -v sed'
  [ "$status" -eq 0 ]
}

@test "pr_merge.sh merges through the fake adapter with no gh on PATH, idempotently (#816)" {
  green_checks_fixture
  write_merge_config
  export ORCH_EXTERNAL_PR_MUTATIONS="pr_merge"
  run_pr_merge
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"PR #12 merged (--squash, head=000000000000 checks=shellcheck=SUCCESS)"* ]] || { echo "$output"; false; }
  # The mutation was recorded by the fake backend, once, with the derived key.
  [ "$(wc -l < "$ORDO_FAKE_ADAPTER_DIR/mutations.jsonl" | tr -d ' ')" -eq 1 ]
  [ "$(jq -r '.op' "$ORDO_FAKE_ADAPTER_DIR/mutations.jsonl")" = "pr_merge" ]
  [ "$(jq -r '.number' "$ORDO_FAKE_ADAPTER_DIR/mutations.jsonl")" = "12" ]
  [ "$(jq -r '.idempotency_key' "$ORDO_FAKE_ADAPTER_DIR/mutations.jsonl")" = "pr_merge:acme/widgets#12:000000000000000000000000000000000000000c" ]
  [ "$(jq -r '.result.method' "$ORDO_FAKE_ADAPTER_DIR/mutations.jsonl")" = "squash" ]
  # The ledger lives under the project's state dir.
  local ledger="$ORCH_STATE_BASE/$PROJECT/ordo-provider-idempotency.jsonl"
  [ -f "$ledger" ]
  [ "$(jq -r '.op' "$ledger")" = "pr_merge" ]
  # The fake flipped the PR to merged: a re-run abandons the poll (exit 8)
  # and never mutates again.
  run_pr_merge
  [ "$status" -eq 8 ]
  [[ "$output" == *"state=MERGED mid-poll"* ]]
  [ "$(wc -l < "$ORDO_FAKE_ADAPTER_DIR/mutations.jsonl" | tr -d ' ')" -eq 1 ]
}

@test "pr_merge.sh refuses to merge when ORCH_EXTERNAL_PR_MUTATIONS lacks pr_merge (#816)" {
  green_checks_fixture
  write_merge_config
  run_pr_merge
  [ "$status" -eq 4 ]
  [[ "$output" == *"MERGE REFUSED — external mutation policy (scope=pr_merge"* ]] || { echo "$output"; false; }
  [[ "$output" == *"reason=policy-refused"* ]]
  [[ "$output" == *"authorize via ORCH_EXTERNAL_PR_MUTATIONS"* ]]
  [ ! -f "$ORDO_FAKE_ADAPTER_DIR/mutations.jsonl" ]
  [ "$(jq -r '.state' "$ORDO_FAKE_ADAPTER_DIR/pr_get/12.json")" = "open" ]
}

@test "pr_merge.sh refuses a failing rollup from the fake adapter before any mutation (#816)" {
  write_merge_config
  export ORCH_EXTERNAL_PR_MUTATIONS="pr_merge"
  run_pr_merge
  [ "$status" -eq 2 ]
  [[ "$output" == *"CI GATE FAILED"* ]]
  [[ "$output" == *"bats=FAILURE"* ]]
  [[ "$output" == *"head=000000000000"* ]]
  [ ! -f "$ORDO_FAKE_ADAPTER_DIR/mutations.jsonl" ]
}

@test "governance_check reads checks, head and files from the fake adapter (#816)" {
  PATH="$NOGH_PATH" run bash -c "
    source '$TK/lib/governance_check.sh'
    gov_pr_check_status acme/widgets 12; echo
    gov_pr_head_oid acme/widgets 12
    gov_pr_check_evidence acme/widgets 12
    gov_pr_scope_kind acme/widgets 12; echo
    gov_pr_changed_paths acme/widgets 12
    if gov_pr_rollup_is_empty acme/widgets 12; then echo empty; else echo not-empty; fi
  "
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "${lines[0]}" = "fail" ]
  [ "${lines[1]}" = "000000000000000000000000000000000000000c" ]
  [ "${lines[2]}" = "000000000000000000000000000000000000000c|fail|shellcheck=SUCCESS;bats=FAILURE;docs-gate=IN_PROGRESS;deploy/preview=SUCCESS" ]
  [ "${lines[3]}" = "code" ]
  [ "${lines[4]}" = "lib/fetcher.sh" ]
  [ "${lines[5]}" = "tests/test_fetcher.sh" ]
  [ "${lines[6]}" = "not-empty" ]
}

@test "ci_external_blockers selects failed jobs through run_get on the fake adapter (#816)" {
  PATH="$NOGH_PATH" run bash -c "
    source '$TK/lib/ci_external_blockers.sh'
    # The fake has no check_annotations fixture for job 2 here: stub the row
    # reader to prove the run_get job selection on its own.
    ci_external_blocker_annotation_rows() { printf 'failure\tgithub_actions_billing_job_start\tJob was not started\tspending limit reached\n'; }
    ci_external_blocker_run_rows acme/widgets 100
  "
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$output" = $'2\tbats\tfailure\tgithub_actions_billing_job_start\tJob was not started\tspending limit reached' ]
}

@test "ci_external_blockers reads check annotations through the adapter and yields nothing when a forge has none (#816, #818)" {
  PATH="$NOGH_PATH" run bash -c "
    source '$TK/lib/ci_external_blockers.sh'
    ci_external_blocker_annotation_rows acme/widgets 77
  "
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  # A billing-style annotation on the fake is matched by the pattern.
  mkdir -p "$ORDO_FAKE_ADAPTER_DIR/check_annotations"
  printf '%s\n' '[{"check_id":78,"check_name":"build","check_conclusion":"failure","path":"","line":null,"end_line":null,"level":"failure","title":"Job was not started","message":"spending limit needs to be increased"}]' \
    > "$ORDO_FAKE_ADAPTER_DIR/check_annotations/check_78.json"
  PATH="$NOGH_PATH" run bash -c "
    source '$TK/lib/ci_external_blockers.sh'
    ci_external_blocker_annotation_rows acme/widgets 78
  "
  [ "$status" -eq 0 ]
  [ "$output" = $'failure\tgithub_actions_billing_job_start\tJob was not started\tspending limit needs to be increased' ]
}

@test "governance_check branch-protection helpers read branch_protection_get on the fake adapter (#818)" {
  PATH="$NOGH_PATH" run bash -c "
    source '$TK/lib/governance_check.sh'
    gov_required_checks acme/widgets main; echo
    gov_branch_protected acme/widgets main && echo protected
    gov_pr_review_required acme/widgets main && echo review-required
    gov_branch_protected acme/widgets develop || echo develop-open
    gov_pr_review_required acme/widgets develop || echo develop-no-review
  "
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "${lines[0]}" = "bats shellcheck " ]
  [ "${lines[1]}" = "protected" ]
  [ "${lines[2]}" = "review-required" ]
  [ "${lines[3]}" = "develop-open" ]
  [ "${lines[4]}" = "develop-no-review" ]
}

@test "gh_pr_files_batch_fetch batches through pr_files_batch on the fake adapter, no gh (#818)" {
  PATH="$NOGH_PATH" run bash -c "
    source '$TK/lib/gh_pr_files_batch.sh'
    gh_pr_files_batch_fetch acme/widgets 12 999 13
  "
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "${lines[0]}" = $'12\tlib/fetcher.sh' ]
  [ "${lines[1]}" = $'12\ttests/test_fetcher.sh' ]
  [ "${#lines[@]}" -eq 2 ]
}

@test "env_diagnostics reports the active forge and counts through the fake adapter (#816)" {
  PATH="$NOGH_PATH" run bash -c "
    source '$TK/lib/env_diagnostics.sh'
    env_diag_github_auth
    env_diag_open_issues_prs acme/widgets
  "
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"gh.adapter=fake"* ]]
  [[ "$output" == *"gh.forge=fake"* ]]
  [[ "$output" == *"gh.status=authenticated"* ]]
  [[ "$output" == *"gh.login=octo-bot"* ]]
  [[ "$output" == *"gh.host=fake.invalid"* ]]
  [[ "$output" == *"gh.repo=acme/widgets"* ]]
  [[ "$output" == *"gh.default_branch=main"* ]]
  [[ "$output" == *"gh.issues_open=4"* ]]
  [[ "$output" == *"gh.prs_open_default_base=2"* ]]
  [[ "$output" == *"gh.prs_open_non_default_base=1"* ]]
}

@test "recovery_context_pr_status projects the neutral PR shape back to the legacy line (#816)" {
  PATH="$NOGH_PATH" run bash -c "
    source '$TK/lib/recovery_context.sh'
    recovery_context_pr_status 12 acme/widgets
    recovery_context_pr_status 999 acme/widgets
  "
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "${lines[0]}" = "pr_status mergeable=MERGEABLE mergeStateStatus=CLEAN state=OPEN updatedAt=2026-09-10T12:00:00Z" ]
  [ "${lines[1]}" = "pr_status mergeable=unknown mergeStateStatus=unknown state=unknown updatedAt=" ]
}

@test "autonomous_pr_ops keeps its gh pr view vocabulary on top of the fake adapter (#816)" {
  PATH="$NOGH_PATH" run bash -c "
    source '$TK/lib/audit_log.sh'
    source '$TK/lib/autonomous_pr_ops.sh'
    auto_pr_ops_pr_field acme/widgets 12 '.mergeStateStatus'
    auto_pr_ops_pr_field acme/widgets 12 '.mergeable'
    auto_pr_ops_pr_field acme/widgets 12 '.isDraft'
    auto_pr_ops_pr_field acme/widgets 12 '.reviewDecision'
    auto_pr_ops_pr_field acme/widgets 12 '.labels[0].name'
    auto_pr_ops_pr_field acme/widgets 12 '.files[1].path'
    auto_pr_ops_pr_field acme/widgets 12 '.statusCheckRollup[1].conclusion'
    auto_pr_ops_pr_field acme/widgets 12 '.baseRefName'
  "
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "${lines[0]}" = "CLEAN" ]
  [ "${lines[1]}" = "MERGEABLE" ]
  [ "${lines[2]}" = "false" ]
  [ "${lines[3]}" = "APPROVED" ]
  [ "${lines[4]}" = "wave-7" ]
  [ "${lines[5]}" = "tests/test_fetcher.sh" ]
  [ "${lines[6]}" = "FAILURE" ]
  [ "${lines[7]}" = "main" ]
}

@test "blocker_issue_registry searches and mutates issues through the fake adapter (#816)" {
  export ORCH_EXTERNAL_PR_MUTATIONS="issue_close,issue_labels,issue_reopen"
  PATH="$NOGH_PATH" run bash -c "
    source '$TK/lib/blocker_issue_registry.sh'
    blocker_issue_search_json acme/widgets 'Issue 7' | jq -c '[.[] | {number, state}]'
    blocker_issue_gh issue close 7 --repo acme/widgets --reason completed >/dev/null
    blocker_issue_gh issue edit 7 --repo acme/widgets --add-label resolved >/dev/null
    blocker_issue_gh issue reopen 7 --repo acme/widgets >/dev/null
    blocker_issue_gh issue delete 7 --repo acme/widgets 2>/dev/null; echo \"unsupported=\$?\"
  "
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "${lines[0]}" = '[{"number":7,"state":"OPEN"},{"number":8,"state":"OPEN"},{"number":9,"state":"CLOSED"},{"number":10,"state":"OPEN"},{"number":11,"state":"OPEN"}]' ]
  [ "${lines[1]}" = "unsupported=2" ]
  [ "$(jq -r '.op' "$ORDO_FAKE_ADAPTER_DIR/mutations.jsonl" | paste -sd, -)" = "issue_edit,issue_labels,issue_edit" ]
  [ "$(jq -r '.idempotency_key' "$ORDO_FAKE_ADAPTER_DIR/mutations.jsonl" | paste -sd, -)" = "blocker_issue:close:acme/widgets#7,blocker_issue:label:resolved:acme/widgets#7,blocker_issue:reopen:acme/widgets#7" ]
  [ "$(jq -r '.labels | index("resolved")' "$ORDO_FAKE_ADAPTER_DIR/issue_get/7.json")" != "null" ]
}

@test "github_identity guard reads the active login through the fake adapter (#816)" {
  PATH="$NOGH_PATH" run bash -c "
    source '$TK/lib/github_identity.sh'
    orch_github_active_login
    ORCH_EXPECTED_GH_LOGIN=octo-bot orch_github_identity_guard '' unit-match; echo \"match=\$?\"
    ORCH_EXPECTED_GH_LOGIN=someone-else orch_github_identity_guard '' unit-mismatch 2>/dev/null; echo \"mismatch=\$?\"
  "
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "${lines[0]}" = "octo-bot" ]
  [ "${lines[1]}" = "match=0" ]
  [ "${lines[2]}" = "mismatch=78" ]
}

@test "gh_body_helpers post bodies by file through the fake adapter, idempotently (#816)" {
  export ORCH_EXTERNAL_PR_MUTATIONS="issue_comment,issue_create"
  # The fake backend composes its issue_create result from an optional
  # template fixture; without one, lib/ordo_provider_adapter_fake.sh's
  # _ordo_provider_fake_load returns success with an empty document (its
  # `local rc=$?` after `if ! ...` reads 0) and the op fails on
  # `--argjson ''`. Ship the template the fixture layout documents.
  mkdir -p "$ORDO_FAKE_ADAPTER_DIR/issue_create"
  printf '{}\n' > "$ORDO_FAKE_ADAPTER_DIR/issue_create/default.json"
  # shellcheck disable=SC2016 # literal backticks and $(...) are the point
  local body='Body with `backticks`, $(no expansion) and "quotes"'
  PATH="$NOGH_PATH" run bash -c "
    source '$TK/lib/gh_body_helpers.sh'
    printf '%s' '$body' | gh_issue_comment_body_file 7 --repo acme/widgets
    printf '%s' '$body' | gh_issue_comment_body_file 7 --repo acme/widgets
    printf 'new issue body' | gh_issue_create_body_file --repo acme/widgets --title 'created via helper' --label bug
  "
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "${lines[0]}" = "https://fake.invalid/acme/widgets/issues/7#comment" ]
  # Second identical comment replayed from the ledger: same URL, no new mutation.
  [ "${lines[1]}" = "https://fake.invalid/acme/widgets/issues/7#comment" ]
  [[ "${lines[2]}" == https://fake.invalid/acme/widgets/issues/* ]]
  [ "$(wc -l < "$ORDO_FAKE_ADAPTER_DIR/mutations.jsonl" | tr -d ' ')" -eq 2 ]
  [ "$(jq -r 'select(.op == "issue_comment") | .body' "$ORDO_FAKE_ADAPTER_DIR/mutations.jsonl")" = "$body" ]
  [ "$(jq -r 'select(.op == "issue_create") | .result.title' "$ORDO_FAKE_ADAPTER_DIR/mutations.jsonl")" = "created via helper" ]
  [[ "$(jq -r 'select(.op == "issue_comment") | .idempotency_key' "$ORDO_FAKE_ADAPTER_DIR/mutations.jsonl")" == gh_body:issue_comment:acme/widgets#7:* ]]
  # Refused without the scope: exit 3, nothing recorded.
  PATH="$NOGH_PATH" ORCH_EXTERNAL_PR_MUTATIONS= run bash -c "
    source '$TK/lib/gh_body_helpers.sh'
    printf 'refused' | gh_issue_comment_body_file 8 --repo acme/widgets
  "
  [ "$status" -eq 3 ]
  [ "$(wc -l < "$ORDO_FAKE_ADAPTER_DIR/mutations.jsonl" | tr -d ' ')" -eq 2 ]
}

@test "gh_pr_files_batch reads pr_files_batch off GitHub; a missing pr is skipped, a provider failure is a single-line error (#816, #818)" {
  PATH="$NOGH_PATH" run bash -c "
    source '$TK/lib/gh_pr_files_batch.sh'
    gh_pr_files_batch_fetch acme/widgets 12
  "
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "${lines[0]}" = $'12\tlib/fetcher.sh' ]
  [ "${lines[1]}" = $'12\ttests/test_fetcher.sh' ]
  # 999 does not exist: reported in the batch's "missing", skipped here (like the GraphQL null on github)
  PATH="$NOGH_PATH" run --separate-stderr bash -c "
    source '$TK/lib/gh_pr_files_batch.sh'
    gh_pr_files_batch_fetch acme/widgets 12 999
  "
  [ "$status" -eq 0 ] || { echo "$output $stderr"; false; }
  [ "${#lines[@]}" -eq 2 ]
  # a provider failure (no fixture root) is the documented single-line error
  PATH="$NOGH_PATH" ORDO_FAKE_ADAPTER_DIR= run --separate-stderr bash -c "
    source '$TK/lib/gh_pr_files_batch.sh'
    gh_pr_files_batch_fetch acme/widgets 12
  "
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"gh_pr_files_batch: provider pr_files_batch failed (prs=12)"* ]]
}
