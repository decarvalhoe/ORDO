#!/usr/bin/env bats
# tests/ordo_provider_adapter_forgejo.bats — Forgejo/Gitea provider adapter
# (#815, epic #806) against the python3 stub server serving the recorded
# fixtures of tests/fixtures/adapters/forgejo/. No network, no gh.
#
#   - registry flip (forgejo is implemented), configuration errors;
#   - the 16 conformance scenarios of tests/ordo_provider_conformance.bash;
#   - key-set parity of every read op with the github-derived fake fixtures;
#   - native REST calls: label ids, WIP prefix, merge body, auto-merge,
#     double-gated `mutate`;
#   - pagination from X-Total-Count / Link, Actions unsupported => empty list;
#   - error classification: 404=4, 401 auth, 403 refused, 429 rate_limited
#     (+Retry-After), 5xx retryable, 405/409 conflict=5, timeout, retries;
#   - token hygiene: 0600 file, env fallback, permissive mode => exit 3,
#     and after EVERY op (success and failure) the token appears in no
#     output, log, ledger, evidence or trace.

bats_require_minimum_version 1.5.0

load './helpers.bash'
load './ordo_provider_rest_harness'

setup() {
  setup_orch_test
  export REST_FORGE=forgejo
  rest_harness_setup
}

teardown() {
  rest_harness_teardown
}

# --- registry and configuration ------------------------------------------------

@test "forgejo is a registered, implemented adapter (#815)" {
  [ "$(ordo_provider_adapter_status forgejo)" = "implemented" ]
  run ordo_provider adapters
  [[ "$output" == *forgejo* ]]
  _ordo_provider_adapter_load forgejo
  local op
  for op in $ORDO_PROVIDER_ADAPTER_OPS; do
    declare -F "ordo_provider_adapter_forgejo_${op}" >/dev/null || { echo "missing op $op"; return 1; }
  done
}

@test "forgejo without ORDO_FORGE_URL or token is a configuration error before any request (#815)" {
  unset ORDO_FORGE_URL
  run --separate-stderr ordo_provider pr_get 12
  [ "$status" -eq 2 ]
  assert_error bad_argument
  [ "$(printf '%s' "$stderr" | jq -r '.error.details.missing')" = "ORDO_FORGE_URL" ]
  export ORDO_FORGE_URL="http://127.0.0.1:${STUB_PORT}"
  unset ORDO_FORGE_TOKEN_FILE
  run --separate-stderr ordo_provider pr_get 12
  [ "$status" -eq 2 ]
  assert_error bad_argument
  [ "$(printf '%s' "$stderr" | jq -r '.error.details.missing')" = "ORDO_FORGE_TOKEN_FILE" ]
  [ "$(rest_request_count)" -eq 0 ]
  # ORDO_FORGE_URL may carry the /api/v1 suffix already
  export ORDO_FORGE_TOKEN_FILE="$BATS_TEST_TMPDIR/token"
  ORDO_FORGE_URL="http://127.0.0.1:${STUB_PORT}/api/v1" run ordo_provider repo_get
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.default_branch')" = "main" ]
  [ "$(rest_requests '.path' | tail -n 1)" = '"/api/v1/repos/acme/widgets"' ]
}

# --- conformance suite ----------------------------------------------------------

@test "conformance[forgejo]: auth_status" { run_conformance auth_status; }
@test "conformance[forgejo]: repo_get" { run_conformance repo_get; }
@test "conformance[forgejo]: issue_get" { run_conformance issue_get; }
@test "conformance[forgejo]: issue_list_pagination" { run_conformance issue_list_pagination; }
@test "conformance[forgejo]: pr_get" { run_conformance pr_get; }
@test "conformance[forgejo]: pr_list_pagination" { run_conformance pr_list_pagination; }
@test "conformance[forgejo]: pr_files" { run_conformance pr_files; }
@test "conformance[forgejo]: checks_get" { run_conformance checks_get; }
@test "conformance[forgejo]: review_list" { run_conformance review_list; }
@test "conformance[forgejo]: runs" { run_conformance runs; }
@test "conformance[forgejo]: not_found => exit 4" { run_conformance not_found; }
@test "conformance[forgejo]: refused mutation => exit 3" { run_conformance mutation_refused; }
@test "conformance[forgejo]: mutation requires --idempotency-key" { run_conformance mutation_requires_key; }
@test "conformance[forgejo]: idempotent replay" { run_conformance mutation_idempotent_replay; }
@test "conformance[forgejo]: retryable classification" { run_conformance retryable_classification; }
@test "conformance[forgejo]: forge-neutral output" { run_conformance forge_neutral_output; }
@test "conformance[forgejo]: label_list (#818)" { run_conformance label_list; }
@test "conformance[forgejo]: repo_list (#818)" { run_conformance repo_list; }
@test "conformance[forgejo]: workflow_list (#818)" { run_conformance workflow_list; }
@test "conformance[forgejo]: branch_protection_get (#818)" { run_conformance branch_protection_get; }
@test "conformance[forgejo]: check_annotations (#818)" { run_conformance check_annotations; }
@test "conformance[forgejo]: run_log (#818)" { run_conformance run_log; }
@test "conformance[forgejo]: pr_review (#818)" { run_conformance pr_review; }
@test "conformance[forgejo]: pr_files_batch (#818)" { run_conformance pr_files_batch; }

@test "forgejo #818 ops map onto the REST API: labels, org/user repos, rule globs, tree fallback, reviews, annotations unsupported (#818)" {
  # branch protection by name, then by rule glob when the name is unknown
  run ordo_provider branch_protection_get release/1.0
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(printf '%s' "$output" | jq -c '[.protected, .required_reviews, .enforce_admins, .required_checks]')" = '[true,2,true,[]]' ]
  [ "$(rest_request_count '.method == "GET" and .path == "/api/v1/repos/acme/widgets/branch_protections/release/1.0"')" -eq 1 ]
  [ "$(rest_request_count '.method == "GET" and .path == "/api/v1/repos/acme/widgets/branch_protections"')" -ge 1 ]
  run ordo_provider branch_protection_get main
  [ "$(printf '%s' "$output" | jq -c '.required_checks')" = '["bats","shellcheck"]' ]
  # workflows: native endpoint, then the tree when the instance has none
  run ordo_provider workflow_list
  [ "$(printf '%s' "$output" | jq -c '[.details.capability, (.items | map(.name))]')" = '["native",["CI","Nightly"]]' ]
  [ "$(printf '%s' "$output" | jq -r '.items[1].state')" = "disabled" ]
  rest_inject_failure '{"method":"GET","path":"/api/v1/repos/acme/widgets/actions/workflows","status":404,"body":{"message":"The target couldn'"'"'t be found."}}'
  run ordo_provider workflow_list
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(printf '%s' "$output" | jq -c '[.details.capability, .count, .items[0].name, .items[0].path, .items[0].state]')" = '["emulated",1,"ci",".forgejo/workflows/ci.yml","active"]' ]
  rest_clear_failures
  # repo_list: organisation first, user on 404
  run ordo_provider repo_list --owner acme
  [ "$(printf '%s' "$output" | jq -r '.items[0].clone_url')" = "https://forge.example/acme/widgets.git" ]
  [ "$(rest_request_count '.path == "/api/v1/orgs/acme/repos"')" -eq 1 ]
  run --separate-stderr ordo_provider repo_list --owner nobody
  [ "$status" -eq 4 ]
  [ "$(rest_request_count '.path == "/api/v1/users/nobody/repos"')" -eq 1 ]
  # label colours are normalised (no #, lowercase)
  run ordo_provider label_list
  [ "$(printf '%s' "$output" | jq -r '[.items[] | select(.name == "wave-7")][0].color')" = "5319e7" ]
  # annotations: honest unsupported, never an error
  run ordo_provider check_annotations --run 100
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -c '[.count, .details.capability]')" = '[0,"unsupported"]' ]
  # pr_review body
  export ORCH_EXTERNAL_PR_MUTATIONS=pr_review
  run ordo_provider pr_review 12 --event request_changes --body "needs work" -k fj-rev-1
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(printf '%s' "$output" | jq -r '.result.state')" = "changes_requested" ]
  [ "$(rest_requests 'select(.method == "POST" and .path == "/api/v1/repos/acme/widgets/pulls/12/reviews") | .body' | tail -n 1)" = '{"event":"REQUEST_CHANGES","body":"needs work\n"}' ]
  assert_no_token_leak "$output"
}

@test "forgejo privileged paths (pr_review, pr_merge --admin) use ORDO_FORGE_ADMIN_TOKEN_FILE / ORDO_FORGE_ADMIN_TOKEN over the ordinary token (#818)" {
  # The ordinary token is wrong: reads fail with 401 ...
  export ORDO_FORGE_ADMIN_TOKEN_FILE="$ORDO_FORGE_TOKEN_FILE"
  export ORDO_FORGE_TOKEN_FILE="$BATS_TEST_TMPDIR/wrong-token"
  (umask 077; printf 'frg_WRONGTOKENwrongwrongwrongwrongwrong0000\n' > "$ORDO_FORGE_TOKEN_FILE")
  run --separate-stderr ordo_provider pr_get 12
  [ "$status" -eq 1 ]
  assert_error provider_error
  [ "$(printf '%s' "$stderr" | jq -r '.error.details.category')" = "auth" ]
  # ... while the privileged mutations carry the admin credential.
  export ORCH_EXTERNAL_PR_MUTATIONS=pr_review,pr_merge
  run ordo_provider pr_review 12 --event approve --body "lgtm" -k fj-adm-1
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(printf '%s' "$output" | jq -r '.result.state')" = "approved" ]
  run ordo_provider pr_merge 12 --method squash --admin -k fj-adm-2
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(printf '%s' "$output" | jq -c '[.result.merged, .result.admin]')" = '[true,true]' ]
  [ "$(rest_requests 'select(.method == "POST" and .path == "/api/v1/repos/acme/widgets/pulls/12/merge") | .body.force_merge' | tail -n 1)" = "true" ]
  # a plain merge (no --admin) still uses the ordinary token -> 401
  run --separate-stderr ordo_provider pr_merge 13 --method squash -k fj-adm-3
  [ "$status" -eq 1 ]
  [ "$(printf '%s' "$stderr" | jq -r '.error.details.category')" = "auth" ]
  # the env form works too, and a permissive admin token file is refused
  unset ORDO_FORGE_ADMIN_TOKEN_FILE
  ORDO_FORGE_ADMIN_TOKEN="$STUB_TOKEN" run ordo_provider pr_review 13 --event comment --body "note" -k fj-adm-4
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  chmod 644 "$ORDO_FORGE_TOKEN_FILE"
  ORDO_FORGE_ADMIN_TOKEN_FILE="$ORDO_FORGE_TOKEN_FILE" run --separate-stderr ordo_provider pr_review 13 --event comment --body "note" -k fj-adm-5
  [ "$status" -eq 3 ]
  assert_error refused
  [ "$(printf '%s' "$stderr" | jq -r '.error.details.reason')" = "token_file_permissive" ]
  assert_no_token_leak "$output" "$stderr"
}

# --- normalisation: same key set as the github-derived shapes -------------------

@test "forgejo read ops carry exactly the key set of the github-derived fixtures (#815)" {
  assert_same_keys "pr_get 12" pr_get/12.json
  assert_same_keys "pr_get 13" pr_get/13.json
  assert_same_keys "pr_get 14" pr_get/14.json
  assert_same_keys "issue_get 7 --with comments" issue_get/7.json
  assert_same_keys "repo_get" repo_get/default.json
  assert_same_keys "pr_files 12" pr_files/12.json
  assert_same_keys "checks_get 12" checks_get/12.json
  assert_same_keys "review_list 12" review_list/12.json
  assert_same_keys "run_get 100 --with log,log_failed" run_get/100.json
  # list items
  run ordo_provider pr_list --state all --limit 50
  [ "$(printf '%s' "$output" | jq -c '.items[0]' | json_key_set)" = "$(jq -c '.[0]' "$FAKE_FIXTURES/pr_list/default.json" | json_key_set)" ]
  run ordo_provider issue_list --state all --limit 50
  [ "$(printf '%s' "$output" | jq -c '.items[0]' | json_key_set)" = "$(jq -c '.[0]' "$FAKE_FIXTURES/issue_list/default.json" | json_key_set)" ]
  run ordo_provider run_list --limit 50
  [ "$(printf '%s' "$output" | jq -c '.items[0]' | json_key_set)" = "$(jq -c '.[0]' "$FAKE_FIXTURES/run_list/default.json" | json_key_set)" ]
  # values that matter to the merge queue agree with the github fixtures
  run ordo_provider pr_get 12
  [ "$(printf '%s' "$output" | jq -c '{state, draft, mergeable, merge_state, review_decision, head: .head.ref, base: .base.ref}')" = '{"state":"open","draft":false,"mergeable":"mergeable","merge_state":"clean","review_decision":"approved","head":"feat/wave-7-12","base":"main"}' ]
  run ordo_provider checks_get 12
  [ "$(printf '%s' "$output" | jq -c '.summary')" = "$(jq -c '.summary' "$FAKE_FIXTURES/checks_get/12.json")" ]
  [ "$(printf '%s' "$output" | jq -r '[.checks[] | .kind] | join(",")')" = "check_run,check_run,check_run,status" ]
  [ "$(printf '%s' "$output" | jq -r '[.checks[] | .workflow // "-"] | join(",")')" = "CI,CI,Docs,-" ]
  assert_no_token_leak "$output"
}

# --- native REST calls ----------------------------------------------------------

@test "forgejo mutations map onto the REST API: label ids, comments, WIP prefix, merge body (#815)" {
  export ORCH_EXTERNAL_PR_MUTATIONS=all
  run ordo_provider issue_create --title "New" --body $'line one\n`code` $(danger)\n' --label ready --label type:feat --assignee fleet-001 -k m1
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.result.number')" = "1001" ]
  [ "$(rest_requests 'select(.method == "POST" and (.path | endswith("/issues"))) | .body | [.title, (.labels | join(",")), (.assignees | join(","))] | join("|")')" = '"New|2,1|fleet-001"' ]
  # bodies reach the forge verbatim (the generic layer stages --body into a file with one trailing newline)
  [ "$(rest_requests 'select(.method == "POST" and (.path | endswith("/issues"))) | .body.body')" = '"line one\n`code` $(danger)\n\n"' ]
  run ordo_provider issue_labels 7 --add ready --remove blocked -k m2
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.details.scope')" = "issue_labels" ]
  [ "$(printf '%s' "$output" | jq -c '.result | [.labels_added, .labels_removed]')" = '[["ready"],["blocked"]]' ]
  [ "$(rest_requests 'select(.path | endswith("/issues/7/labels")) | .body.labels')" = "[2]" ]
  [ "$(rest_requests 'select(.method == "DELETE") | .path')" = '"/api/v1/repos/acme/widgets/issues/7/labels/6"' ]
  run --separate-stderr ordo_provider issue_labels 7 --add no-such-label -k m2b
  [ "$status" -eq 4 ]
  assert_error not_found
  [ "$(printf '%s' "$stderr" | jq -r '.error.details.labels[0]')" = "no-such-label" ]
  run ordo_provider issue_comment 7 --body "hello" -k m3
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.result.url')" = "https://forge.example/acme/widgets/issues/7#issuecomment-99" ]
  run ordo_provider issue_edit 7 --state closed --reason completed -k m4
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.details.scope')" = "issue_close" ]
  [ "$(rest_requests 'select(.method == "PATCH" and (.path | endswith("/issues/7"))) | .body.state')" = '"closed"' ]
  run ordo_provider pr_edit 12 --title "renamed" --base develop -k m5
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.details.scope')" = "pr_edit" ]
  [ "$(rest_requests 'select(.method == "PATCH" and (.path | endswith("/pulls/12"))) | .body | [.title, .base] | join("|")')" = '"renamed|develop"' ]
  run ordo_provider pr_create --title "T" --head feat/x --draft -k m6
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -c '.result | [.number, .draft, .base.ref]')" = '[1002,true,"main"]' ]
  [ "$(rest_requests 'select(.method == "POST" and (.path | endswith("/pulls"))) | .body | [.title, .head, .base] | join("|")')" = '"WIP: T|feat/x|main"' ]
  run ordo_provider pr_ready 13 -k m7
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.result.draft')" = "false" ]
  [ "$(rest_requests 'select(.method == "PATCH" and (.path | endswith("/pulls/13"))) | .body.title')" = '"feat: pr 13"' ]
  run ordo_provider pr_ready 12 --undo -k m8
  [ "$(rest_requests 'select(.method == "PATCH" and (.path | endswith("/pulls/12"))) | .body.title' | tail -n 1)" = '"WIP: feat: pr 12"' ]
  run ordo_provider pr_merge 12 --method rebase --delete-branch --admin -k m9
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -c '.result')" = '{"number":12,"merged":true,"action":"merged","method":"rebase","admin":true}' ]
  [ "$(rest_requests 'select(.method == "POST" and (.path | endswith("/pulls/12/merge"))) | .body')" = '{"Do":"rebase","delete_branch_after_merge":true,"merge_when_checks_succeed":false,"force_merge":true}' ]
  run ordo_provider pr_merge 15 --auto -k m10
  [ "$(printf '%s' "$output" | jq -r '.result.action')" = "auto_merge_enabled" ]
  [ "$(rest_requests 'select(.method == "POST" and (.path | endswith("/pulls/15/merge"))) | .body.merge_when_checks_succeed')" = "true" ]
  run ordo_provider pr_merge 15 --disable-auto -k m11
  [ "$(printf '%s' "$output" | jq -r '.result.action')" = "auto_merge_disabled" ]
  [ "$(rest_requests 'select(.method == "DELETE" and (.path | endswith("/pulls/15/merge"))) | .path')" = '"/api/v1/repos/acme/widgets/pulls/15/merge"' ]
  run --separate-stderr ordo_provider pr_merge 14 -k m12
  [ "$status" -eq 5 ]
  assert_error conflict
  [ "$(printf '%s' "$stderr" | jq -r '.error.details.http_status')" = "405" ]
  run --separate-stderr ordo_provider pr_merge 13 -k m13
  [ "$status" -eq 5 ]
  assert_error conflict
  [ "$(printf '%s' "$stderr" | jq -r '.error.details.http_status')" = "409" ]
  # every request carried the token in the Authorization header (the stub demands it) and never in the URL
  [ "$(rest_requests 'select(.status == 401 or .status == 400) | .path' | wc -l | tr -d ' ')" -eq 0 ]
  assert_no_token_leak "$output" "$stderr"
}

@test "forgejo mutate is a native REST passthrough gated twice: declared scope, then the path's implied scope (#815)" {
  export ORCH_EXTERNAL_PR_MUTATIONS=pr_review
  run ordo_provider mutate --scope pr_review -k e1 -- --method POST --path repos/acme/widgets/pulls/12/reviews --body '{"event":"APPROVED","body":"ok"}'
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.result.backend')" = "rest" ]
  [ "$(printf '%s' "$output" | jq -r '.result.status')" = "200" ]
  [ "$(printf '%s' "$output" | jq -r '.result.body.state')" = "APPROVED" ]
  [ "$(rest_requests 'select(.path | endswith("/reviews")) | .body.event')" = '"APPROVED"' ]
  # scope says review, path says merge: refused before any request
  local before
  before=$(rest_request_count)
  run --separate-stderr ordo_provider mutate --scope pr_review -k e2 -- --method POST --path repos/acme/widgets/pulls/12/merge
  [ "$status" -eq 3 ]
  assert_error policy_refused
  [ "$(printf '%s' "$stderr" | jq -r '.error.details.implied_scope')" = "pr_merge" ]
  [ "$(rest_request_count)" -eq "$before" ]
  # GET is not a mutation; credentials in the path are refused
  run --separate-stderr ordo_provider mutate --scope pr_review -k e3 -- --method GET --path repos/acme/widgets/pulls/12
  [ "$status" -eq 2 ]
  assert_error bad_argument
  run --separate-stderr ordo_provider mutate --scope pr_review -k e4 -- --method POST --path "repos/acme/widgets/pulls/12/reviews?access_token=x"
  [ "$status" -eq 2 ]
  assert_error bad_argument
  # an absolute /api/v1 path is accepted; --body-file too
  printf '{"event":"COMMENT"}' > "$BATS_TEST_TMPDIR/body.json"
  run ordo_provider mutate --scope pr_review -k e5 -- --method POST --path /api/v1/repos/acme/widgets/pulls/12/reviews --body-file "$BATS_TEST_TMPDIR/body.json"
  [ "$status" -eq 0 ]
  [ "$(rest_requests 'select(.path | endswith("/reviews")) | .body.event' | tail -n 1)" = '"COMMENT"' ]
  assert_no_token_leak "$output" "$stderr"
}

# --- pagination and capabilities ---------------------------------------------------

@test "forgejo pagination uses the page/limit query and X-Total-Count for has_more (#815)" {
  run ordo_provider issue_list --limit 2
  [ "$(printf '%s' "$output" | jq -c '[.count, .page, .limit, .has_more, (.items | map(.number))]')" = '[2,1,2,true,[7,8]]' ]
  [ "$(rest_requests 'select(.path | endswith("/issues")) | .query | [.state, .type, .page, .limit] | join("|")' | tail -n 1)" = '"open|issues|1|2"' ]
  run ordo_provider issue_list --limit 2 --page 3
  [ "$(printf '%s' "$output" | jq -c '[.count, .page, .has_more]')" = '[0,3,false]' ]
  run ordo_provider issue_list --state all --label ready --limit 10
  [ "$(printf '%s' "$output" | jq -c '.items | map(.number)')" = '[7,10]' ]
  [ "$(rest_requests 'select(.path | endswith("/issues")) | .query.labels' | tail -n 1)" = '"ready"' ]
  # pr_list: pure server-side page when only state/labels are used ...
  run ordo_provider pr_list --limit 2 --page 2
  [ "$(printf '%s' "$output" | jq -c '[.count, .has_more, (.items | map(.number))]')" = '[1,false,[15]]' ]
  [ "$(rest_requests 'select(.path | endswith("/pulls")) | .query | [.state, .page, .limit] | join("|")' | tail -n 1)" = '"open|2|2"' ]
  # ... and a local walk + slice when Forgejo cannot filter server-side (base, head, author, merged)
  run ordo_provider pr_list --state merged --limit 10
  [ "$(printf '%s' "$output" | jq -c '.items | map(.number)')" = '[14]' ]
  run ordo_provider pr_list --state all --head feat/wave-7-16 --limit 10
  [ "$(printf '%s' "$output" | jq -c '.items | map(.number)')" = '[16]' ]
  run ordo_provider pr_list --state all --author fleet-001 --limit 2 --page 2
  [ "$(printf '%s' "$output" | jq -c '[.count, .has_more, (.items | map(.number))]')" = '[2,true,[14,15]]' ]
  # pr_files follows Link pagination: one page here, exact count
  run ordo_provider pr_files 12
  [ "$(printf '%s' "$output" | jq -r '.count')" = "2" ]
  assert_no_token_leak "$output"
}

@test "forgejo run_list falls back to /actions/tasks and reports unsupported Actions as an empty list (#815)" {
  # /actions/runs missing (older Forgejo): /actions/tasks serves the same envelope
  rest_inject_failure '{"method":"GET","path":"/api/v1/repos/acme/widgets/actions/runs","status":404,"body":{"message":"The target couldn'"'"'t be found."}}'
  cp -R "$FIXTURES" "$BATS_TEST_TMPDIR/fixtures-tasks"
  mv "$BATS_TEST_TMPDIR/fixtures-tasks/GET/api/v1/repos/acme/widgets/actions/runs.json" "$BATS_TEST_TMPDIR/fixtures-tasks/GET/api/v1/repos/acme/widgets/actions/tasks.json"
  rest_stub_stop
  rest_stub_start "$BATS_TEST_TMPDIR/fixtures-tasks"
  run ordo_provider run_list --branch main
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -c '[.count, .items[0].id]')" = '[1,200]' ]
  [ "$(rest_requests 'select(.path | endswith("/actions/tasks")) | .path' | wc -l | tr -d ' ')" -ge 1 ]
  # neither endpoint: empty list, details.capability=unsupported, exit 0
  rest_inject_failure '[{"method":"GET","path_regex":"/actions/(runs|tasks)$","status":404,"body":{"message":"The target couldn'"'"'t be found."}}]'
  run --separate-stderr ordo_provider run_list
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -c '[.count, .has_more, .details.capability]')" = '[0,false,"unsupported"]' ]
  [ -z "$stderr" ]
  # run_get on such an instance is not_found (exit 4), not a crash
  rest_inject_failure '[{"method":"GET","path_regex":"/actions/","status":404,"body":{"message":"The target couldn'"'"'t be found."}}]'
  run --separate-stderr ordo_provider run_get 100
  [ "$status" -eq 4 ]
  assert_error not_found
  assert_no_token_leak "$output" "$stderr"
}

# --- error classification -------------------------------------------------------

@test "forgejo HTTP errors are classified: 404=4, 401 auth, 403 refused, 429 rate_limited, 5xx retryable, timeout (#815)" {
  local p
  p=$(rest_pr_path 12)
  run --separate-stderr ordo_provider pr_get 999
  [ "$status" -eq 4 ]
  assert_error not_found
  [ "$(printf '%s' "$stderr" | jq -r '.error.details.retryable')" = "false" ]
  rest_inject_failure "$(jq -cn --arg p "$p" '{"method":"GET","path":$p,"status":401,"body":{"message":"token is required"}}')"
  run --separate-stderr ordo_provider pr_get 12
  [ "$status" -eq 1 ]
  assert_error provider_error
  [ "$(printf '%s' "$stderr" | jq -c '.error.details | [.category, .retryable, .http_status]')" = '["auth",false,401]' ]
  rest_inject_failure "$(jq -cn --arg p "$p" '{"method":"GET","path":$p,"status":403,"body":{"message":"user does not have write access"}}')"
  run --separate-stderr ordo_provider pr_get 12
  [ "$status" -eq 3 ]
  assert_error policy_refused
  [ "$(printf '%s' "$stderr" | jq -c '.error.details | [.category, .retryable]')" = '["permission",false]' ]
  rest_inject_failure "$(jq -cn --arg p "$p" '{"method":"GET","path":$p,"status":429,"headers":{"Retry-After":"7"},"body":{"message":"rate limited"}}')"
  run --separate-stderr ordo_provider pr_get 12
  [ "$status" -eq 1 ]
  assert_error rate_limited
  [ "$(printf '%s' "$stderr" | jq -c '.error.details | [.category, .retryable, .retry_after]')" = '["rate_limited",true,"7"]' ]
  rest_inject_failure "$(jq -cn --arg p "$p" '{"method":"GET","path":$p,"status":503,"body":"Service Unavailable"}')"
  run --separate-stderr ordo_provider pr_get 12
  [ "$status" -eq 1 ]
  assert_error provider_error
  [ "$(printf '%s' "$stderr" | jq -c '.error.details | [.category, .retryable, .http_status]')" = '["transient",true,503]' ]
  # a read that exceeds ORDO_PROVIDER_TIMEOUT_SEC is a retryable timeout
  rest_inject_failure "$(jq -cn --arg p "$p" '{"method":"GET","path":$p,"status":200,"sleep":3,"body":{}}')"
  ORDO_PROVIDER_TIMEOUT_SEC=1 run --separate-stderr ordo_provider pr_get 12
  [ "$status" -eq 1 ]
  assert_error provider_error
  [ "$(printf '%s' "$stderr" | jq -c '.error.details | [.category, .retryable, .curl_exit]')" = '["timeout",true,28]' ]
  # a mutation that times out is NOT retryable (outcome unknown)
  rest_inject_failure "$(jq -cn '{"method":"POST","path_regex":"/pulls/12/merge$","status":200,"sleep":3}')"
  ORCH_EXTERNAL_PR_MUTATIONS=all ORDO_PROVIDER_MUTATION_TIMEOUT_SEC=1 run --separate-stderr ordo_provider pr_merge 12 -k t1
  [ "$status" -eq 1 ]
  [ "$(printf '%s' "$stderr" | jq -c '.error.details | [.category, .retryable, .mutation]')" = '["timeout",false,true]' ]
  [[ "$(printf '%s' "$stderr" | jq -r '.error.message')" == *"may or may not have been applied"* ]]
  # a failed mutation is not recorded in the ledger
  [ ! -s "$(ordo_provider_adapter_ledger_file)" ] || [ "$(grep -c '"t1"' "$(ordo_provider_adapter_ledger_file)")" -eq 0 ]
  # bounded retries for reads: 502 once, then success (Retry-After honoured, capped)
  rest_inject_failure "$(jq -cn --arg p "$p" '{"method":"GET","path":$p,"status":502,"headers":{"Retry-After":"1"},"times":1,"body":{"message":"Bad Gateway"}}')"
  ORDO_PROVIDER_HTTP_RETRIES=2 run ordo_provider pr_get 12
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.number')" = "12" ]
  [ "$(rest_request_count '.path == "'"$p"'" and .status == 502')" -eq 1 ]
  # mutations are never retried by the HTTP layer
  rest_inject_failure "$(jq -cn '{"method":"POST","path_regex":"/pulls/12/merge$","status":502,"body":{"message":"Bad Gateway"}}')"
  ORCH_EXTERNAL_PR_MUTATIONS=all ORDO_PROVIDER_HTTP_RETRIES=3 run --separate-stderr ordo_provider pr_merge 12 -k t2
  [ "$status" -eq 1 ]
  [ "$(printf '%s' "$stderr" | jq -r '.error.details.attempts')" = "1" ]
  [ "$(printf '%s' "$stderr" | jq -r '.error.details.retryable')" = "true" ]
  assert_no_token_leak "$output" "$stderr"
}

# --- token hygiene --------------------------------------------------------------

@test "forgejo token never leaks: outputs, errors, logs, ledger, evidence, trace — on every op incl. failures (#815)" {
  export ORCH_EXTERNAL_PR_MUTATIONS=all
  local spec
  while IFS= read -r spec; do
    [ -n "$spec" ] || continue
    # shellcheck disable=SC2086
    run --separate-stderr ordo_provider $spec
    assert_no_token_leak "$output" "$stderr" || { echo "leak after: $spec"; return 1; }
    [[ "$output$stderr" != *"Authorization"* ]] || { echo "header name leaked after: $spec"; return 1; }
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
issue_labels 7 --add ready -k s2
pr_merge 14 -k s3
pr_merge 12 -k s4
mutate --scope pr_review -k s5 -- --method POST --path repos/acme/widgets/pulls/12/reviews --body {"event":"COMMENT"}
EOF
  # the log_failed text is masked, the token-looking value in it never reaches the caller
  run ordo_provider run_get 100 --with log_failed
  [[ "$output" == *"[REDACTED]"* ]]
  [[ "$output" != *"ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"* ]]
  # error paths that echo the forge's message mask the token even when the forge echoes it back
  rest_inject_failure "$(jq -cn --arg p "$(rest_pr_path 12)" --arg t "$STUB_TOKEN" '{"method":"GET","path":$p,"status":401,"body":{"message":("bad token " + $t)}}')"
  run --separate-stderr ordo_provider pr_get 12
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"[REDACTED]"* ]]
  assert_no_token_leak "$output" "$stderr"
  # the http trace log holds method/url/status only
  [ -s "$ORDO_PROVIDER_HTTP_LOG" ]
  grep -qE '^[0-9TZ:-]+ GET http://127\.0\.0\.1:[0-9]+/api/v1/repos/acme/widgets/pulls/12 [0-9]{3} [0-9]+ms$' "$ORDO_PROVIDER_HTTP_LOG"
  # requests never carried credentials in the URL (the stub answers 400 to those)
  [ "$(rest_request_count '.status == 400')" -eq 0 ]
  # the stub saw the right token on every request (no 401 except the injected one)
  [ "$(rest_request_count '.status == 401')" -eq 1 ]
}

@test "forgejo token file: permissive mode is refused (exit 3) with the fix, env fallback works, wrong token is unauthenticated (#815)" {
  chmod 644 "$ORDO_FORGE_TOKEN_FILE"
  run --separate-stderr ordo_provider pr_get 12
  [ "$status" -eq 3 ]
  assert_error refused
  [ "$(printf '%s' "$stderr" | jq -r '.error.details.reason')" = "token_file_permissive" ]
  [ "$(printf '%s' "$stderr" | jq -r '.error.details.mode')" = "644" ]
  [ "$(printf '%s' "$stderr" | jq -r '.error.details.fix')" = "chmod 600 $ORDO_FORGE_TOKEN_FILE" ]
  [ "$(rest_request_count)" -eq 0 ]
  chmod 640 "$ORDO_FORGE_TOKEN_FILE"
  run --separate-stderr ordo_provider pr_get 12
  [ "$status" -eq 3 ]
  chmod 600 "$ORDO_FORGE_TOKEN_FILE"
  run ordo_provider pr_get 12
  [ "$status" -eq 0 ]
  # a missing file is not_found; an empty file is a bad argument
  ORDO_FORGE_TOKEN_FILE=/nonexistent run --separate-stderr ordo_provider pr_get 12
  [ "$status" -eq 4 ]
  assert_error not_found
  : > "$BATS_TEST_TMPDIR/empty"; chmod 600 "$BATS_TEST_TMPDIR/empty"
  ORDO_FORGE_TOKEN_FILE="$BATS_TEST_TMPDIR/empty" run --separate-stderr ordo_provider pr_get 12
  [ "$status" -eq 2 ]
  # ORDO_FORGE_TOKEN env is the fallback when no file is configured
  unset ORDO_FORGE_TOKEN_FILE
  ORDO_FORGE_TOKEN="$STUB_TOKEN" run ordo_provider pr_get 12
  [ "$status" -eq 0 ]
  # a wrong token: auth_status says unauthenticated (exit 0), reads are auth errors (not retryable)
  ORDO_FORGE_TOKEN="frg_WRONGTOKENxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" run ordo_provider auth_status
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -c '[.forge, .authenticated, .http_status]')" = '["forgejo",false,401]' ]
  ORDO_FORGE_TOKEN="frg_WRONGTOKENxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" run --separate-stderr ordo_provider pr_get 12
  [ "$status" -eq 1 ]
  [ "$(printf '%s' "$stderr" | jq -c '.error.details | [.category, .retryable]')" = '["auth",false]' ]
  [[ "$output$stderr" != *"frg_WRONGTOKEN"* ]]
  assert_no_token_leak "$output" "$stderr"
}
