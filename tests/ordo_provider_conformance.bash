#!/usr/bin/env bash
# tests/ordo_provider_conformance.bash — provider adapter conformance suite
# (#811, epic #806). Reusable by #815 for forgejo/gitlab.
#
# Sourced by a bats file (after `load './helpers.bash'` + setup_orch_test and
# after `source "$TK/lib/ordo_provider_adapter.sh"`). The harness selects the
# adapter with ORDO_PROVIDER_ADAPTER and must define three hooks:
#
#   conformance_backend_setup
#       prepare the backend for the adapter under test (mock CLI, fixtures,
#       stub HTTP server, ...) and export ORDO_FORGE_REPO=acme/widgets.
#       The dataset the scenarios expect is the one under
#       tests/fixtures/adapters/ (repo acme/widgets; issue #7; PRs #12 open
#       with 4 checks and 2 files, #13 draft+conflicting, #14 merged,
#       #15 open on base develop, #16 closed; 5 issues of which 4 open; run 100
#       failed with 2 jobs, run 200 on main; #818: six labels incl. type:feat,
#       owner acme with repos widgets + gadgets (archived), workflow "CI"
#       active, branch main protected with required checks bats+shellcheck and
#       1 required review, develop unprotected, job 2 "bats" of run 100
#       failed, pr 12 and pr 13 (no files) for the batch).
#   conformance_inject_failure <retryable|non_retryable>
#       arrange for `pr_get <N>` to fail with that classification and print N.
#   conformance_mutation_count
#       print how many mutations the backend has actually executed so far.
#
# Then, per scenario, the bats file calls:
#   ordo_provider_conformance_run <scenario>
# Scenario names: see ORDO_PROVIDER_CONFORMANCE_SCENARIOS below. Each
# scenario is a plain bash function returning non-zero with a message on
# stderr; no bats-specific helper is used so the suite also runs from a
# plain shell test.

ORDO_PROVIDER_CONFORMANCE_SCENARIOS="auth_status repo_get issue_get issue_list_pagination pr_get pr_list_pagination pr_files checks_get review_list runs not_found mutation_refused mutation_requires_key mutation_idempotent_replay retryable_classification forge_neutral_output label_list repo_list workflow_list branch_protection_get check_annotations run_log pr_review pr_files_batch"

ordo_provider_conformance_scenarios() {
  local s
  for s in $ORDO_PROVIDER_CONFORMANCE_SCENARIOS; do printf '%s\n' "$s"; done
}

# --- tiny assertion kit -------------------------------------------------------
CF_OUT="" CF_ERR="" CF_RC=0

# _cf_call <ordo_provider args...>  -> CF_OUT / CF_ERR / CF_RC
_cf_call() {
  local err
  err=$(mktemp)
  CF_RC=0
  CF_OUT=$(ordo_provider "$@" 2> "$err") || CF_RC=$?
  CF_ERR=$(cat "$err")
  rm -f "$err"
  return 0
}

_cf_fail() {
  printf 'conformance[%s]: %s\n  stdout: %s\n  stderr: %s\n' "${ORDO_PROVIDER_ADAPTER}" "$1" "${CF_OUT:0:400}" "${CF_ERR:0:400}" >&2
  return 1
}

_cf_rc() { [[ "$CF_RC" -eq "$1" ]] || _cf_fail "expected exit $1, got $CF_RC ($2)"; }

# _cf_json <jq boolean expr> <message>   (against CF_OUT)
_cf_json() {
  printf '%s' "$CF_OUT" | jq -e "$1" >/dev/null 2>&1 || _cf_fail "$2 (jq: $1)"
}

# _cf_err <jq boolean expr> <message>    (against CF_ERR = the error object)
_cf_err() {
  [[ "$(printf '%s\n' "$CF_ERR" | grep -c .)" -eq 1 ]] || _cf_fail "expected exactly one error line on stderr"
  printf '%s' "$CF_ERR" | jq -e "$1" >/dev/null 2>&1 || _cf_fail "$2 (jq: $1)"
}

_cf_error_shape() {
  # Every error carries code/message/module/details.retryable(bool)/details.adapter.
  _cf_err '.error.code | type == "string"' "error.code missing" || return 1
  _cf_err '.error.message | type == "string" and length > 0' "error.message missing" || return 1
  _cf_err '.error.module == "provider_adapter"' "error.module must be provider_adapter" || return 1
  _cf_err '.error.details.retryable | type == "boolean"' "details.retryable must be a boolean" || return 1
  _cf_err ".error.details.adapter == \"${ORDO_PROVIDER_ADAPTER}\"" "details.adapter must name the adapter" || return 1
  [[ -z "$CF_OUT" ]] || _cf_fail "an error must print nothing on stdout"
}

_cf_envelope() {
  local op="$1"
  _cf_json ".op == \"$op\"" "envelope .op" || return 1
  _cf_json ".adapter == \"${ORDO_PROVIDER_ADAPTER}\"" "envelope .adapter" || return 1
  _cf_json '.repo == "acme/widgets"' "envelope .repo" || return 1
}

# --- scenarios ----------------------------------------------------------------
conformance_scenario_auth_status() {
  _cf_call auth_status
  _cf_rc 0 "auth_status" || return 1
  _cf_json '.op == "auth_status"' "op" || return 1
  _cf_json '.authenticated == true' "authenticated must be true with the fixture credentials" || return 1
  _cf_json '.forge | type == "string" and length > 0' "forge name" || return 1
  _cf_json '.login | type == "string"' "login" || return 1
  _cf_json '.host | type == "string"' "host" || return 1
  _cf_json '.scopes | type == "array"' "scopes array" || return 1
  _cf_json '[.. | strings] | any(test("gho_|ghp_|glpat-"; "i")) | not' "auth_status must never expose a token" || return 1
}

conformance_scenario_repo_get() {
  _cf_call repo_get
  _cf_rc 0 "repo_get" || return 1
  _cf_envelope repo_get || return 1
  _cf_json '.full_name == "acme/widgets" and .owner == "acme" and .name == "widgets"' "repo identity" || return 1
  _cf_json '.default_branch == "main"' "default_branch" || return 1
  _cf_json '.private | type == "boolean"' "private flag" || return 1
  _cf_json '.url | startswith("http")' "url" || return 1
  _cf_json '.permission | type == "string"' "permission" || return 1
}

conformance_scenario_issue_get() {
  _cf_call issue_get 7
  _cf_rc 0 "issue_get 7" || return 1
  _cf_envelope issue_get || return 1
  _cf_json '.number == 7 and .state == "open"' "number/state" || return 1
  _cf_json '.title | type == "string" and length > 0' "title" || return 1
  _cf_json '.labels | index("type:feat") != null' "labels contain type:feat" || return 1
  _cf_json '.assignees | index("fleet-001") != null' "assignees contain fleet-001" || return 1
  _cf_json '.url | startswith("http")' "url" || return 1
  _cf_json '.body | type == "string"' "body" || return 1
  _cf_json '.author | type == "string"' "author" || return 1
  _cf_json '.updated_at | type == "string"' "updated_at" || return 1
  _cf_json '.closed_by_prs | type == "array"' "closed_by_prs" || return 1
  _cf_json 'has("comments") | not' "comments only with --with comments" || return 1
  _cf_call issue_get 7 --with comments
  _cf_rc 0 "issue_get 7 --with comments" || return 1
  _cf_json '.comments | type == "array" and length >= 1 and (.[0] | has("author") and has("body"))' "comments shape" || return 1
}

conformance_scenario_issue_list_pagination() {
  _cf_call issue_list --limit 2
  _cf_rc 0 "issue_list page 1" || return 1
  _cf_envelope issue_list || return 1
  _cf_json '.count == 2 and (.items | length) == 2 and .page == 1 and .limit == 2 and .has_more == true' "page 1 of open issues" || return 1
  _cf_json '.items | all(.state == "open")' "default state is open" || return 1
  _cf_call issue_list --limit 2 --page 2
  _cf_rc 0 "issue_list page 2" || return 1
  _cf_json '.count == 2 and .page == 2 and .has_more == false' "page 2 is the last page (4 open issues)" || return 1
  _cf_call issue_list --state all --limit 10
  _cf_rc 0 "issue_list all" || return 1
  _cf_json '.count == 5 and .has_more == false' "5 issues in total" || return 1
  _cf_call issue_list --state closed --limit 10
  _cf_rc 0 "issue_list closed" || return 1
  _cf_json '.count == 1 and .items[0].number == 9' "one closed issue (#9)" || return 1
}

conformance_scenario_pr_get() {
  _cf_call pr_get 12
  _cf_rc 0 "pr_get 12" || return 1
  _cf_envelope pr_get || return 1
  _cf_json '.number == 12 and .state == "open" and .draft == false' "number/state/draft" || return 1
  _cf_json '.head.ref == "feat/wave-7-12" and (.head.sha | type == "string" and length > 0)' "head ref/sha" || return 1
  _cf_json '.base.ref == "main"' "base ref" || return 1
  _cf_json '.mergeable == "mergeable"' "mergeable enum" || return 1
  _cf_json '.merge_state | type == "string"' "merge_state" || return 1
  _cf_json '.review_decision == "approved"' "review_decision" || return 1
  _cf_json '.labels | index("wave-7") != null' "labels" || return 1
  _cf_json '.author | type == "string"' "author" || return 1
  _cf_json '.url | startswith("http")' "url" || return 1
  _cf_json '.updated_at | type == "string"' "updated_at" || return 1
  _cf_json '.auto_merge | type == "boolean"' "auto_merge" || return 1
  _cf_call pr_get 13
  _cf_rc 0 "pr_get 13" || return 1
  _cf_json '.draft == true and .mergeable == "conflicting" and .review_decision == "review_required"' "draft + conflicting pr" || return 1
  _cf_call pr_get 14
  _cf_rc 0 "pr_get 14" || return 1
  _cf_json '.state == "merged" and (.merged_at | type == "string") and (.merge_commit | type == "string")' "merged pr" || return 1
}

conformance_scenario_pr_list_pagination() {
  _cf_call pr_list --limit 2
  _cf_rc 0 "pr_list page 1" || return 1
  _cf_envelope pr_list || return 1
  _cf_json '.count == 2 and .has_more == true and (.items | all(.state == "open"))' "page 1 of open prs" || return 1
  _cf_call pr_list --limit 2 --page 2
  _cf_rc 0 "pr_list page 2" || return 1
  _cf_json '.count == 1 and .has_more == false' "page 2 holds the third open pr" || return 1
  _cf_call pr_list --state all --limit 10
  _cf_rc 0 "pr_list all" || return 1
  _cf_json '.count == 5' "5 prs in total" || return 1
  _cf_call pr_list --state merged --limit 10
  _cf_rc 0 "pr_list merged" || return 1
  _cf_json '.count == 1 and .items[0].number == 14' "merged filter" || return 1
  _cf_call pr_list --state all --base develop --limit 10
  _cf_rc 0 "pr_list base develop" || return 1
  _cf_json '.count == 1 and .items[0].number == 15' "base filter" || return 1
}

conformance_scenario_pr_files() {
  _cf_call pr_files 12
  _cf_rc 0 "pr_files 12" || return 1
  _cf_envelope pr_files || return 1
  _cf_json '.number == 12 and .count == 2' "count" || return 1
  _cf_json '[.files[].path] | index("lib/fetcher.sh") != null' "file paths" || return 1
  _cf_json '.files | all(has("additions") and has("deletions"))' "file stats" || return 1
}

conformance_scenario_checks_get() {
  _cf_call checks_get 12
  _cf_rc 0 "checks_get 12" || return 1
  _cf_envelope checks_get || return 1
  _cf_json '.number == 12 and (.checks | length) == 4' "4 checks" || return 1
  _cf_json '.checks | all((.name | type == "string") and (.status | IN("queued", "in_progress", "completed")) and has("conclusion") and has("url"))' "check shape" || return 1
  _cf_json '.summary.state == "fail" and .summary.failed == 1 and .summary.pending == 1 and .summary.total == 4' "summary" || return 1
  _cf_json '[.checks[] | select(.name == "bats")][0].conclusion == "failure"' "bats failed" || return 1
}

conformance_scenario_review_list() {
  _cf_call review_list 12
  _cf_rc 0 "review_list 12" || return 1
  _cf_envelope review_list || return 1
  _cf_json '.decision == "approved" and (.reviews | length) == 2' "decision + reviews" || return 1
  _cf_json '.reviews | all((.author | type == "string") and (.state | IN("approved", "changes_requested", "commented", "dismissed", "pending")))' "review shape" || return 1
}

conformance_scenario_runs() {
  _cf_call run_list --branch main
  _cf_rc 0 "run_list --branch main" || return 1
  _cf_envelope run_list || return 1
  _cf_json '.count == 1 and .items[0].id == 200 and .items[0].status == "completed" and .items[0].conclusion == "success"' "run on main" || return 1
  _cf_call run_list --limit 3
  _cf_rc 0 "run_list --limit 3" || return 1
  _cf_json '.count == 3 and .has_more == true' "run pagination" || return 1
  _cf_call run_get 100
  _cf_rc 0 "run_get 100" || return 1
  _cf_envelope run_get || return 1
  _cf_json '.id == 100 and .conclusion == "failure" and (.jobs | length) == 2' "run + jobs" || return 1
  _cf_json '.jobs | all(has("name") and has("status") and has("conclusion"))' "job shape" || return 1
  _cf_json 'has("log_failed") | not' "log only with --with log_failed" || return 1
  _cf_call run_get 100 --with log_failed
  _cf_rc 0 "run_get --with log_failed" || return 1
  _cf_json '.log_failed | type == "string" and length > 0' "log_failed text" || return 1
  _cf_json '.log_failed | test("ghp_[A-Za-z0-9]{20,}") | not' "log_failed must be redacted" || return 1
}

conformance_scenario_not_found() {
  _cf_call pr_get 999
  _cf_rc 4 "pr_get 999" || return 1
  _cf_error_shape || return 1
  _cf_err '.error.code == "not_found" and .error.details.retryable == false' "not_found is not retryable" || return 1
  _cf_call issue_get 999
  _cf_rc 4 "issue_get 999" || return 1
  _cf_err '.error.code == "not_found"' "issue not_found" || return 1
}

conformance_scenario_mutation_refused() {
  local before
  before=$(conformance_mutation_count)
  ORCH_EXTERNAL_PR_MUTATIONS="" _cf_call pr_merge 12 --idempotency-key "cf-refused-$RANDOM"
  _cf_rc 3 "refused mutation" || return 1
  _cf_error_shape || return 1
  _cf_err '.error.code == "policy_refused" and .error.details.retryable == false and .error.details.scope == "pr_merge"' "policy_refused" || return 1
  [[ "$(conformance_mutation_count)" == "$before" ]] || _cf_fail "a refused mutation must not reach the backend"
  ORCH_EXTERNAL_PR_MUTATIONS="pr_comment" _cf_call issue_comment 7 --body "x" --idempotency-key "cf-refused2-$RANDOM"
  _cf_rc 3 "scope mismatch is refused" || return 1
  [[ "$(conformance_mutation_count)" == "$before" ]] || _cf_fail "a refused mutation must not reach the backend (scope mismatch)"
}

conformance_scenario_mutation_requires_key() {
  local before op
  before=$(conformance_mutation_count)
  for op in issue_create issue_edit issue_comment issue_labels pr_create pr_edit pr_ready pr_merge mutate pr_review; do
    case "$op" in
      issue_create) ORCH_EXTERNAL_PR_MUTATIONS=all _cf_call issue_create --title t ;;
      pr_create) ORCH_EXTERNAL_PR_MUTATIONS=all _cf_call pr_create --title t --head h ;;
      mutate) ORCH_EXTERNAL_PR_MUTATIONS=all _cf_call mutate --scope pr_review -- pr review 12 ;;
      issue_labels) ORCH_EXTERNAL_PR_MUTATIONS=all _cf_call issue_labels 7 --add x ;;
      pr_review) ORCH_EXTERNAL_PR_MUTATIONS=all _cf_call pr_review 12 --event approve ;;
      *) ORCH_EXTERNAL_PR_MUTATIONS=all _cf_call "$op" 12 --title t ;;
    esac
    _cf_rc 2 "$op without --idempotency-key" || return 1
    _cf_err '.error.code == "usage" and .error.details.missing == "idempotency_key"' "$op must demand the key" || return 1
  done
  [[ "$(conformance_mutation_count)" == "$before" ]] || _cf_fail "mutations without a key must not reach the backend"
}

conformance_scenario_mutation_idempotent_replay() {
  local key="cf-replay-$RANDOM-$RANDOM" before first second
  before=$(conformance_mutation_count)
  ORCH_EXTERNAL_PR_MUTATIONS=all _cf_call issue_comment 7 --body "conformance" --idempotency-key "$key"
  _cf_rc 0 "first execution" || return 1
  _cf_json '.op == "issue_comment" and .details.replayed == false and .details.idempotency_key == "'"$key"'" and .details.scope == "issue_comment"' "receipt shape" || return 1
  _cf_json '.result | type == "object"' "receipt result" || return 1
  first="$CF_OUT"
  [[ "$(conformance_mutation_count)" == "$((before + 1))" ]] || _cf_fail "first execution must reach the backend exactly once"
  ORCH_EXTERNAL_PR_MUTATIONS="" _cf_call issue_comment 7 --body "conformance" --idempotency-key "$key"
  _cf_rc 0 "replay" || return 1
  _cf_json '.details.replayed == true' "replayed flag" || return 1
  second="$CF_OUT"
  [[ "$(conformance_mutation_count)" == "$((before + 1))" ]] || _cf_fail "a replayed key must not re-execute"
  [[ "$(printf '%s' "$first" | jq -c '.result')" == "$(printf '%s' "$second" | jq -c '.result')" ]] || _cf_fail "replay must return the recorded result"
  ORCH_EXTERNAL_PR_MUTATIONS=all _cf_call pr_ready 12 --idempotency-key "$key"
  _cf_rc 5 "same key, other op" || return 1
  _cf_err '.error.code == "conflict"' "key reuse across ops is a conflict" || return 1
}

conformance_scenario_retryable_classification() {
  local n
  n=$(conformance_inject_failure retryable)
  _cf_call pr_get "$n"
  [[ "$CF_RC" -ne 0 ]] || _cf_fail "injected transient failure must fail"
  _cf_error_shape || return 1
  _cf_err '.error.details.retryable == true' "transient failure must be retryable" || return 1
  _cf_err '.error.code == "provider_error"' "transient failure code" || return 1
  n=$(conformance_inject_failure non_retryable)
  _cf_call pr_get "$n"
  [[ "$CF_RC" -ne 0 ]] || _cf_fail "injected auth failure must fail"
  _cf_error_shape || return 1
  _cf_err '.error.details.retryable == false' "auth failure must not be retryable" || return 1
}

conformance_scenario_forge_neutral_output() {
  local op
  for op in "pr_get 12" "issue_get 7" "checks_get 12" "run_get 100" "review_list 12" "repo_get" "pr_list --limit 2" "issue_list --limit 2" \
            "label_list --limit 3" "repo_list --owner acme" "workflow_list" "branch_protection_get main" "check_annotations --run 100" "pr_files_batch 12,13"; do
    # shellcheck disable=SC2086 # intentional word-splitting of the op spec
    _cf_call $op
    _cf_rc 0 "$op" || return 1
    _cf_json '[paths | .[] | strings] | all(test("^[a-z][a-z0-9_]*$"))' "$op: every key must be snake_case (no forge vocabulary)" || return 1
    _cf_json '[paths | .[] | strings] | any(IN("headRefName", "isDraft", "mergeStateStatus", "statusCheckRollup", "databaseId", "nameWithOwner", "__typename", "iid", "merge_request", "annotation_level", "start_line", "status_check_contexts", "required_status_checks", "path_with_namespace", "web_url", "html_url", "defaultBranchRef", "isArchived", "rule_name")) | not' "$op: no gh/glab field names may leak" || return 1
  done
}


# --- scenarios added by #818 ---------------------------------------------------
conformance_scenario_label_list() {
  _cf_call label_list --limit 3
  _cf_rc 0 "label_list --limit 3" || return 1
  _cf_envelope label_list || return 1
  _cf_json '.count == 3 and (.items | length) == 3 and .page == 1 and .limit == 3 and .has_more == true' "page 1 of the six labels" || return 1
  _cf_json '.items | all((.name | type == "string" and length > 0) and (.color | type == "string" and test("^[0-9a-f]{6}$")) and (.description | type == "string"))' "label shape (colour is 6 lowercase hex digits, no #)" || return 1
  _cf_call label_list --limit 10
  _cf_rc 0 "label_list --limit 10" || return 1
  _cf_json '.count == 6 and .has_more == false' "six labels in total" || return 1
  _cf_json '[.items[] | select(.name == "type:feat")][0] | .color == "0e8a16" and .description == "Feature"' "type:feat colour + description" || return 1
}

conformance_scenario_repo_list() {
  _cf_call repo_list --owner acme --limit 10
  _cf_rc 0 "repo_list --owner acme" || return 1
  _cf_json '.op == "repo_list" and .owner == "acme"' "op + owner" || return 1
  _cf_json '.count == 2 and .has_more == false' "two repositories" || return 1
  _cf_json '.items | all(has("name") and has("full_name") and has("default_branch") and (.private | type == "boolean") and (.url | startswith("http")) and (.clone_url | endswith(".git")) and (.archived | type == "boolean"))' "repo item shape" || return 1
  _cf_json '[.items[] | select(.full_name == "acme/widgets")][0] | .name == "widgets" and .default_branch == "main" and .archived == false' "acme/widgets" || return 1
  _cf_json '[.items[] | select(.full_name == "acme/gadgets")][0] | .archived == true and .default_branch == "develop"' "acme/gadgets is archived" || return 1
  _cf_call repo_list --owner acme --limit 1 --page 2
  _cf_rc 0 "repo_list page 2" || return 1
  _cf_json '.count == 1 and .page == 2 and .has_more == false' "pagination" || return 1
  _cf_call repo_list
  _cf_rc 0 "repo_list without --owner uses the owner of the repo" || return 1
  _cf_json '.owner == "acme"' "owner derived from ORDO_FORGE_REPO" || return 1
}

conformance_scenario_workflow_list() {
  _cf_call workflow_list
  _cf_rc 0 "workflow_list" || return 1
  _cf_envelope workflow_list || return 1
  _cf_json '.items | type == "array"' "items array" || return 1
  _cf_json '.items | all(has("id") and (.name | type == "string" and length > 0) and (.path | type == "string") and (.state | IN("active", "disabled", "unknown")))' "workflow shape" || return 1
  _cf_json '(.details.capability // "native") | IN("native", "emulated", "unsupported")' "capability enum" || return 1
  # Every backend of the conformance dataset lists at least one active
  # workflow (GitLab: the CI configuration file, emulated).
  _cf_json '.count >= 1 and (.items | any(.state == "active"))' "at least one active workflow" || return 1
  _cf_call workflow_list --state active
  _cf_rc 0 "workflow_list --state active" || return 1
  _cf_json '.items | all(.state == "active")' "state filter" || return 1
}

conformance_scenario_branch_protection_get() {
  _cf_call branch_protection_get main
  _cf_rc 0 "branch_protection_get main" || return 1
  _cf_envelope branch_protection_get || return 1
  _cf_json '.branch == "main" and .protected == true' "main is protected" || return 1
  _cf_json '.required_checks | type == "array" and (index("bats") != null) and (index("shellcheck") != null)' "required checks bats + shellcheck" || return 1
  _cf_json '.required_reviews == 1' "one required review" || return 1
  _cf_json '.enforce_admins | type == "boolean"' "enforce_admins boolean" || return 1
  _cf_call branch_protection_get develop
  _cf_rc 0 "branch_protection_get develop" || return 1
  _cf_json '.branch == "develop" and .protected == false and .required_checks == [] and .required_reviews == 0 and .enforce_admins == false' "develop is not protected" || return 1
  _cf_call branch_protection_get
  _cf_rc 2 "branch_protection_get without a branch" || return 1
  _cf_err '.error.code == "usage" and .error.details.missing == "branch"' "usage error" || return 1
}

_cf_annotations_shape() {
  _cf_json '.annotations | type == "array"' "annotations array" || return 1
  _cf_json '.count == (.annotations | length)' "count" || return 1
  _cf_json '.annotations | all(has("check_id") and has("check_name") and has("path") and has("line") and (.level | IN("failure", "warning", "notice")) and (.message | type == "string"))' "annotation shape" || return 1
  _cf_json '(.details.capability // "native") | IN("native", "emulated", "unsupported")' "capability enum" || return 1
}

conformance_scenario_check_annotations() {
  _cf_call check_annotations --check 2
  _cf_rc 0 "check_annotations --check 2" || return 1
  _cf_envelope check_annotations || return 1
  _cf_json '.subject.kind == "check" and .subject.id == 2' "subject" || return 1
  _cf_annotations_shape || return 1
  # Job 2 (bats) failed: a forge with annotations reports at least one failure
  # level entry; a forge without (unsupported) reports none, never an error.
  _cf_json 'if (.details.capability // "") == "unsupported" then .count == 0 else (.count >= 1 and (.annotations | any(.level == "failure"))) end' "failed check annotations or honest unsupported" || return 1
  _cf_call check_annotations --run 100
  _cf_rc 0 "check_annotations --run 100" || return 1
  _cf_json '.subject.kind == "run" and .subject.id == 100' "run subject" || return 1
  _cf_annotations_shape || return 1
  _cf_json 'if (.details.capability // "") == "unsupported" then .count == 0 else (.count >= 1 and (.annotations | any(.check_name == "bats" and .level == "failure"))) end' "run annotations name the failed job" || return 1
  _cf_call check_annotations 12
  _cf_rc 0 "check_annotations 12 (pr)" || return 1
  _cf_json '.subject.kind == "pr" and .subject.id == 12' "pr subject" || return 1
  _cf_annotations_shape || return 1
  _cf_json 'if (.details.capability // "") == "unsupported" then .count == 0 else .count >= 1 end' "pr annotations" || return 1
  _cf_json '[.. | strings] | any(test("ghp_[A-Za-z0-9]{20,}")) | not' "annotations must be masked" || return 1
  _cf_call check_annotations
  _cf_rc 2 "check_annotations without a subject" || return 1
  _cf_err '.error.code == "usage" and .error.details.missing == "subject"' "usage error" || return 1
}

conformance_scenario_run_log() {
  _cf_call run_get 100
  _cf_rc 0 "run_get 100" || return 1
  _cf_json 'has("log") | not' "log only with --with log" || return 1
  _cf_call run_get 100 --with log
  _cf_rc 0 "run_get 100 --with log" || return 1
  _cf_envelope run_get || return 1
  _cf_json '.log | type == "string" and length > 0' "full log text" || return 1
  _cf_json '.log | test("fetcher retries")' "log carries the failed job output" || return 1
  _cf_json '.log | test("shellcheck")' "log carries the successful job too (log_failed does not)" || return 1
  _cf_json '.log | test("ghp_[A-Za-z0-9]{20,}") | not' "log must be redacted" || return 1
  _cf_json 'has("log_failed") | not' "log_failed absent unless asked" || return 1
  _cf_call run_get 100 --with log,log_failed
  _cf_rc 0 "run_get --with log,log_failed" || return 1
  _cf_json '(.log | type == "string") and (.log_failed | type == "string")' "both logs" || return 1
}

conformance_scenario_pr_review() {
  local before key="cf-review-$RANDOM-$RANDOM"
  before=$(conformance_mutation_count)
  ORCH_EXTERNAL_PR_MUTATIONS="" _cf_call pr_review 12 --event approve --body "lgtm" --idempotency-key "$key"
  _cf_rc 3 "refused review" || return 1
  _cf_err '.error.code == "policy_refused" and .error.details.scope == "pr_review"' "pr_review scope" || return 1
  [[ "$(conformance_mutation_count)" == "$before" ]] || _cf_fail "a refused review must not reach the backend"
  ORCH_EXTERNAL_PR_MUTATIONS=pr_review _cf_call pr_review 12 --event bogus --body "x" --idempotency-key "$key"
  _cf_rc 2 "unknown event" || return 1
  _cf_err '.error.code == "usage"' "usage error on the event" || return 1
  ORCH_EXTERNAL_PR_MUTATIONS=pr_review _cf_call pr_review 12 --event request_changes --idempotency-key "$key"
  _cf_rc 2 "request_changes without a body" || return 1
  _cf_err '.error.code == "usage" and .error.details.missing == "body"' "body required" || return 1
  ORCH_EXTERNAL_PR_MUTATIONS=pr_review _cf_call pr_review 12 --event approve --body "lgtm" --idempotency-key "$key"
  _cf_rc 0 "approve" || return 1
  _cf_json '.op == "pr_review" and .details.scope == "pr_review" and .details.replayed == false' "receipt" || return 1
  _cf_json '.result.number == 12 and .result.event == "approve" and .result.state == "approved" and (.result.url | type == "string")' "result shape" || return 1
  [[ "$(conformance_mutation_count)" -ge "$((before + 1))" ]] || _cf_fail "the approval must reach the backend"
  local after
  after=$(conformance_mutation_count)
  ORCH_EXTERNAL_PR_MUTATIONS="" _cf_call pr_review 12 --event approve --body "lgtm" --idempotency-key "$key"
  _cf_rc 0 "replay" || return 1
  _cf_json '.details.replayed == true and .result.state == "approved"' "replayed receipt" || return 1
  [[ "$(conformance_mutation_count)" == "$after" ]] || _cf_fail "a replayed review must not re-execute"
}

conformance_scenario_pr_files_batch() {
  _cf_call pr_files_batch 12,13
  _cf_rc 0 "pr_files_batch 12,13" || return 1
  _cf_envelope pr_files_batch || return 1
  _cf_json '.count == 2 and (.items | length) == 2 and .missing == []' "two prs, none missing" || return 1
  _cf_json '.items | map(.number) == [12, 13]' "sorted by number" || return 1
  _cf_json '.items[0] | .number == 12 and .count == 2 and ([.files[].path] | index("lib/fetcher.sh") != null) and (.files | all(has("additions") and has("deletions")))' "pr 12 files" || return 1
  _cf_json '.items[1] | .number == 13 and .count == 0 and .files == []' "pr 13 has no files" || return 1
  _cf_call pr_files_batch 12 999
  _cf_rc 0 "pr_files_batch 12 999" || return 1
  _cf_json '.count == 1 and .items[0].number == 12 and .missing == [999]' "a missing pr is reported, not fatal" || return 1
  _cf_call pr_files_batch
  _cf_rc 2 "pr_files_batch without numbers" || return 1
  _cf_err '.error.code == "usage"' "usage error" || return 1
  _cf_call pr_files_batch 12,abc
  _cf_rc 2 "pr_files_batch with a non-number" || return 1
}

# ordo_provider_conformance_run <scenario>
ordo_provider_conformance_run() {
  local scenario="${1:?usage: ordo_provider_conformance_run <scenario>}"
  local fn="conformance_scenario_${scenario}"
  declare -F "$fn" >/dev/null 2>&1 || { printf 'unknown conformance scenario: %s\n' "$scenario" >&2; return 2; }
  local hook
  for hook in conformance_backend_setup conformance_inject_failure conformance_mutation_count; do
    declare -F "$hook" >/dev/null 2>&1 || { printf 'conformance harness must define %s\n' "$hook" >&2; return 2; }
  done
  [[ -n "${ORDO_PROVIDER_ADAPTER:-}" ]] || { printf 'ORDO_PROVIDER_ADAPTER must be set\n' >&2; return 2; }
  "$fn"
}
