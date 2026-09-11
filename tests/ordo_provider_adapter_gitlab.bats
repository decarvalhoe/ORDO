#!/usr/bin/env bats
# tests/ordo_provider_adapter_gitlab.bats — GitLab provider adapter (#815,
# epic #806) against the python3 stub server serving the recorded fixtures
# of tests/fixtures/adapters/gitlab/. No network, no glab, no gh.
#
#   - registry flip (gitlab is implemented), project-path encoding;
#   - the 16 conformance scenarios of tests/ordo_provider_conformance.bash;
#   - key-set parity of every read op with the github-derived fake fixtures,
#     merge-request vocabulary fully mapped (iid, opened, source/target...);
#   - native REST calls: notes, add_labels/remove_labels, assignee ids,
#     Draft: prefix, merge body, auto-merge cancel, double-gated `mutate`;
#   - pagination from page/per_page + X-Next-Page / X-Total;
#   - error classification: 404=4, 401 auth, 403 refused, 429 rate_limited,
#     5xx retryable, 405/406 conflict=5;
#   - token hygiene after every op, permissive token file => exit 3.

bats_require_minimum_version 1.5.0

load './helpers.bash'
load './ordo_provider_rest_harness'

setup() {
  setup_orch_test
  export REST_FORGE=gitlab
  rest_harness_setup
}

teardown() {
  rest_harness_teardown
}

# --- registry and configuration ------------------------------------------------

@test "gitlab is a registered, implemented adapter and encodes the project path (#815)" {
  [ "$(ordo_provider_adapter_status gitlab)" = "implemented" ]
  run ordo_provider repo_get
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -c '[.full_name, .owner, .name, .default_branch, .private, .permission]')" = '["acme/widgets","acme","widgets","main",true,"write"]' ]
  # the stub percent-decodes the path; the wire carried projects/acme%2Fwidgets
  grep -q 'GET http://127.0.0.1:[0-9]*/api/v4/projects/acme%2Fwidgets ' "$ORDO_PROVIDER_HTTP_LOG"
  ORDO_FORGE_URL="http://127.0.0.1:${STUB_PORT}/api/v4" run ordo_provider repo_get
  [ "$status" -eq 0 ]
  unset ORDO_FORGE_URL
  run --separate-stderr ordo_provider pr_get 12
  [ "$status" -eq 2 ]
  assert_error bad_argument
  _ordo_provider_adapter_load gitlab
  local op
  for op in $ORDO_PROVIDER_ADAPTER_OPS; do
    declare -F "ordo_provider_adapter_gitlab_${op}" >/dev/null || { echo "missing op $op"; return 1; }
  done
}

# --- conformance suite ----------------------------------------------------------

@test "conformance[gitlab]: auth_status" { run_conformance auth_status; }
@test "conformance[gitlab]: repo_get" { run_conformance repo_get; }
@test "conformance[gitlab]: issue_get" { run_conformance issue_get; }
@test "conformance[gitlab]: issue_list_pagination" { run_conformance issue_list_pagination; }
@test "conformance[gitlab]: pr_get" { run_conformance pr_get; }
@test "conformance[gitlab]: pr_list_pagination" { run_conformance pr_list_pagination; }
@test "conformance[gitlab]: pr_files" { run_conformance pr_files; }
@test "conformance[gitlab]: checks_get" { run_conformance checks_get; }
@test "conformance[gitlab]: review_list" { run_conformance review_list; }
@test "conformance[gitlab]: runs" { run_conformance runs; }
@test "conformance[gitlab]: not_found => exit 4" { run_conformance not_found; }
@test "conformance[gitlab]: refused mutation => exit 3" { run_conformance mutation_refused; }
@test "conformance[gitlab]: mutation requires --idempotency-key" { run_conformance mutation_requires_key; }
@test "conformance[gitlab]: idempotent replay" { run_conformance mutation_idempotent_replay; }
@test "conformance[gitlab]: retryable classification" { run_conformance retryable_classification; }
@test "conformance[gitlab]: forge-neutral output" { run_conformance forge_neutral_output; }

# --- normalisation: merge requests in the pr vocabulary ---------------------------

@test "gitlab read ops carry exactly the key set of the github-derived fixtures; merge requests map onto pr (#815)" {
  assert_same_keys "pr_get 12" pr_get/12.json
  assert_same_keys "pr_get 13" pr_get/13.json
  assert_same_keys "pr_get 14" pr_get/14.json
  assert_same_keys "issue_get 7 --with comments" issue_get/7.json
  assert_same_keys "repo_get" repo_get/default.json
  assert_same_keys "pr_files 12" pr_files/12.json
  assert_same_keys "checks_get 12" checks_get/12.json
  assert_same_keys "review_list 12" review_list/12.json
  assert_same_keys "run_get 100 --with log_failed" run_get/100.json
  run ordo_provider pr_list --state all --limit 50
  [ "$(printf '%s' "$output" | jq -c '.items[0]' | json_key_set)" = "$(jq -c '.[0]' "$FAKE_FIXTURES/pr_list/default.json" | json_key_set)" ]
  run ordo_provider issue_list --state all --limit 50
  [ "$(printf '%s' "$output" | jq -c '.items[0]' | json_key_set)" = "$(jq -c '.[0]' "$FAKE_FIXTURES/issue_list/default.json" | json_key_set)" ]
  run ordo_provider run_list --limit 50
  [ "$(printf '%s' "$output" | jq -c '.items[0]' | json_key_set)" = "$(jq -c '.[0]' "$FAKE_FIXTURES/run_list/default.json" | json_key_set)" ]
  # vocabulary mapping
  run ordo_provider pr_get 12
  [ "$(printf '%s' "$output" | jq -c '{number, state, draft, mergeable, merge_state, review_decision, head: .head.ref, sha: .head.sha, base: .base.ref, changed_files, auto_merge}')" = '{"number":12,"state":"open","draft":false,"mergeable":"mergeable","merge_state":"clean","review_decision":"approved","head":"feat/wave-7-12","sha":"000000000000000000000000000000000000000c","base":"main","changed_files":2,"auto_merge":false}' ]
  run ordo_provider pr_get 13
  [ "$(printf '%s' "$output" | jq -c '[.state, .draft, .mergeable, .merge_state, .review_decision]')" = '["open",true,"conflicting","dirty","review_required"]' ]
  run ordo_provider pr_get 14
  [ "$(printf '%s' "$output" | jq -c '[.state, .merged_at, .merge_commit, .mergeable, .merge_state]')" = '["merged","2026-09-09T10:00:00Z","c0ffee0000000000000000000000000000000000","mergeable","clean"]' ]
  run ordo_provider issue_get 7
  [ "$(printf '%s' "$output" | jq -c '[.number, .state, .milestone, .closed_by_prs]')" = '[7,"open","v1.2",[{"number":12,"state":"open"}]]' ]
  run ordo_provider issue_get 7 --with comments
  [ "$(printf '%s' "$output" | jq -c '.comments | map([.author, .body])')" = '[["fleet-001","On it."]]' ]
  [ "$(printf '%s' "$output" | jq -r '.comments[0].url')" = "https://gitlab.example/acme/widgets/-/issues/7#note_1" ]
  # checks: pipeline jobs are check_runs, external statuses are statuses, retried jobs deduplicated by name
  run ordo_provider checks_get 12
  [ "$(printf '%s' "$output" | jq -c '.summary')" = "$(jq -c '.summary' "$FAKE_FIXTURES/checks_get/12.json")" ]
  [ "$(printf '%s' "$output" | jq -r '[.checks[] | .name + ":" + .kind + ":" + (.conclusion // "-")] | join(",")')" = "bats:check_run:failure,deploy/preview:status:success,docs-gate:check_run:-,shellcheck:check_run:success" ]
  # pipelines are runs, jobs carry an empty steps list
  run ordo_provider run_get 100
  [ "$(printf '%s' "$output" | jq -c '[.id, .run_number, .status, .conclusion, .head_branch, .event, (.jobs | length), .jobs[1].conclusion]')" = '[100,50,"completed","failure","feat/wave-7-12","merge_request_event",2,"failure"]' ]
  run ordo_provider review_list 12
  [ "$(printf '%s' "$output" | jq -c '[.decision, (.reviews | map(.author + ":" + .state))]')" = '["approved",["operator:approved","fleet-002:commented"]]' ]
  assert_no_token_leak "$output"
}

# --- native REST calls ----------------------------------------------------------

@test "gitlab mutations map onto the REST API: notes, add/remove labels, assignee ids, Draft: prefix, merge body (#815)" {
  export ORCH_EXTERNAL_PR_MUTATIONS=all
  run ordo_provider issue_create --title "New" --body "b" --label ready --label type:feat --assignee fleet-001 --milestone v1.2 -k m1
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.result.number')" = "1001" ]
  [ "$(rest_requests 'select(.method == "POST" and (.path | endswith("/issues"))) | .body')" = '{"title":"New","description":"b\n","labels":"ready,type:feat","assignee_ids":[2],"milestone_id":3}' ]
  [ "$(rest_requests 'select(.path == "/api/v4/users") | .query.username')" = '"fleet-001"' ]
  run --separate-stderr ordo_provider issue_create --title "New" --assignee nobody -k m1b
  [ "$status" -eq 4 ]
  assert_error not_found
  run ordo_provider issue_labels 7 --add ready --remove blocked -k m2
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.details.scope')" = "issue_labels" ]
  [ "$(rest_requests 'select(.method == "PUT" and (.path | endswith("/issues/7"))) | .body')" = '{"add_labels":"ready","remove_labels":"blocked"}' ]
  run ordo_provider issue_comment 7 --body "hello" -k m3
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.result.url')" = "http://127.0.0.1:${STUB_PORT}/acme/widgets/-/issues/7#note_99" ]
  [ "$(rest_requests 'select(.method == "POST" and (.path | endswith("/issues/7/notes"))) | .body.body')" = '"hello\n"' ]
  run ordo_provider issue_edit 7 --state closed -k m4
  [ "$(printf '%s' "$output" | jq -r '.details.scope')" = "issue_close" ]
  [ "$(rest_requests 'select(.method == "PUT" and (.path | endswith("/issues/7"))) | .body.state_event' | tail -n 1)" = '"close"' ]
  run ordo_provider pr_edit 12 --title "renamed" --base develop --add-assignee fleet-002 -k m5
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.details.scope')" = "pr_edit" ]
  [ "$(rest_requests 'select(.method == "PUT" and (.path | endswith("/merge_requests/12"))) | .body' | tail -n 1)" = '{"title":"renamed","target_branch":"develop","assignee_ids":[2,3]}' ]
  run ordo_provider pr_create --title "T" --head feat/x --draft --label wave-7 -k m6
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -c '.result | [.number, .draft, .head.ref, .base.ref]')" = '[1002,true,"feat/x","main"]' ]
  [ "$(rest_requests 'select(.method == "POST" and (.path | endswith("/merge_requests"))) | .body')" = '{"source_branch":"feat/x","target_branch":"main","title":"Draft: T","description":"","labels":"wave-7"}' ]
  run ordo_provider pr_ready 13 -k m7
  [ "$(printf '%s' "$output" | jq -r '.result.draft')" = "false" ]
  [ "$(rest_requests 'select(.method == "PUT" and (.path | endswith("/merge_requests/13"))) | .body.title')" = '"feat: pr 13"' ]
  run ordo_provider pr_merge 12 --delete-branch -k m8
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -c '.result')" = '{"number":12,"merged":true,"action":"merged","method":"squash","admin":false}' ]
  [ "$(rest_requests 'select(.method == "PUT" and (.path | endswith("/merge_requests/12/merge"))) | .body')" = '{"squash":true,"should_remove_source_branch":true,"merge_when_pipeline_succeeds":false}' ]
  run ordo_provider pr_merge 15 --method merge --auto -k m9
  [ "$(printf '%s' "$output" | jq -r '.result.action')" = "auto_merge_enabled" ]
  [ "$(rest_requests 'select(.method == "PUT" and (.path | endswith("/merge_requests/15/merge"))) | .body')" = '{"squash":false,"should_remove_source_branch":false,"merge_when_pipeline_succeeds":true}' ]
  run ordo_provider pr_merge 15 --disable-auto -k m10
  [ "$(printf '%s' "$output" | jq -r '.result.action')" = "auto_merge_disabled" ]
  [ "$(rest_requests 'select(.path | endswith("/cancel_merge_when_pipeline_succeeds")) | .method')" = '"POST"' ]
  run --separate-stderr ordo_provider pr_merge 14 -k m11
  [ "$status" -eq 5 ]
  assert_error conflict
  [ "$(printf '%s' "$stderr" | jq -r '.error.details.http_status')" = "405" ]
  run --separate-stderr ordo_provider pr_merge 13 -k m12
  [ "$status" -eq 5 ]
  assert_error conflict
  [ "$(printf '%s' "$stderr" | jq -r '.error.details.http_status')" = "406" ]
  [ "$(rest_request_count '.status == 401 or .status == 400')" -eq 0 ]
  assert_no_token_leak "$output" "$stderr"
}

@test "gitlab mutate is a native REST passthrough gated twice (#815)" {
  export ORCH_EXTERNAL_PR_MUTATIONS=pr_review
  run ordo_provider mutate --scope pr_review -k e1 -- --method POST --path projects/acme%2Fwidgets/merge_requests/12/approve
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -c '.result | [.backend, .status, .body.approved]')" = '["rest",201,true]' ]
  local before
  before=$(rest_request_count)
  run --separate-stderr ordo_provider mutate --scope pr_review -k e2 -- --method PUT --path projects/acme%2Fwidgets/merge_requests/12/merge
  [ "$status" -eq 3 ]
  assert_error policy_refused
  [ "$(printf '%s' "$stderr" | jq -r '.error.details.implied_scope')" = "pr_merge" ]
  [ "$(rest_request_count)" -eq "$before" ]
  run --separate-stderr ordo_provider mutate --scope pr_review -k e3 -- --method POST --path "projects/acme%2Fwidgets/merge_requests/12/approve?private_token=x"
  [ "$status" -eq 2 ]
  assert_error bad_argument
  assert_no_token_leak "$output" "$stderr"
}

# --- pagination -------------------------------------------------------------------

@test "gitlab pagination uses page/per_page and X-Next-Page/X-Total for has_more (#815)" {
  run ordo_provider issue_list --limit 2
  [ "$(printf '%s' "$output" | jq -c '[.count, .page, .limit, .has_more, (.items | map(.number))]')" = '[2,1,2,true,[7,8]]' ]
  [ "$(rest_requests 'select(.path | endswith("/issues")) | .query | [.state, .page, .per_page] | join("|")' | tail -n 1)" = '"opened|1|2"' ]
  run ordo_provider issue_list --limit 2 --page 2
  [ "$(printf '%s' "$output" | jq -c '[.count, .page, .has_more, (.items | map(.number))]')" = '[2,2,false,[10,11]]' ]
  run ordo_provider issue_list --limit 2 --page 3
  [ "$(printf '%s' "$output" | jq -c '[.count, .has_more]')" = '[0,false]' ]
  run ordo_provider pr_list --state all --base develop --limit 10
  [ "$(printf '%s' "$output" | jq -c '.items | map(.number)')" = '[15]' ]
  [ "$(rest_requests 'select(.path | endswith("/merge_requests")) | .query | [.state, .target_branch] | join("|")' | tail -n 1)" = '"all|develop"' ]
  run ordo_provider pr_list --state merged --limit 10
  [ "$(printf '%s' "$output" | jq -c '.items | map(.number)')" = '[14]' ]
  run ordo_provider pr_list --state all --head feat/wave-7-16 --author fleet-001 --limit 10
  [ "$(printf '%s' "$output" | jq -c '.items | map(.number)')" = '[16]' ]
  run ordo_provider run_list --branch main
  [ "$(rest_requests 'select(.path | endswith("/pipelines")) | .query.ref' | tail -n 1)" = '"main"' ]
  run ordo_provider run_list --state in_progress
  [ "$(printf '%s' "$output" | jq -c '.items | map(.id)')" = '[101]' ]
  run ordo_provider run_list --limit 3 --page 2
  [ "$(printf '%s' "$output" | jq -c '[.count, .has_more, (.items | map(.id))]')" = '[2,false,[103,200]]' ]
  assert_no_token_leak "$output"
}

# --- error classification -------------------------------------------------------

@test "gitlab HTTP errors are classified: 404=4, 401 auth, 403 refused, 429 rate_limited, 5xx retryable (#815)" {
  local p
  p=$(rest_pr_path 12)
  run --separate-stderr ordo_provider issue_get 999
  [ "$status" -eq 4 ]
  assert_error not_found
  rest_inject_failure "$(jq -cn --arg p "$p" '{"method":"GET","path":$p,"status":401,"body":{"message":"401 Unauthorized"}}')"
  run --separate-stderr ordo_provider pr_get 12
  [ "$status" -eq 1 ]
  [ "$(printf '%s' "$stderr" | jq -c '.error.details | [.category, .retryable]')" = '["auth",false]' ]
  rest_inject_failure "$(jq -cn --arg p "$p" '{"method":"GET","path":$p,"status":403,"body":{"message":"403 Forbidden"}}')"
  run --separate-stderr ordo_provider pr_get 12
  [ "$status" -eq 3 ]
  assert_error policy_refused
  rest_inject_failure "$(jq -cn --arg p "$p" '{"method":"GET","path":$p,"status":429,"headers":{"Retry-After":"30","RateLimit-Remaining":"0"},"body":{"message":"Retry later"}}')"
  run --separate-stderr ordo_provider pr_get 12
  [ "$status" -eq 1 ]
  assert_error rate_limited
  [ "$(printf '%s' "$stderr" | jq -c '.error.details | [.retryable, .retry_after]')" = '[true,"30"]' ]
  rest_inject_failure "$(jq -cn --arg p "$p" '{"method":"GET","path":$p,"status":502,"body":"<html>Bad Gateway</html>"}')"
  run --separate-stderr ordo_provider pr_get 12
  [ "$status" -eq 1 ]
  assert_error provider_error
  [ "$(printf '%s' "$stderr" | jq -c '.error.details | [.category, .retryable, .http_status]')" = '["transient",true,502]' ]
  # GitLab error bodies with an object message are flattened into the message
  rest_inject_failure "$(jq -cn --arg p "$p" '{"method":"GET","path":$p,"status":400,"body":{"message":{"title":["is too long"]}}}')"
  run --separate-stderr ordo_provider pr_get 12
  [ "$status" -eq 1 ]
  [ "$(printf '%s' "$stderr" | jq -c '.error.details | [.category, .retryable]')" = '["client",false]' ]
  [[ "$(printf '%s' "$stderr" | jq -r '.error.message')" == *"is too long"* ]]
  assert_no_token_leak "$output" "$stderr"
}

# --- token hygiene --------------------------------------------------------------

@test "gitlab token never leaks after any op, PRIVATE-TOKEN header only, permissive token file refused (#815)" {
  export ORCH_EXTERNAL_PR_MUTATIONS=all
  local spec
  while IFS= read -r spec; do
    [ -n "$spec" ] || continue
    # shellcheck disable=SC2086
    run --separate-stderr ordo_provider $spec
    assert_no_token_leak "$output" "$stderr" || { echo "leak after: $spec"; return 1; }
    [[ "$output$stderr" != *"PRIVATE-TOKEN"* ]] || { echo "header name leaked after: $spec"; return 1; }
  done <<'EOF'
auth_status
repo_get
issue_get 7 --with comments
issue_list --limit 2
pr_get 12
pr_list --state all --limit 5
pr_files 12
checks_get 12
review_list 12
run_list --limit 2
run_get 100 --with log_failed
pr_get 999
issue_comment 7 --body hi -k s1
pr_merge 14 -k s2
pr_merge 12 -k s3
EOF
  run ordo_provider auth_status
  [ "$(printf '%s' "$output" | jq -c '[.forge, .authenticated, .login, .scopes]')" = '["gitlab",true,"octo-bot",["api","read_repository","write_repository"]]' ]
  run ordo_provider run_get 100 --with log_failed
  [[ "$output" == *"[REDACTED]"* ]]
  [[ "$output" != *"ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"* ]]
  [ "$(rest_request_count '.status == 400')" -eq 0 ]
  [ "$(rest_request_count '.status == 401')" -eq 0 ]
  chmod 604 "$ORDO_FORGE_TOKEN_FILE"
  run --separate-stderr ordo_provider pr_get 12
  [ "$status" -eq 3 ]
  assert_error refused
  [ "$(printf '%s' "$stderr" | jq -r '.error.details.fix')" = "chmod 600 $ORDO_FORGE_TOKEN_FILE" ]
  chmod 600 "$ORDO_FORGE_TOKEN_FILE"
  ORDO_FORGE_TOKEN="glpat-WRONGxxxxxxxxxxxxxxxxxxxxxx" ORDO_FORGE_TOKEN_FILE= run ordo_provider auth_status
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -c '[.authenticated, .http_status]')" = '[false,401]' ]
  [[ "$output" != *"glpat-WRONG"* ]]
  assert_no_token_leak "$output" "$stderr"
}
