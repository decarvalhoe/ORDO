#!/usr/bin/env bats
# tests/ordo_provider_adapter.bats — forge-neutral provider adapter (#811).
#
# Covers lib/ordo_provider_adapter.sh + the github (mocked gh) and fake
# backends:
#   - registry, op list, selection knob, stub adapters (forgejo/gitlab -> 6);
#   - pass-through: github output == the fake fixtures generated from the
#     same mocked payloads (so the two backends agree byte for byte);
#   - the gh invocations map 1:1 onto today's call sites (fields, flags);
#   - mutation policy: gate audit lines, idempotency ledger under state_dir,
#     bodies by file, the double-gated `mutate` escape hatch;
#   - the fake adapter works with no gh on PATH (#816's proof pattern);
#   - the conformance suite (tests/ordo_provider_conformance.bash) for both.

bats_require_minimum_version 1.5.0

load './helpers.bash'

setup() {
  setup_orch_test
  export GH_FIXTURES="$TK/tests/fixtures/adapters/github"
  export FAKE_FIXTURES="$TK/tests/fixtures/adapters/fake"
  export ORDO_FAKE_ADAPTER_DIR="$BATS_TEST_TMPDIR/fake"
  export GH_MOCK_LOG="$BATS_TEST_TMPDIR/gh.log"
  export GH_MOCK_FIXTURES="$GH_FIXTURES"
  export GH_MOCK_FAIL_FILE="$BATS_TEST_TMPDIR/gh.fail"
  export ORDO_FORGE_REPO="acme/widgets"
  unset ORCH_EXTERNAL_PR_MUTATIONS ORDO_PROVIDER_ADAPTER GH_REPO
  cp -R "$FAKE_FIXTURES" "$ORDO_FAKE_ADAPTER_DIR"
  cp "$GH_FIXTURES/mock_gh.sh" "$TEST_BIN_DIR/gh"
  chmod +x "$TEST_BIN_DIR/gh"
  # audit_log.sh gives the gate its audit() sink (PROJECT is set by setup_orch_test).
  # shellcheck disable=SC1090
  source "$TK/lib/audit_log.sh"
  set +e
  # shellcheck disable=SC1090
  source "$TK/lib/ordo_provider_adapter.sh"
  # shellcheck disable=SC1090
  source "$TK/tests/ordo_provider_conformance.bash"
}

# --- conformance harness hooks ---------------------------------------------
conformance_backend_setup() {
  export ORDO_FORGE_REPO="acme/widgets"
  rm -f "$GH_MOCK_FAIL_FILE"
}

conformance_inject_failure() {
  case "$ORDO_PROVIDER_ADAPTER" in
    github)
      case "$1" in
        retryable) printf '1\nHTTP 502: Bad Gateway (https://api.github.com/graphql)\n' > "$GH_MOCK_FAIL_FILE" ;;
        *) printf '4\nTo get started with GitHub CLI, please run:  gh auth login\n' > "$GH_MOCK_FAIL_FILE" ;;
      esac
      printf '12\n'
      ;;
    fake)
      # error fixtures shipped under tests/fixtures/adapters/fake/pr_get/
      case "$1" in retryable) printf '502\n' ;; *) printf '401\n' ;; esac
      ;;
  esac
}

conformance_mutation_count() {
  case "$ORDO_PROVIDER_ADAPTER" in
    github) grep -cE '^(pr|issue) (merge|create|comment|edit|close|reopen|ready|review)' "$GH_MOCK_LOG" 2>/dev/null || true ;;
    fake) if [[ -f "$ORDO_FAKE_ADAPTER_DIR/mutations.jsonl" ]]; then wc -l < "$ORDO_FAKE_ADAPTER_DIR/mutations.jsonl" | tr -d ' '; else printf '0\n'; fi ;;
  esac
}

run_conformance() {
  export ORDO_PROVIDER_ADAPTER="$1"
  conformance_backend_setup
  run ordo_provider_conformance_run "$2"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

assert_error() {
  local code="$1" module="${2:-provider_adapter}"
  [ "$(printf '%s\n' "$stderr" | grep -c .)" -eq 1 ]
  [ "$(printf '%s' "$stderr" | jq -r '.error.code')" = "$code" ]
  [ "$(printf '%s' "$stderr" | jq -r '.error.module')" = "$module" ]
  printf '%s' "$stderr" | jq -e '.error.details.retryable | type == "boolean"' >/dev/null
  [ -z "$output" ]
}

# --- registry and selection ---------------------------------------------------

@test "ops list the twenty generic provider operations (#811)" {
  run ordo_provider_adapter_ops
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | wc -l)" -eq 20 ]
  [ "$(printf '%s' "$output" | tr '\n' ' ' | sed 's/ $//')" = "auth_status repo_get issue_get issue_list issue_create issue_edit issue_comment issue_labels pr_get pr_list pr_create pr_edit pr_ready pr_merge pr_files checks_get review_list run_list run_get mutate" ]
  run ordo_provider_adapter_mutating_ops
  [ "$(printf '%s' "$output" | tr '\n' ' ' | sed 's/ $//')" = "issue_create issue_edit issue_comment issue_labels pr_create pr_edit pr_ready pr_merge mutate" ]
}

@test "registry names github forgejo gitlab fake; github is the default adapter (#811)" {
  run ordo_provider_adapter_names
  [ "$(printf '%s' "$output" | tr '\n' ' ' | sed 's/ $//')" = "github forgejo gitlab fake" ]
  [ "$(ordo_provider_adapter_name)" = "github" ]
  [ "$(ordo_provider_adapter_status github)" = "implemented" ]
  [ "$(ordo_provider_adapter_status fake)" = "implemented" ]
  [ "$(ordo_provider_adapter_status forgejo)" = "stub:#815" ]
  [ "$(ordo_provider_adapter_status gitlab)" = "stub:#815" ]
}

@test "forgejo and gitlab stubs return provider_not_available (exit 6) naming #815 for every op (#811, #815)" {
  local adapter op
  for adapter in forgejo gitlab; do
    export ORDO_PROVIDER_ADAPTER="$adapter"
    for op in $ORDO_PROVIDER_ADAPTER_OPS; do
      case "$op" in
        auth_status|repo_get|issue_list|pr_list|run_list) run --separate-stderr ordo_provider "$op" ;;
        issue_create) run --separate-stderr ordo_provider issue_create --title t -k k ;;
        pr_create) run --separate-stderr ordo_provider pr_create --title t --head h -k k ;;
        mutate) run --separate-stderr ordo_provider mutate --scope pr_review -k k -- x ;;
        *) run --separate-stderr ordo_provider "$op" 12 -k k ;;
      esac
      [ "$status" -eq 6 ] || { echo "$adapter $op: status $status: $stderr"; return 1; }
      assert_error provider_not_available
      [ "$(printf '%s' "$stderr" | jq -r '.error.details.implemented_by')" = "#815" ]
      [ "$(printf '%s' "$stderr" | jq -r '.error.details.adapter')" = "$adapter" ]
      [ "$(printf '%s' "$stderr" | jq -r '.error.details.retryable')" = "false" ]
    done
  done
  # stubs never touch the ledger or the backend
  [ ! -f "$(ordo_provider_adapter_ledger_file)" ]
  [ ! -f "$GH_MOCK_LOG" ]
}

@test "unknown adapter, unknown op and missing repo are usage errors (exit 2) (#811)" {
  ORDO_PROVIDER_ADAPTER=bitbucket run --separate-stderr ordo_provider pr_get 12
  [ "$status" -eq 2 ]
  assert_error bad_argument
  run --separate-stderr ordo_provider pr_fetch 12
  [ "$status" -eq 2 ]
  assert_error unknown_command
  unset ORDO_FORGE_REPO
  run --separate-stderr ordo_provider pr_get 12
  [ "$status" -eq 2 ]
  assert_error usage
  [ "$(printf '%s' "$stderr" | jq -r '.error.details.missing')" = "repo" ]
  # GH_REPO is honoured as the legacy fallback
  GH_REPO=acme/widgets run ordo_provider pr_get 12
  [ "$status" -eq 0 ]
}

# --- pass-through: github (mocked gh) == fake fixtures --------------------------

@test "every read op yields the same normalised payload from github (mocked gh) and fake (#811)" {
  local spec op fixture github_out fake_out
  while IFS='|' read -r spec fixture; do
    [ -n "$spec" ] || continue
    # shellcheck disable=SC2086
    ORDO_PROVIDER_ADAPTER=github run ordo_provider $spec
    [ "$status" -eq 0 ] || { echo "github $spec: $output"; return 1; }
    github_out=$(printf '%s' "$output" | jq -S 'del(.op, .adapter, .repo)')
    # shellcheck disable=SC2086
    ORDO_PROVIDER_ADAPTER=fake run ordo_provider $spec
    [ "$status" -eq 0 ] || { echo "fake $spec: $output"; return 1; }
    fake_out=$(printf '%s' "$output" | jq -S 'del(.op, .adapter, .repo)')
    op=${spec%% *}
    [ "$github_out" = "$fake_out" ] || { echo "$spec differs between github and fake"; diff <(echo "$github_out") <(echo "$fake_out"); return 1; }
    if [ -n "$fixture" ]; then
      [ "$github_out" = "$(jq -S . "$FAKE_FIXTURES/$fixture")" ] || { echo "$spec differs from fixture $fixture"; return 1; }
    fi
    printf '%s' "$github_out" | jq -e --arg op "$op" 'type == "object"' >/dev/null
  done <<'EOF'
repo_get|repo_get/default.json
issue_get 7 --with comments|issue_get/7.json
pr_get 12|pr_get/12.json
pr_get 13|pr_get/13.json
pr_get 14|pr_get/14.json
pr_files 12|pr_files/12.json
checks_get 12|checks_get/12.json
review_list 12|review_list/12.json
run_get 100 --with log_failed|run_get/100.json
issue_list --state all --limit 50|
pr_list --state all --limit 50|
run_list --limit 50|
issue_list --limit 2 --page 2|
pr_list --limit 2 --page 2|
pr_list --state merged|
run_list --branch main|
EOF
}

@test "github read ops issue the same gh invocations as today's call sites (#811, #816)" {
  export ORDO_PROVIDER_ADAPTER=github
  ordo_provider pr_get 12 >/dev/null
  ordo_provider issue_get 7 >/dev/null
  ordo_provider pr_files 12 >/dev/null
  ordo_provider checks_get 12 >/dev/null
  ordo_provider review_list 12 >/dev/null
  ordo_provider run_list --branch main --limit 20 >/dev/null
  ordo_provider run_get 100 >/dev/null
  ordo_provider repo_get >/dev/null
  ordo_provider auth_status >/dev/null
  ordo_provider pr_list --state merged --base main --search "closes #7" --limit 5 >/dev/null
  run cat "$GH_MOCK_LOG"
  [ "${lines[0]}" = "pr view 12 --repo acme/widgets --json number,title,state,isDraft,headRefName,headRefOid,baseRefName,url,mergeable,mergeStateStatus,author,labels,assignees,reviewDecision,autoMergeRequest,createdAt,updatedAt,mergedAt,closedAt,mergeCommit,body,changedFiles" ]
  [ "${lines[1]}" = "issue view 7 --repo acme/widgets --json number,title,state,labels,assignees,url,body,author,createdAt,updatedAt,closedAt,milestone,closedByPullRequestsReferences" ]
  [ "${lines[2]}" = "pr view 12 --repo acme/widgets --json number,files,changedFiles" ]
  [ "${lines[3]}" = "pr view 12 --repo acme/widgets --json number,headRefOid,statusCheckRollup" ]
  [ "${lines[4]}" = "pr view 12 --repo acme/widgets --json number,reviewDecision,reviews" ]
  [ "${lines[5]}" = "run list --repo acme/widgets --json databaseId,number,name,workflowName,displayTitle,status,conclusion,headSha,headBranch,url,createdAt,updatedAt,event --limit 21 --branch main" ]
  [ "${lines[6]}" = "run view 100 --repo acme/widgets --json databaseId,number,name,workflowName,displayTitle,status,conclusion,headSha,headBranch,url,createdAt,updatedAt,event,jobs" ]
  [ "${lines[7]}" = "repo view acme/widgets --json name,owner,nameWithOwner,defaultBranchRef,url,isPrivate,viewerPermission,description" ]
  [ "${lines[8]}" = "auth status" ]
  [ "${lines[9]}" = "pr list --repo acme/widgets --json number,title,state,isDraft,headRefName,headRefOid,baseRefName,url,mergeable,mergeStateStatus,author,labels,assignees,reviewDecision,autoMergeRequest,createdAt,updatedAt,mergedAt,closedAt,mergeCommit,body,changedFiles --state merged --limit 6 --base main --search closes #7" ]
}

@test "github auth_status reports not-authenticated (exit 0) and a missing gh is missing_dependency (exit 6) (#811, #816)" {
  export ORDO_PROVIDER_ADAPTER=github
  GH_MOCK_AUTH_FAIL=1 run ordo_provider auth_status
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.authenticated')" = "false" ]
  [ "$(printf '%s' "$output" | jq -r '.forge')" = "github" ]
  local empty_bin="$BATS_TEST_TMPDIR/empty-bin"
  mkdir -p "$empty_bin"
  ln -s "$(command -v jq)" "$empty_bin/jq"
  for tool in cat tr grep sed head tail awk mktemp rm date od paste wc sort uniq find sha256sum cp mkdir dirname basename timeout; do
    ln -sf "$(command -v "$tool")" "$empty_bin/$tool" 2>/dev/null || true
  done
  PATH="$empty_bin" run --separate-stderr ordo_provider auth_status
  [ "$status" -eq 6 ]
  assert_error missing_dependency
  PATH="$empty_bin" run --separate-stderr ordo_provider pr_get 12
  [ "$status" -eq 6 ]
}

@test "github errors are classified: not_found=4, conflict=5, transient retryable, auth not retryable, token masked (#811)" {
  export ORDO_PROVIDER_ADAPTER=github
  run --separate-stderr ordo_provider pr_get 999
  [ "$status" -eq 4 ]
  assert_error not_found
  printf '1\nX Pull request #12 is not mergeable: the merge commit cannot be cleanly created.\n' > "$GH_MOCK_FAIL_FILE"
  ORCH_EXTERNAL_PR_MUTATIONS=all run --separate-stderr ordo_provider pr_merge 12 -k k1
  [ "$status" -eq 5 ]
  assert_error conflict
  printf '1\nPost "https://api.github.com/graphql": dial tcp: i/o timeout\n' > "$GH_MOCK_FAIL_FILE"
  run --separate-stderr ordo_provider pr_get 12
  [ "$status" -eq 1 ]
  assert_error provider_error
  [ "$(printf '%s' "$stderr" | jq -r '.error.details.retryable')" = "true" ]
  [ "$(printf '%s' "$stderr" | jq -r '.error.details.category')" = "transient" ]
  printf '1\nHTTP 401: Bad credentials, token ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 rejected\n' > "$GH_MOCK_FAIL_FILE"
  run --separate-stderr ordo_provider pr_get 12
  [ "$status" -eq 1 ]
  [ "$(printf '%s' "$stderr" | jq -r '.error.details.retryable')" = "false" ]
  [ "$(printf '%s' "$stderr" | jq -r '.error.details.category')" = "auth" ]
  [[ "$stderr" != *"ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"* ]]
  [[ "$stderr" == *"[REDACTED]"* ]]
}

# --- mutation policy -----------------------------------------------------------

@test "github mutations go through external_pr_mutation_run: refused by default, audited, allowed via ORCH_EXTERNAL_PR_MUTATIONS (#811)" {
  export ORDO_PROVIDER_ADAPTER=github
  run --separate-stderr ordo_provider pr_merge 12 --idempotency-key m1
  [ "$status" -eq 3 ]
  assert_error policy_refused
  [ "$(printf '%s' "$stderr" | jq -r '.error.details.scope')" = "pr_merge" ]
  [ "$(printf '%s' "$stderr" | jq -r '.error.details.authorize_via')" = "ORCH_EXTERNAL_PR_MUTATIONS" ]
  [ ! -f "$GH_MOCK_LOG" ]
  grep -q 'EXTERNAL_PR_MUTATION action=pr_merge mode=refused context=provider_adapter:github:pr_merge:acme/widgets#12' "$ORCH_LOG_DIR/$PROJECT.log"
  ORCH_EXTERNAL_PR_MUTATIONS=pr_merge run --separate-stderr ordo_provider pr_merge 12 --idempotency-key m1 --method rebase --admin
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.details.replayed')" = "false" ]
  [ "$(printf '%s' "$output" | jq -r '.result.merged')" = "true" ]
  [ "$(printf '%s' "$output" | jq -r '.result.method')" = "rebase" ]
  [ "$(cat "$GH_MOCK_LOG")" = "pr merge 12 --repo acme/widgets --rebase --admin" ]
  grep -q 'EXTERNAL_PR_MUTATION action=pr_merge mode=allowed' "$ORCH_LOG_DIR/$PROJECT.log"
}

@test "the idempotency ledger lives under state_dir and a replayed key never re-executes (#811)" {
  export ORDO_PROVIDER_ADAPTER=github
  local ledger
  ledger=$(ordo_provider_adapter_ledger_file)
  [ "$ledger" = "$(state_dir)/ordo-provider-idempotency.jsonl" ]
  ORCH_EXTERNAL_PR_MUTATIONS=all run ordo_provider issue_comment 7 --body "hello" --idempotency-key c1
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$ledger" | tr -d ' ')" -eq 1 ]
  [ "$(jq -r '.idempotency_key' "$ledger")" = "c1" ]
  [ "$(jq -r '.scope' "$ledger")" = "issue_comment" ]
  printf '%s' "$output" | jq -e '.details.recorded_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T")' >/dev/null
  # replay with the policy closed again: no gh call, same result, replayed=true
  run ordo_provider issue_comment 7 --body "hello" --idempotency-key c1
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.details.replayed')" = "true" ]
  [ "$(printf '%s' "$output" | jq -r '.result.url')" = "https://github.com/acme/widgets/issues/7#issuecomment-99" ]
  [ "$(grep -c 'issue comment' "$GH_MOCK_LOG")" -eq 1 ]
  [ "$(wc -l < "$ledger" | tr -d ' ')" -eq 1 ]
  # a failed mutation is not recorded, so a retry with the same key executes
  printf '1\nHTTP 502: Bad Gateway\n' > "$GH_MOCK_FAIL_FILE"
  ORCH_EXTERNAL_PR_MUTATIONS=all run --separate-stderr ordo_provider issue_comment 7 --body "again" --idempotency-key c2
  [ "$status" -eq 1 ]
  [ "$(wc -l < "$ledger" | tr -d ' ')" -eq 1 ]
  rm -f "$GH_MOCK_FAIL_FILE"
  ORCH_EXTERNAL_PR_MUTATIONS=all run ordo_provider issue_comment 7 --body "again" --idempotency-key c2
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.details.replayed')" = "false" ]
  [ "$(wc -l < "$ledger" | tr -d ' ')" -eq 2 ]
}

@test "bodies travel by --body-file, edits narrow their scope, and closing an issue is issue_close (#811)" {
  export ORDO_PROVIDER_ADAPTER=github ORCH_EXTERNAL_PR_MUTATIONS=all
  run ordo_provider issue_create --title "Child" --body $'line one\n`code` $(danger)\n' --label ready --assignee fleet-001 -k b1
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.result.number')" = "1001" ]
  grep -qE '^issue create --repo acme/widgets --title Child --body-file /.* --label ready --assignee fleet-001$' "$GH_MOCK_LOG"
  run ! grep -q -- '--body line' "$GH_MOCK_LOG"
  run ordo_provider issue_labels 7 --add ready --remove blocked -k b2
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.details.scope')" = "issue_labels" ]
  grep -q '^issue edit 7 --repo acme/widgets --add-label ready --remove-label blocked$' "$GH_MOCK_LOG"
  run ordo_provider pr_edit 12 --add-assignee fleet-002 -k b3
  [ "$(printf '%s' "$output" | jq -r '.details.scope')" = "pr_assignees" ]
  run ordo_provider pr_edit 12 --title "new" -k b4
  [ "$(printf '%s' "$output" | jq -r '.details.scope')" = "pr_edit" ]
  run ordo_provider issue_edit 7 --state closed --reason completed -k b5
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.details.scope')" = "issue_close" ]
  [ "$(printf '%s' "$output" | jq -r '.result.state')" = "closed" ]
  grep -q '^issue close 7 --repo acme/widgets --reason completed$' "$GH_MOCK_LOG"
  ORCH_EXTERNAL_PR_MUTATIONS=issue_edit run --separate-stderr ordo_provider issue_edit 7 --state closed -k b6
  [ "$status" -eq 3 ]
  run ordo_provider pr_create --title T --head feat/x --base main --draft -k b7
  [ "$(printf '%s' "$output" | jq -r '.details.scope')" = "pr_state" ]
  [ "$(printf '%s' "$output" | jq -r '.result.number')" = "1002" ]
  run ordo_provider pr_ready 13 -k b8
  [ "$(printf '%s' "$output" | jq -r '.result.draft')" = "false" ]
  run ordo_provider pr_merge 15 --disable-auto -k b9
  [ "$(printf '%s' "$output" | jq -r '.result.action')" = "auto_merge_disabled" ]
  grep -q '^pr merge 15 --repo acme/widgets --disable-auto$' "$GH_MOCK_LOG"
}

@test "mutate is an escape hatch that is gated twice: generic scope, then gh-argument classification (#811, #816)" {
  export ORDO_PROVIDER_ADAPTER=github
  ORCH_EXTERNAL_PR_MUTATIONS=pr_review run ordo_provider mutate --scope pr_review -k e1 -- pr review 12 --approve --repo acme/widgets
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.result.args | join(" ")')" = "pr review 12 --approve --repo acme/widgets" ]
  grep -q '^pr review 12 --approve --repo acme/widgets$' "$GH_MOCK_LOG"
  # scope says review, args say merge: external_pr_mutation_run refuses (80 -> 3)
  ORCH_EXTERNAL_PR_MUTATIONS=pr_review run --separate-stderr ordo_provider mutate --scope pr_review -k e2 -- pr merge 12 --squash --repo acme/widgets
  [ "$status" -eq 3 ]
  assert_error policy_refused
  run ! grep -q '^pr merge' "$GH_MOCK_LOG"
  ORCH_EXTERNAL_PR_MUTATIONS=all run --separate-stderr ordo_provider mutate --scope not_a_scope -k e3 -- pr review 12
  [ "$status" -eq 2 ]
  assert_error bad_argument
}

@test "fake adapter serves fixtures, records mutations and needs no gh on PATH (#811, #816)" {
  export ORDO_PROVIDER_ADAPTER=fake
  rm -f "$TEST_BIN_DIR/gh"
  local empty_bin="$BATS_TEST_TMPDIR/empty-bin"
  mkdir -p "$empty_bin"
  for tool in jq cat tr grep sed head tail awk mktemp rm date od paste wc sort uniq find sha256sum cp mkdir dirname basename mv ls; do
    ln -sf "$(command -v "$tool")" "$empty_bin/$tool" 2>/dev/null || true
  done
  export PATH="$empty_bin"
  run ordo_provider pr_get 12
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.state')" = "open" ]
  ORCH_EXTERNAL_PR_MUTATIONS=all run ordo_provider pr_merge 12 -k f1
  [ "$status" -eq 0 ]
  [ "$(jq -r '.op' "$ORDO_FAKE_ADAPTER_DIR/mutations.jsonl")" = "pr_merge" ]
  [ "$(jq -r '.idempotency_key' "$ORDO_FAKE_ADAPTER_DIR/mutations.jsonl")" = "f1" ]
  # the fake reflects the mutation on subsequent reads
  run ordo_provider pr_get 12
  [ "$(printf '%s' "$output" | jq -r '.state')" = "merged" ]
  ORCH_EXTERNAL_PR_MUTATIONS=all run --separate-stderr ordo_provider pr_merge 12 -k f2
  [ "$status" -eq 5 ]
  assert_error conflict
  ORCH_EXTERNAL_PR_MUTATIONS=all run ordo_provider issue_create --title "New" --label ready -k f3
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.result.number')" = "1001" ]
  [ "$(wc -l < "$ORDO_FAKE_ADAPTER_DIR/mutations.jsonl" | tr -d ' ')" -eq 2 ]
  unset ORDO_FAKE_ADAPTER_DIR
  run --separate-stderr ordo_provider pr_get 12
  [ "$status" -eq 2 ]
  assert_error bad_argument
}

@test "forge knobs: ORDO_FORGE_TOKEN_FILE is read by helper only and never appears in outputs; ORDO_FORGE_URL sets GH_HOST (#811, #815)" {
  local token_file="$BATS_TEST_TMPDIR/token"
  printf 'ghp_SECRETSECRETSECRETSECRETSECRET1234\n' > "$token_file"
  export ORDO_FORGE_TOKEN_FILE="$token_file"
  [ "$(ordo_provider_adapter_token)" = "ghp_SECRETSECRETSECRETSECRETSECRET1234" ]
  ORDO_FORGE_TOKEN_FILE=/nonexistent run ordo_provider_adapter_token
  [ "$status" -eq 4 ]
  export ORDO_PROVIDER_ADAPTER=github
  run --separate-stderr ordo_provider pr_get 999
  [[ "$output$stderr" != *"ghp_SECRET"* ]]
  ORDO_FORGE_URL="https://ghe.example.org/api/v3" run bash -c 'source "$TK/lib/ordo_provider_adapter.sh"; ordo_provider auth_status >/dev/null; printf "%s\n" "${GH_HOST:-}"'
  [ "$output" = "ghe.example.org" ]
  grep -rq 'ghp_SECRET' "$ORCH_LOG_DIR" && return 1
  true
}

# --- conformance suite: github (mocked gh) and fake ----------------------------

@test "conformance[github]: auth_status" { run_conformance github auth_status; }
@test "conformance[github]: repo_get" { run_conformance github repo_get; }
@test "conformance[github]: issue_get" { run_conformance github issue_get; }
@test "conformance[github]: issue_list_pagination" { run_conformance github issue_list_pagination; }
@test "conformance[github]: pr_get" { run_conformance github pr_get; }
@test "conformance[github]: pr_list_pagination" { run_conformance github pr_list_pagination; }
@test "conformance[github]: pr_files" { run_conformance github pr_files; }
@test "conformance[github]: checks_get" { run_conformance github checks_get; }
@test "conformance[github]: review_list" { run_conformance github review_list; }
@test "conformance[github]: runs" { run_conformance github runs; }
@test "conformance[github]: not_found => exit 4" { run_conformance github not_found; }
@test "conformance[github]: refused mutation => exit 3" { run_conformance github mutation_refused; }
@test "conformance[github]: mutation requires --idempotency-key" { run_conformance github mutation_requires_key; }
@test "conformance[github]: idempotent replay" { run_conformance github mutation_idempotent_replay; }
@test "conformance[github]: retryable classification" { run_conformance github retryable_classification; }
@test "conformance[github]: forge-neutral output" { run_conformance github forge_neutral_output; }

@test "conformance[fake]: auth_status" { run_conformance fake auth_status; }
@test "conformance[fake]: repo_get" { run_conformance fake repo_get; }
@test "conformance[fake]: issue_get" { run_conformance fake issue_get; }
@test "conformance[fake]: issue_list_pagination" { run_conformance fake issue_list_pagination; }
@test "conformance[fake]: pr_get" { run_conformance fake pr_get; }
@test "conformance[fake]: pr_list_pagination" { run_conformance fake pr_list_pagination; }
@test "conformance[fake]: pr_files" { run_conformance fake pr_files; }
@test "conformance[fake]: checks_get" { run_conformance fake checks_get; }
@test "conformance[fake]: review_list" { run_conformance fake review_list; }
@test "conformance[fake]: runs" { run_conformance fake runs; }
@test "conformance[fake]: not_found => exit 4" { run_conformance fake not_found; }
@test "conformance[fake]: refused mutation => exit 3" { run_conformance fake mutation_refused; }
@test "conformance[fake]: mutation requires --idempotency-key" { run_conformance fake mutation_requires_key; }
@test "conformance[fake]: idempotent replay" { run_conformance fake mutation_idempotent_replay; }
@test "conformance[fake]: retryable classification" { run_conformance fake retryable_classification; }
@test "conformance[fake]: forge-neutral output" { run_conformance fake forge_neutral_output; }

@test "the conformance scenario list is stable so #815 can iterate over it" {
  run ordo_provider_conformance_scenarios
  [ "$(printf '%s\n' "$output" | wc -l)" -eq 16 ]
  local s
  for s in $ORDO_PROVIDER_CONFORMANCE_SCENARIOS; do
    declare -F "conformance_scenario_$s" >/dev/null
  done
}
