#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2153 # jq programs use $vars; ORDO_PV_* are set by the generic layer
# lib/ordo_provider_adapter_gitlab.sh — GitLab backend of the provider
# adapter (#815, epic #806). REST API v4 through curl
# (lib/ordo_provider_adapter_http.sh); no `glab`, no `gh`.
#
# Configuration:
#   ORDO_FORGE_URL         instance base (https://gitlab.example); the API base
#                          is $ORDO_FORGE_URL/api/v4 (a URL already ending in
#                          /api/v4 is accepted as-is)
#   ORDO_FORGE_REPO        owner/repo — the project path, URL-encoded into the
#                          project id (owner%2Frepo); nested groups work
#                          (group/subgroup/repo)
#   ORDO_FORGE_TOKEN_FILE  0600 file holding a personal/project/group access
#                          token (header PRIVATE-TOKEN); ORDO_FORGE_TOKEN env
#                          is the fallback
#
# Vocabulary mapping — "pr" is a merge request: iid -> number, opened -> open,
# merged -> merged, closed/locked -> closed, source_branch -> head.ref,
# sha -> head.sha, target_branch -> base.ref, detailed_merge_status ->
# mergeable/merge_state, pipelines -> runs, pipeline jobs -> run.jobs,
# commit statuses -> checks, approvals + reviewers -> reviews.
#
# Native mapping (see docs/architecture/providers.md for the capability matrix):
#   auth_status   GET /user (+ GET /personal_access_tokens/self for scopes, best effort)
#   repo_get      GET /projects/:id
#   issue_get     GET /projects/:id/issues/:iid + /closed_by [+ /notes]
#   issue_list    GET /projects/:id/issues?state=&labels=&search=&author_username=&assignee_username=&milestone=&page=&per_page=
#   pr_get        GET /projects/:id/merge_requests/:iid + /approvals
#   pr_list       GET /projects/:id/merge_requests?state=&target_branch=&source_branch=&labels=&author_username=&assignee_username=&search=
#   pr_files      GET /projects/:id/merge_requests/:iid/diffs (additions/deletions counted from the diff)
#   checks_get    GET /projects/:id/repository/commits/:sha/statuses (head pipeline jobs + external statuses)
#   review_list   GET /projects/:id/merge_requests/:iid/approvals + /reviewers
#   run_list      GET /projects/:id/pipelines?ref=&sha=&status=&name=
#   run_get       GET /projects/:id/pipelines/:id + /jobs [+ /jobs/:id/trace for failed jobs]
#   issue_create  POST /projects/:id/issues (assignee_ids and milestone_id resolved by name)
#   issue_edit    PUT /projects/:id/issues/:iid (state_event, add_labels/remove_labels, ...)
#   issue_comment POST /projects/:id/issues/:iid/notes
#   issue_labels  PUT /projects/:id/issues/:iid {add_labels, remove_labels}
#   pr_create     POST /projects/:id/merge_requests (draft = "Draft:" title prefix)
#   pr_edit       PUT /projects/:id/merge_requests/:iid
#   pr_ready      PUT title without/with the "Draft:" prefix
#   pr_merge      PUT /projects/:id/merge_requests/:iid/merge {squash, should_remove_source_branch,
#                 merge_when_pipeline_succeeds}; --disable-auto = POST .../cancel_merge_when_pipeline_succeeds
#   mutate        native REST passthrough: -- --method M --path P [--body J|--body-file F]
#   label_list    GET /projects/:id/labels?page=&per_page= (#818)
#   repo_list     GET /groups/:owner/projects (404 -> GET /users/:owner/projects) (#818)
#   workflow_list emulated: the CI config file (ci_config_path, default .gitlab-ci.yml) on the
#                 default branch is the one "workflow" (details.capability="emulated");
#                 pipeline schedules are not listed (#818)
#   branch_protection_get  GET /projects/:id/protected_branches/:name (404 -> the list, matched
#                 by wildcard) + /approval_rules (required_reviews) + /external_status_checks
#                 (required_checks, premium; absent -> []); enforce_admins unsupported -> false (#818)
#   check_annotations  emulated from job traces: one annotation per failed job carrying the
#                 tail of its trace (details.capability="emulated") (#818)
#   run_get --with log  GET /jobs/:id/trace of every job (#818)
#   pr_review     approve -> POST .../approve; request_changes -> POST .../unapprove + note;
#                 comment -> POST .../notes (privileged token) (#818)
#   pr_files_batch  GET .../merge_requests/:iid/diffs per number (404 -> "missing") (#818)
#
# Privileged paths (pr_review; pr_merge --admin has no GitLab equivalent) send
# ORDO_FORGE_ADMIN_TOKEN_FILE / ORDO_FORGE_ADMIN_TOKEN when configured.
#
# Loaded on demand by lib/ordo_provider_adapter.sh; do not source directly.

# shellcheck source=lib/ordo_provider_adapter_http.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ordo_provider_adapter_http.sh"

_ORDO_GITLAB_AUTH="private-token"
: "${ORDO_GITLAB_DRAFT_PREFIX:=Draft:}"

_ORDO_PROVIDER_GITLAB_JQ_LIB='
def lc: if . == null then "" else (tostring | ascii_downcase) end;
def ts: if . == null or . == "" then null else . end;
def usernames: [.[]? | if type == "object" then .username else . end];
def norm_issue: {
  "number": .iid, "title": (.title // ""),
  "state": (if (.state | lc) == "closed" then "closed" else "open" end),
  "labels": (.labels // []), "assignees": (.assignees | usernames),
  "url": (.web_url // ""), "body": (.description // ""), "author": (.author.username // ""),
  "created_at": (.created_at | ts), "updated_at": (.updated_at | ts), "closed_at": (.closed_at | ts),
  "milestone": (.milestone.title // null),
  "closed_by_prs": []};
def mr_state_of($s): if $s == "merged" then "merged" elif $s == "closed" then "closed" else "open" end;
def norm_note($url): {"author": (.author.username // ""), "body": (.body // ""), "created_at": (.created_at | ts), "url": ($url + "#note_" + ((.id // "") | tostring))};
def pr_state: mr_state_of(.state | lc);
def dms: (.detailed_merge_status // .merge_status // "") | lc;
def pr_mergeable:
  if pr_state == "merged" then "mergeable"
  elif .has_conflicts == true or dms == "conflict" or dms == "cannot_be_merged" or dms == "broken_status" then "conflicting"
  elif dms == "checking" or dms == "unchecked" or dms == "preparing" or dms == "cannot_be_merged_recheck" or dms == "" then "unknown"
  else "mergeable" end;
def pr_merge_state:
  if pr_state == "merged" then "clean"
  elif pr_state == "closed" then "unknown"
  elif .has_conflicts == true or dms == "conflict" or dms == "cannot_be_merged" or dms == "broken_status" then "dirty"
  elif dms == "mergeable" or dms == "can_be_merged" then "clean"
  elif dms == "draft_status" then "draft"
  elif dms == "need_rebase" then "behind"
  elif dms == "ci_still_running" then "unstable"
  elif dms == "ci_must_pass" or dms == "not_approved" or dms == "discussions_not_resolved" or dms == "requested_changes"
       or dms == "policies_denied" or dms == "blocked_status" or dms == "jira_association_missing" or dms == "external_status_checks"
       or dms == "approvals_syncing" or dms == "locked_paths" or dms == "locked_lfs_files" or dms == "commits_status" or dms == "security_policy_violations" then "blocked"
  else "unknown" end;
def decision_from_pr:
  if dms == "requested_changes" then "changes_requested"
  elif dms == "not_approved" then "review_required"
  elif ((.reviewers // []) | length) > 0 then "review_required"
  else "none" end;
def norm_pr($decision): {
  "number": .iid, "title": (.title // ""), "state": pr_state, "draft": (.draft // .work_in_progress // false),
  "head": {"ref": (.source_branch // ""), "sha": (.sha // "")},
  "base": {"ref": (.target_branch // "")},
  "url": (.web_url // ""), "mergeable": pr_mergeable, "merge_state": pr_merge_state,
  "author": (.author.username // ""),
  "labels": (.labels // []), "assignees": (.assignees | usernames),
  "review_decision": $decision, "auto_merge": ((.auto_merge_enabled // .merge_when_pipeline_succeeds // false) == true),
  "created_at": (.created_at | ts), "updated_at": (.updated_at | ts),
  "merged_at": (.merged_at | ts), "closed_at": (.closed_at | ts),
  "merge_commit": (.merge_commit_sha // .squash_commit_sha // null),
  "body": (.description // ""),
  "changed_files": ((.changes_count // null) | if . == null then null elif (tostring | test("^[0-9]+$")) then tonumber else null end)};
def gl_status:
  (.status | lc) as $s
  | if $s == "created" or $s == "pending" or $s == "waiting_for_resource" or $s == "preparing" or $s == "scheduled" then "queued"
    elif $s == "running" then "in_progress"
    else "completed" end;
def gl_conclusion:
  (.status | lc) as $s
  | if $s == "success" then "success"
    elif $s == "failed" then (if .allow_failure == true then "neutral" else "failure" end)
    elif $s == "canceled" or $s == "canceling" then "cancelled"
    elif $s == "skipped" then "skipped"
    elif $s == "manual" then (if .allow_failure == true then "skipped" else "action_required" end)
    elif $s == "created" or $s == "pending" or $s == "waiting_for_resource" or $s == "preparing" or $s == "scheduled" or $s == "running" then null
    else $s end;
def norm_status($workflow): {
  "name": (.name // ""), "kind": (if .pipeline_id != null then "check_run" else "status" end),
  "status": gl_status, "conclusion": gl_conclusion,
  "url": (.target_url // ""), "workflow": (if .pipeline_id != null then $workflow else null end),
  "started_at": ((.started_at // .created_at) | ts), "completed_at": (.finished_at | ts)};
def checks_summary:
  {"total": length,
   "passed": ([.[] | select(.status == "completed" and (.conclusion == "success" or .conclusion == "neutral" or .conclusion == "skipped"))] | length),
   "failed": ([.[] | select(.status == "completed" and (.conclusion == "failure" or .conclusion == "timed_out" or .conclusion == "cancelled" or .conclusion == "action_required" or .conclusion == "startup_failure" or .conclusion == "stale"))] | length),
   "pending": ([.[] | select(.status != "completed")] | length)}
  | .state = (if .total == 0 then "none" elif .failed > 0 then "fail" elif .pending > 0 then "pending" else "pass" end);
def reviewer_state:
  (.state | lc) as $s
  | if $s == "approved" then "approved" elif $s == "requested_changes" then "changes_requested"
    elif $s == "reviewed" then "commented" elif $s == "unapproved" then "dismissed" else "pending" end;
def norm_run: {
  "id": (.id // null), "run_number": (.iid // null),
  "name": (if (.name // "") != "" then .name else ("pipeline #" + ((.iid // .id) | tostring)) end),
  "workflow": (if (.name // "") != "" then .name else "pipeline" end),
  "title": (.name // .ref // ""), "status": gl_status, "conclusion": gl_conclusion,
  "head_sha": (.sha // ""), "head_branch": (.ref // ""), "url": (.web_url // ""),
  "created_at": (.created_at | ts), "updated_at": (.updated_at | ts), "event": (.source // "")};
def norm_job: {
  "id": (.id // null), "name": (.name // ""), "status": gl_status, "conclusion": gl_conclusion,
  "url": (.web_url // ""), "started_at": (.started_at | ts), "completed_at": (.finished_at | ts), "steps": []};
def norm_label: {"name": (.name // ""), "color": ((.color // "") | ltrimstr("#") | ascii_downcase), "description": (.description // "")};
def norm_repo_item: {
  "name": (.path // .name // ""), "full_name": (.path_with_namespace // ""), "default_branch": (.default_branch // ""),
  "private": ((.visibility // "private") != "public"), "url": (.web_url // ""), "clone_url": (.http_url_to_repo // ""),
  "archived": (.archived // false), "description": (.description // "")};
'

# _ordo_provider_gitlab_jq [jq options...] <program>   (the program is the last argument)
_ordo_provider_gitlab_jq() {
  local prog="${*: -1}"
  if [[ $# -gt 1 ]]; then
    jq -c "${@:1:$#-1}" "${_ORDO_PROVIDER_GITLAB_JQ_LIB}${prog}"
  else
    jq -c "${_ORDO_PROVIDER_GITLAB_JQ_LIB}${prog}"
  fi
}

_ordo_provider_gitlab_api() { ordo_provider_http_base_url "/api/v4"; }

# Backend availability hook of ordo_provider_backend_available.
ordo_provider_adapter_gitlab_available() { command -v "${ORDO_PROVIDER_HTTP_CURL:-curl}" >/dev/null 2>&1; }

# projects/<owner%2Frepo>
_ordo_provider_gitlab_project_path() {
  local repo="${ORDO_PV_REPO:?}"
  if [[ "$repo" != */* ]]; then
    ordo_provider_adapter_error bad_argument "repository must be a project path like group/repo, got '${repo}'" false "$(jq -cn --arg r "$repo" '{"repo": $r}')"
    return $?
  fi
  printf 'projects/%s\n' "$(ordo_provider_http_urlencode "$repo")"
}

_ordo_provider_gitlab_call() {
  # <op> <method> <relative-path> [request options...]
  local op="$1" method="$2" rel="$3"
  shift 3
  local base
  base=$(_ordo_provider_gitlab_api) || return $?
  ordo_provider_http_request "$op" "$_ORDO_GITLAB_AUTH" "$method" "${base}/${rel#/}" "$@"
}

_ordo_provider_gitlab_get() {
  _ordo_provider_gitlab_call "$1" GET "$2" || return $?
  ordo_provider_http_json
}

_ordo_provider_gitlab_get_all() {
  # <op> <relative-path(with optional ?query)> [jq-items-expr]
  local base
  base=$(_ordo_provider_gitlab_api) || return $?
  ordo_provider_http_get_all "$1" "$_ORDO_GITLAB_AUTH" "${base}/${2#/}" page per_page "${3:-.}"
}

_ordo_provider_gitlab_json_list() {
  printf '%s\n' "$@" | jq -R . | jq -sc 'map(select(. != ""))'
}

_ordo_provider_gitlab_has_more() {
  # Uses the response headers of the last call: X-Next-Page / X-Total.
  local next total
  next=$(ordo_provider_http_header X-Next-Page)
  [[ -n "$next" ]] && return 0
  total=$(ordo_provider_http_header X-Total)
  if [[ "$total" =~ ^[0-9]+$ ]]; then
    (( ORDO_PV_PAGE * ORDO_PV_LIMIT < total )) && return 0
    return 1
  fi
  ordo_provider_http_has_next
}

_ordo_provider_gitlab_state_param() {
  # <issue|mr> -> GitLab state value for ORDO_PV_STATE (default open)
  case "${ORDO_PV_STATE:-open}" in
    open) printf 'opened\n' ;;
    closed) printf 'closed\n' ;;
    merged) if [[ "$1" == mr ]]; then printf 'merged\n'; else printf 'closed\n'; fi ;;
    all) printf 'all\n' ;;
    *) printf 'opened\n' ;;
  esac
}

# ---------------------------------------------------------------------------
# Read ops
# ---------------------------------------------------------------------------
ordo_provider_adapter_gitlab_auth_status() {
  local base host
  base=$(_ordo_provider_gitlab_api) || return $?
  host=$(ordo_provider_http_host)
  ordo_provider_http_token >/dev/null || return $?
  local rc=0 err
  err=$(mktemp)
  ordo_provider_http_request auth_status "$_ORDO_GITLAB_AUTH" GET "${base}/user" 2> "$err" || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    if [[ "${ORDO_HTTP_STATUS:-}" == 401 || "${ORDO_HTTP_STATUS:-}" == 403 ]]; then
      rm -f "$err"
      jq -cn --arg host "$host" --argjson status "${ORDO_HTTP_STATUS#0}" \
        '{"forge": "gitlab", "authenticated": false, "host": $host, "login": "", "scopes": [], "backend": "rest", "http_status": $status}'
      return 0
    fi
    cat "$err" >&2; rm -f "$err"
    return "$rc"
  fi
  rm -f "$err"
  local user scopes='[]'
  user=$(ordo_provider_http_json) || return $?
  if ordo_provider_http_request auth_status "$_ORDO_GITLAB_AUTH" GET "${base}/personal_access_tokens/self" --allow-404 2>/dev/null && [[ "$ORDO_HTTP_STATUS" == 2* ]]; then
    scopes=$(ordo_provider_http_json 2>/dev/null | jq -c '.scopes // []' 2>/dev/null) || scopes='[]'
  fi
  printf '%s' "$user" | jq -c --arg host "$host" --argjson scopes "$scopes" \
    '{"forge": "gitlab", "authenticated": true, "host": $host, "login": (.username // ""), "scopes": $scopes, "backend": "rest"}'
}

ordo_provider_adapter_gitlab_repo_get() {
  local pp raw
  pp=$(_ordo_provider_gitlab_project_path) || return $?
  raw=$(_ordo_provider_gitlab_get repo_get "$pp") || return $?
  printf '%s' "$raw" | _ordo_provider_gitlab_jq '
    def access_level: (.permissions.project_access.access_level // .permissions.group_access.access_level // 0);
    {"name": (.path // .name // ""), "owner": ((.path_with_namespace // "") | split("/") | .[:-1] | join("/")),
     "full_name": (.path_with_namespace // ""), "default_branch": (.default_branch // ""), "url": (.web_url // ""),
     "private": ((.visibility // "private") != "public"),
     "permission": (access_level as $l | if $l >= 40 then "admin" elif $l >= 30 then "write" elif $l >= 20 then "triage" elif $l >= 10 then "read" else "" end),
     "description": (.description // "")}'
}

ordo_provider_adapter_gitlab_issue_get() {
  local pp raw closed_by
  pp=$(_ordo_provider_gitlab_project_path) || return $?
  raw=$(_ordo_provider_gitlab_get issue_get "$pp/issues/$ORDO_PV_NUMBER") || return $?
  closed_by='[]'
  if _ordo_provider_gitlab_call issue_get GET "$pp/issues/$ORDO_PV_NUMBER/closed_by" --allow-404 2>/dev/null && [[ "$ORDO_HTTP_STATUS" == 2* ]]; then
    closed_by=$(ordo_provider_http_json 2>/dev/null) || closed_by='[]'
  fi
  local payload
  payload=$(printf '%s' "$raw" | _ordo_provider_gitlab_jq --argjson cb "$closed_by" \
    'norm_issue | .closed_by_prs = [ ($cb // [])[] | {"number": .iid, "state": mr_state_of(.state | lc)} ]')
  if [[ ",$ORDO_PV_WITH," == *,comments,* ]]; then
    local notes web
    notes=$(_ordo_provider_gitlab_get_all issue_get "$pp/issues/$ORDO_PV_NUMBER/notes?sort=asc&order_by=created_at") || return $?
    web=$(printf '%s' "$raw" | jq -r '.web_url // ""')
    payload=$(printf '%s' "$payload" | _ordo_provider_gitlab_jq --argjson n "$notes" --arg url "$web" \
      '. + {"comments": [ $n[] | select(.system != true) | norm_note($url) ]}')
  fi
  printf '%s\n' "$payload"
}

ordo_provider_adapter_gitlab_issue_list() {
  local pp query labels body
  pp=$(_ordo_provider_gitlab_project_path) || return $?
  labels=$(IFS=,; printf '%s' "${ORDO_PV_LABELS[*]:-}")
  query=$(ordo_provider_http_query "state=$(_ordo_provider_gitlab_state_param issue)" "labels=$labels" "search=$ORDO_PV_SEARCH" \
    "author_username=$ORDO_PV_AUTHOR" "assignee_username=$ORDO_PV_ASSIGNEE" "milestone=$ORDO_PV_MILESTONE" \
    "page=$ORDO_PV_PAGE" "per_page=$ORDO_PV_LIMIT")
  _ordo_provider_gitlab_call issue_list GET "$pp/issues$query" || return $?
  body=$(ordo_provider_http_json) || return $?
  local has_more=false
  _ordo_provider_gitlab_has_more && has_more=true
  ordo_provider_http_page_shape "$(printf '%s' "$body" | _ordo_provider_gitlab_jq 'map(norm_issue)')" "$ORDO_PV_PAGE" "$ORDO_PV_LIMIT" "$has_more"
}

# review decision of one MR from its approvals (+ the MR's own hints)
_ordo_provider_gitlab_pr_decision() {
  # <pp> <mr-json>
  local pp="$1" mr="$2" approvals
  _ordo_provider_gitlab_call pr_get GET "$pp/merge_requests/$ORDO_PV_NUMBER/approvals" --allow-404 || return $?
  if [[ "$ORDO_HTTP_STATUS" == 2* ]]; then approvals=$(ordo_provider_http_json) || return $?; else approvals='{}'; fi
  printf '%s' "$mr" | _ordo_provider_gitlab_jq -r --argjson a "$approvals" '
    if dms == "requested_changes" then "changes_requested"
    elif (($a.approved_by // []) | length) > 0 and ($a.approved == true or ($a.approvals_left // 0) == 0) then "approved"
    elif ($a.approvals_required // 0) > 0 or dms == "not_approved" then "review_required"
    elif ((.reviewers // []) | length) > 0 then "review_required"
    else "none" end'
}

ordo_provider_adapter_gitlab_pr_get() {
  local pp raw decision
  pp=$(_ordo_provider_gitlab_project_path) || return $?
  raw=$(_ordo_provider_gitlab_get pr_get "$pp/merge_requests/$ORDO_PV_NUMBER") || return $?
  decision=$(_ordo_provider_gitlab_pr_decision "$pp" "$raw") || return $?
  printf '%s' "$raw" | _ordo_provider_gitlab_jq --arg d "$decision" 'norm_pr($d)'
}

ordo_provider_adapter_gitlab_pr_list() {
  local pp query labels body
  pp=$(_ordo_provider_gitlab_project_path) || return $?
  labels=$(IFS=,; printf '%s' "${ORDO_PV_LABELS[*]:-}")
  query=$(ordo_provider_http_query "state=$(_ordo_provider_gitlab_state_param mr)" "target_branch=$ORDO_PV_BASE" "source_branch=$ORDO_PV_HEAD" \
    "labels=$labels" "author_username=$ORDO_PV_AUTHOR" "assignee_username=$ORDO_PV_ASSIGNEE" "search=$ORDO_PV_SEARCH" \
    "page=$ORDO_PV_PAGE" "per_page=$ORDO_PV_LIMIT")
  _ordo_provider_gitlab_call pr_list GET "$pp/merge_requests$query" || return $?
  body=$(ordo_provider_http_json) || return $?
  local has_more=false
  _ordo_provider_gitlab_has_more && has_more=true
  ordo_provider_http_page_shape "$(printf '%s' "$body" | _ordo_provider_gitlab_jq 'map(norm_pr(decision_from_pr))')" "$ORDO_PV_PAGE" "$ORDO_PV_LIMIT" "$has_more"
}

ordo_provider_adapter_gitlab_pr_files() {
  local pp diffs
  pp=$(_ordo_provider_gitlab_project_path) || return $?
  diffs=$(_ordo_provider_gitlab_get_all pr_files "$pp/merge_requests/$ORDO_PV_NUMBER/diffs") || return $?
  printf '%s' "$diffs" | jq -c --argjson n "$ORDO_PV_NUMBER" '
    def count($prefix): ((.diff // "") | split("\n") | map(select(startswith($prefix) and (startswith($prefix + $prefix + $prefix) | not))) | length);
    {"number": $n,
     "files": [ .[] | {"path": (.new_path // .old_path // ""), "additions": count("+"), "deletions": count("-")} ],
     "count": length}'
}

ordo_provider_adapter_gitlab_checks_get() {
  local pp mr sha workflow statuses
  pp=$(_ordo_provider_gitlab_project_path) || return $?
  mr=$(_ordo_provider_gitlab_get checks_get "$pp/merge_requests/$ORDO_PV_NUMBER") || return $?
  sha=$(printf '%s' "$mr" | jq -r '.sha // ""')
  workflow=$(printf '%s' "$mr" | jq -r '.head_pipeline.name // (if .head_pipeline.id then ("pipeline #" + (.head_pipeline.id | tostring)) else "" end)')
  if [[ -z "$sha" ]]; then
    jq -cn --argjson n "$ORDO_PV_NUMBER" '{"number": $n, "sha": "", "checks": [], "summary": {"total": 0, "passed": 0, "failed": 0, "pending": 0, "state": "none"}}'
    return 0
  fi
  statuses=$(_ordo_provider_gitlab_get_all checks_get "$pp/repository/commits/$(ordo_provider_http_urlencode "$sha")/statuses") || return $?
  # One entry per status name: the most recent one wins (retried jobs, older pipelines).
  printf '%s' "$statuses" | _ordo_provider_gitlab_jq --argjson n "$ORDO_PV_NUMBER" --arg sha "$sha" --arg wf "$workflow" '
    ([ group_by(.name)[] | sort_by(.id // 0) | last | norm_status($wf) ]) as $checks
    | {"number": $n, "sha": $sha, "checks": $checks, "summary": ($checks | checks_summary)}'
}

ordo_provider_adapter_gitlab_review_list() {
  local pp mr approvals reviewers
  pp=$(_ordo_provider_gitlab_project_path) || return $?
  mr=$(_ordo_provider_gitlab_get review_list "$pp/merge_requests/$ORDO_PV_NUMBER") || return $?
  approvals='{}'
  if _ordo_provider_gitlab_call review_list GET "$pp/merge_requests/$ORDO_PV_NUMBER/approvals" --allow-404 && [[ "$ORDO_HTTP_STATUS" == 2* ]]; then
    approvals=$(ordo_provider_http_json) || return $?
  fi
  reviewers='[]'
  if _ordo_provider_gitlab_call review_list GET "$pp/merge_requests/$ORDO_PV_NUMBER/reviewers" --allow-404 && [[ "$ORDO_HTTP_STATUS" == 2* ]]; then
    reviewers=$(ordo_provider_http_json) || return $?
  fi
  local decision
  decision=$(_ordo_provider_gitlab_pr_decision "$pp" "$mr") || return $?
  _ordo_provider_gitlab_jq -n --argjson n "$ORDO_PV_NUMBER" --arg d "$decision" --argjson a "$approvals" --argjson r "$reviewers" \
    --arg url "$(printf '%s' "$mr" | jq -r '.web_url // ""')" '
    ([ ($a.approved_by // [])[] | {"author": (.user.username // ""), "state": "approved", "body": "", "submitted_at": null, "url": $url} ]) as $approved
    | ([ $r[] | . as $rv | select(($approved | map(.author) | index($rv.user.username // "")) == null)
         | {"author": (.user.username // ""), "state": reviewer_state, "body": "", "submitted_at": (.created_at | ts), "url": $url} ]) as $rest
    | {"number": $n, "decision": $d, "reviews": ($approved + $rest)}'
}

ordo_provider_adapter_gitlab_run_list() {
  local pp query body status_param="" scope_param=""
  pp=$(_ordo_provider_gitlab_project_path) || return $?
  case "$ORDO_PV_STATE" in
    queued) status_param="pending" ;;
    in_progress) status_param="running" ;;
    completed) scope_param="finished" ;;
    "") ;;
    *) status_param="$ORDO_PV_STATE" ;;
  esac
  query=$(ordo_provider_http_query "ref=$ORDO_PV_BRANCH" "sha=$ORDO_PV_COMMIT" "status=$status_param" "scope=$scope_param" "name=$ORDO_PV_WORKFLOW" \
    "page=$ORDO_PV_PAGE" "per_page=$ORDO_PV_LIMIT")
  _ordo_provider_gitlab_call run_list GET "$pp/pipelines$query" || return $?
  body=$(ordo_provider_http_json) || return $?
  local has_more=false
  _ordo_provider_gitlab_has_more && has_more=true
  ordo_provider_http_page_shape "$(printf '%s' "$body" | _ordo_provider_gitlab_jq --arg st "$ORDO_PV_STATE" 'map(norm_run) | map(select($st == "" or $st == "completed" or .status == $st or ($st == "queued" and .status == "queued") or ($st == "in_progress" and .status == "in_progress")))')" "$ORDO_PV_PAGE" "$ORDO_PV_LIMIT" "$has_more"
}

ordo_provider_adapter_gitlab_run_get() {
  local pp raw jobs payload
  pp=$(_ordo_provider_gitlab_project_path) || return $?
  raw=$(_ordo_provider_gitlab_get run_get "$pp/pipelines/$ORDO_PV_NUMBER") || return $?
  jobs=$(_ordo_provider_gitlab_get_all run_get "$pp/pipelines/$ORDO_PV_NUMBER/jobs") || return $?
  payload=$(printf '%s' "$raw" | _ordo_provider_gitlab_jq --argjson jobs "$jobs" 'norm_run + {"jobs": [ $jobs[] | norm_job ]}')
  if [[ ",$ORDO_PV_WITH," == *,log_failed,* ]]; then
    local log="" job_id job_name chunk
    while IFS=$'\t' read -r job_id job_name; do
      [[ -n "$job_id" ]] || continue
      _ordo_provider_gitlab_call run_get GET "$pp/jobs/$job_id/trace" --accept "text/plain" --allow-404 2>/dev/null || continue
      [[ "$ORDO_HTTP_STATUS" == 2* ]] || continue
      chunk=$(printf '%s\n' "$ORDO_HTTP_BODY" | sed "s/^/${job_name//\//\\/}\t/")
      log="${log}${chunk}"$'\n'
    done < <(printf '%s' "$payload" | jq -r '.jobs[] | select(.conclusion == "failure" or .conclusion == "cancelled") | [(.id | tostring), .name] | @tsv')
    log=$(ordo_provider_http_mask "$(printf '%s' "$log" | head -c "${ORDO_PROVIDER_LOG_MAX_BYTES:-200000}")")
    payload=$(printf '%s' "$payload" | jq -c --arg log "$log" '.log_failed = $log')
  fi
  if [[ ",$ORDO_PV_WITH," == *,log,* ]]; then
    local full
    full=$(_ordo_provider_gitlab_job_traces "$pp" "$(printf '%s' "$payload" | jq -r '.jobs[] | [(.id | tostring), .name] | @tsv')")
    payload=$(printf '%s' "$payload" | jq -c --arg log "$full" '.log = $log')
  fi
  printf '%s\n' "$payload"
}

# _ordo_provider_gitlab_job_traces <pp> <tsv id\tname lines> -> masked, capped text
_ordo_provider_gitlab_job_traces() {
  local pp="$1" log="" job_id job_name chunk
  while IFS=$'\t' read -r job_id job_name; do
    [[ -n "$job_id" ]] || continue
    _ordo_provider_gitlab_call run_get GET "$pp/jobs/$job_id/trace" --accept "text/plain" --allow-404 2>/dev/null || continue
    [[ "$ORDO_HTTP_STATUS" == 2* ]] || continue
    chunk=$(printf '%s\n' "$ORDO_HTTP_BODY" | sed "s/^/${job_name//\//\\/}\t/")
    log="${log}${chunk}"$'\n'
  done <<< "$2"
  ordo_provider_http_mask "$(printf '%s' "$log" | head -c "${ORDO_PROVIDER_LOG_MAX_BYTES:-200000}")"
}

# ---------------------------------------------------------------------------
# Read ops added by #818
# ---------------------------------------------------------------------------
ordo_provider_adapter_gitlab_label_list() {
  local pp query body has_more=false
  pp=$(_ordo_provider_gitlab_project_path) || return $?
  query=$(ordo_provider_http_query "page=$ORDO_PV_PAGE" "per_page=$ORDO_PV_LIMIT")
  _ordo_provider_gitlab_call label_list GET "$pp/labels$query" || return $?
  body=$(ordo_provider_http_json) || return $?
  _ordo_provider_gitlab_has_more && has_more=true
  ordo_provider_http_page_shape "$(printf '%s' "$body" | _ordo_provider_gitlab_jq 'map(norm_label)')" "$ORDO_PV_PAGE" "$ORDO_PV_LIMIT" "$has_more"
}

ordo_provider_adapter_gitlab_repo_list() {
  local owner query body has_more=false
  owner=$(ordo_provider_http_urlencode "$ORDO_PV_OWNER")
  query=$(ordo_provider_http_query "page=$ORDO_PV_PAGE" "per_page=$ORDO_PV_LIMIT")
  _ordo_provider_gitlab_call repo_list GET "groups/$owner/projects$query" --allow-404 || return $?
  if [[ "$ORDO_HTTP_STATUS" == 404 ]]; then
    _ordo_provider_gitlab_call repo_list GET "users/$owner/projects$query" || return $?
  fi
  body=$(ordo_provider_http_json) || return $?
  _ordo_provider_gitlab_has_more && has_more=true
  ordo_provider_http_page_shape "$(printf '%s' "$body" | _ordo_provider_gitlab_jq 'map(norm_repo_item)')" "$ORDO_PV_PAGE" "$ORDO_PV_LIMIT" "$has_more" \
    | jq -c --arg owner "$ORDO_PV_OWNER" '{"owner": $owner} + .'
}

# GitLab has no workflow registry: the CI configuration file is the one
# "workflow" of a project. Its presence on the default branch is reported as
# one active workflow, its absence as an empty list (details.capability="emulated").
ordo_provider_adapter_gitlab_workflow_list() {
  local pp project ci_path branch items='[]'
  pp=$(_ordo_provider_gitlab_project_path) || return $?
  project=$(_ordo_provider_gitlab_get workflow_list "$pp") || return $?
  ci_path=$(printf '%s' "$project" | jq -r '(.ci_config_path // "") | if . == "" then ".gitlab-ci.yml" else (split("@")[0] | if . == "" then ".gitlab-ci.yml" else . end) end')
  branch=$(printf '%s' "$project" | jq -r '.default_branch // ""')
  _ordo_provider_gitlab_call workflow_list GET "$pp/repository/files/$(ordo_provider_http_urlencode "$ci_path")$(ordo_provider_http_query "ref=$branch")" --allow-404 || return $?
  if [[ "$ORDO_HTTP_STATUS" == 2* ]]; then
    items=$(jq -cn --arg p "$ci_path" '[{"id": null, "name": ($p | split("/") | last | sub("\\.ya?ml$"; "")), "path": $p, "state": "active"}]')
  fi
  items=$(printf '%s' "$items" | jq -c --arg st "$ORDO_PV_STATE" 'map(select($st == "" or $st == "all" or .state == $st))')
  ordo_provider_http_paginate_local "$items" "$ORDO_PV_PAGE" "$ORDO_PV_LIMIT" | jq -c '. + {"details": {"capability": "emulated"}}'
}

ordo_provider_adapter_gitlab_branch_protection_get() {
  local pp branch="$ORDO_PV_BRANCH" rule=""
  pp=$(_ordo_provider_gitlab_project_path) || return $?
  _ordo_provider_gitlab_call branch_protection_get GET "$pp/protected_branches/$(ordo_provider_http_urlencode "$branch")" --allow-404 || return $?
  if [[ "$ORDO_HTTP_STATUS" == 2* ]]; then
    rule=$(ordo_provider_http_json) || return $?
  else
    local rules pattern
    rules=$(_ordo_provider_gitlab_get_all branch_protection_get "$pp/protected_branches") || return $?
    while IFS= read -r pattern; do
      [[ -n "$pattern" ]] || continue
      [[ -z "$rule" || "$rule" == null ]] || continue  # first match wins; keep draining the producer
      # shellcheck disable=SC2254 # protected branch names are wildcards by design
      case "$branch" in
        $pattern) rule=$(printf '%s' "$rules" | jq -c --arg p "$pattern" '[ .[] | select((.name // "") == $p) ][0]') ;;
      esac
    done < <(printf '%s' "$rules" | jq -r '.[] | (.name // "") | select(. != "")')
  fi
  if [[ -z "$rule" || "$rule" == null ]]; then
    jq -cn --arg b "$branch" '{"branch": $b, "protected": false, "required_checks": [], "required_reviews": 0, "enforce_admins": false}'
    return 0
  fi
  local approval_rules='[]' status_checks='[]'
  if _ordo_provider_gitlab_call branch_protection_get GET "$pp/approval_rules" --allow-404 2>/dev/null && [[ "$ORDO_HTTP_STATUS" == 2* ]]; then
    approval_rules=$(ordo_provider_http_json 2>/dev/null) || approval_rules='[]'
  fi
  if _ordo_provider_gitlab_call branch_protection_get GET "$pp/external_status_checks" --allow-404 2>/dev/null && [[ "$ORDO_HTTP_STATUS" == 2* ]]; then
    status_checks=$(ordo_provider_http_json 2>/dev/null) || status_checks='[]'
  fi
  jq -cn --arg b "$branch" --argjson ar "$approval_rules" --argjson sc "$status_checks" '
    def glob_re($p): "^" + ($p | gsub("\\."; "\\\\.") | gsub("\\*"; ".*")) + "$";
    def applies: (.applies_to_all_protected_branches == true) or ((.protected_branches // []) | length) == 0
                 or ((.protected_branches // []) | any((.name // "") as $p | $p != "" and ($b | test(glob_re($p)))));
    {"branch": $b, "protected": true,
     "required_checks": ([ ($sc | if type == "array" then .[] else empty end) | select(applies) | .name ] | unique),
     "required_reviews": ([ ($ar | if type == "array" then .[] else empty end) | select(applies) | (.approvals_required // 0) ] | max // 0),
     "enforce_admins": false}'
}

# check_annotations (emulated): the tail of the trace of each failed job.
_ordo_provider_gitlab_trace_annotations() {
  # <pp> <jobs-json (native)> -> annotations array
  local pp="$1" all='[]' job id name conclusion tail
  while IFS= read -r job; do
    [[ -n "$job" ]] || continue
    id=$(printf '%s' "$job" | jq -r '.id // empty')
    [[ -n "$id" ]] || continue
    name=$(printf '%s' "$job" | jq -r '.name // ""')
    conclusion=$(printf '%s' "$job" | _ordo_provider_gitlab_jq -r 'gl_conclusion // "null"')
    _ordo_provider_gitlab_call check_annotations GET "$pp/jobs/$id/trace" --accept "text/plain" --allow-404 2>/dev/null || continue
    [[ "$ORDO_HTTP_STATUS" == 2* ]] || continue
    tail=$(ordo_provider_http_tail_lines "$ORDO_HTTP_BODY")
    all=$(jq -cn --argjson a "$all" --argjson id "$id" --arg name "$name" --arg c "$conclusion" --arg t "$tail" \
      '$a + [{"check_id": $id, "check_name": $name, "check_conclusion": (if $c == "null" then null else $c end),
              "path": "", "line": null, "end_line": null, "level": "failure", "title": "job trace tail", "message": $t}]')
  done < <(printf '%s' "$2" | _ordo_provider_gitlab_jq '.[] | select(gl_conclusion == "failure" or gl_conclusion == "cancelled")')
  printf '%s\n' "$all"
}

ordo_provider_adapter_gitlab_check_annotations() {
  local pp jobs='[]' subject pipeline=""
  pp=$(_ordo_provider_gitlab_project_path) || return $?
  case "$ORDO_PV_SUBJECT" in
    check)
      jobs=$(_ordo_provider_gitlab_get check_annotations "$pp/jobs/$ORDO_PV_CHECK" | jq -c '[.]') || return $?
      subject=$(jq -cn --argjson id "$ORDO_PV_CHECK" '{"kind": "check", "id": $id}') ;;
    run)
      pipeline="$ORDO_PV_RUN"
      subject=$(jq -cn --argjson id "$ORDO_PV_RUN" '{"kind": "run", "id": $id}') ;;
    pr)
      local mr
      mr=$(_ordo_provider_gitlab_get check_annotations "$pp/merge_requests/$ORDO_PV_NUMBER") || return $?
      pipeline=$(printf '%s' "$mr" | jq -r '.head_pipeline.id // empty')
      subject=$(jq -cn --argjson n "$ORDO_PV_NUMBER" --arg sha "$(printf '%s' "$mr" | jq -r '.sha // ""')" '{"kind": "pr", "id": $n, "sha": $sha}') ;;
    *)
      local pipes
      pipes=$(_ordo_provider_gitlab_get check_annotations "$pp/pipelines$(ordo_provider_http_query "sha=$ORDO_PV_REF" "per_page=1")") || return $?
      pipeline=$(printf '%s' "$pipes" | jq -r '.[0].id // empty')
      subject=$(jq -cn --arg sha "$ORDO_PV_REF" '{"kind": "ref", "id": $sha, "sha": $sha}') ;;
  esac
  if [[ -n "$pipeline" ]]; then
    jobs=$(_ordo_provider_gitlab_get_all check_annotations "$pp/pipelines/$pipeline/jobs") || return $?
  fi
  local all
  all=$(_ordo_provider_gitlab_trace_annotations "$pp" "$jobs")
  jq -cn --argjson s "$subject" --argjson a "$all" '{"subject": $s, "annotations": $a, "count": ($a | length),
    "details": {"capability": "emulated", "reason": "GitLab has no check annotations; each failed job contributes the tail of its trace"}}'
}

ordo_provider_adapter_gitlab_pr_files_batch() {
  local pp n diffs items='[]' missing='[]'
  pp=$(_ordo_provider_gitlab_project_path) || return $?
  for n in "${ORDO_PV_NUMBERS[@]}"; do
    _ordo_provider_gitlab_call pr_files_batch GET "$pp/merge_requests/$n/diffs?page=1&per_page=1" --allow-404 || return $?
    if [[ "$ORDO_HTTP_STATUS" == 404 ]]; then
      missing=$(jq -cn --argjson m "$missing" --argjson n "$n" '$m + [$n]')
      continue
    fi
    diffs=$(_ordo_provider_gitlab_get_all pr_files_batch "$pp/merge_requests/$n/diffs") || return $?
    items=$(jq -cn --argjson a "$items" --argjson n "$n" --argjson d "$diffs" '
      def count($prefix): ((.diff // "") | split("\n") | map(select(startswith($prefix) and (startswith($prefix + $prefix + $prefix) | not))) | length);
      $a + [{"number": $n, "files": [ $d[] | {"path": (.new_path // .old_path // ""), "additions": count("+"), "deletions": count("-")} ], "count": ($d | length)}]')
  done
  jq -cn --argjson items "$items" --argjson missing "$missing" \
    '{"items": ($items | sort_by(.number)), "count": ($items | length), "missing": ($missing | unique)}'
}

# ---------------------------------------------------------------------------
# Mutations
# ---------------------------------------------------------------------------
_ordo_provider_gitlab_user_ids() {
  # <usernames...> -> JSON array of ids (unknown username => not_found)
  local ids='[]' u id
  for u in "$@"; do
    [[ -n "$u" ]] || continue
    _ordo_provider_gitlab_call issue_edit GET "users$(ordo_provider_http_query "username=$u")" || return $?
    id=$(ordo_provider_http_json | jq -r '.[0].id // empty')
    if [[ -z "$id" ]]; then
      ordo_provider_adapter_error not_found "user not found on the forge: ${u}" false "$(jq -cn --arg u "$u" '{"username": $u}')"
      return $?
    fi
    ids=$(printf '%s' "$ids" | jq -c --argjson id "$id" '. + [$id]')
  done
  printf '%s\n' "$ids"
}

_ordo_provider_gitlab_milestone_id() {
  # <pp> <title> -> id or null
  local pp="$1" title="$2" id
  [[ -n "$title" ]] || { printf 'null\n'; return 0; }
  if [[ "$title" =~ ^[0-9]+$ ]]; then printf '%s\n' "$title"; return 0; fi
  _ordo_provider_gitlab_call issue_edit GET "$pp/milestones$(ordo_provider_http_query "title=$title" "state=all")" || return $?
  id=$(ordo_provider_http_json | jq -r '.[0].id // empty')
  if [[ -z "$id" ]]; then
    ordo_provider_adapter_error not_found "milestone not found: ${title}" false "$(jq -cn --arg t "$title" '{"milestone": $t}')"
    return $?
  fi
  printf '%s\n' "$id"
}

ordo_provider_adapter_gitlab_issue_create() {
  local pp body assignee_ids ms labels
  pp=$(_ordo_provider_gitlab_project_path) || return $?
  assignee_ids=$(_ordo_provider_gitlab_user_ids "${ORDO_PV_ADD_ASSIGNEES[@]}") || return $?
  ms=$(_ordo_provider_gitlab_milestone_id "$pp" "$ORDO_PV_MILESTONE") || return $?
  labels=$(IFS=,; printf '%s' "${ORDO_PV_LABELS[*]:-}")
  body=$(jq -cn --arg title "$ORDO_PV_TITLE" --rawfile desc "$(ordo_provider_http_body_path)" --arg labels "$labels" --argjson a "$assignee_ids" --argjson ms "$ms" \
    '{"title": $title, "description": $desc} + (if $labels != "" then {"labels": $labels} else {} end)
     + (if ($a | length) > 0 then {"assignee_ids": $a} else {} end) + (if $ms != null then {"milestone_id": $ms} else {} end)')
  _ordo_provider_gitlab_call issue_create POST "$pp/issues" --body "$body" --mutation || return $?
  ordo_provider_http_json | jq -c '{"number": (.iid // null), "url": (.web_url // "")}'
}

ordo_provider_adapter_gitlab_issue_comment() {
  if [[ -z "${ORDO_PV_BODY_PATH:-}" ]]; then
    ordo_provider_adapter_error usage "issue_comment requires --body or --body-file" false '{"missing":"body"}'
    return $?
  fi
  local pp body
  pp=$(_ordo_provider_gitlab_project_path) || return $?
  body=$(jq -cn --rawfile body "$ORDO_PV_BODY_PATH" '{"body": $body}')
  _ordo_provider_gitlab_call issue_comment POST "$pp/issues/$ORDO_PV_NUMBER/notes" --body "$body" --mutation || return $?
  ordo_provider_http_json | jq -c --argjson n "$ORDO_PV_NUMBER" --arg root "$(ordo_provider_http_web_root)" --arg repo "$ORDO_PV_REPO" \
    '{"number": $n, "url": ($root + "/" + $repo + "/-/issues/" + ($n | tostring) + "#note_" + ((.id // "") | tostring))}'
}

_ordo_provider_gitlab_edit_common() {
  # <topic:issue|pr>
  local topic="$1" pp kind path op
  pp=$(_ordo_provider_gitlab_project_path) || return $?
  if [[ "$topic" == pr ]]; then kind=merge_requests; else kind=issues; fi
  path="$pp/$kind/$ORDO_PV_NUMBER"
  op="${topic}_edit"
  case "$ORDO_PV_STATE" in
    closed|open)
      local ev=close
      [[ "$ORDO_PV_STATE" == open ]] && ev=reopen
      _ordo_provider_gitlab_call "$op" PUT "$path" --body "$(jq -cn --arg e "$ev" '{"state_event": $e}')" --mutation || return $?
      if [[ "$ORDO_PV_STATE" == closed && -n "${ORDO_PV_BODY_PATH:-}" ]]; then
        _ordo_provider_gitlab_call "$op" POST "$path/notes" --body "$(jq -cn --rawfile b "$ORDO_PV_BODY_PATH" '{"body": $b}')" --mutation || return $?
      fi
      jq -cn --argjson n "$ORDO_PV_NUMBER" --arg s "$ORDO_PV_STATE" '{"number": $n, "state": $s}'
      return 0
      ;;
  esac
  local patch='{}' changes=0
  if [[ -n "$ORDO_PV_TITLE" ]]; then patch=$(printf '%s' "$patch" | jq -c --arg t "$ORDO_PV_TITLE" '.title = $t'); changes=1; fi
  if [[ -n "${ORDO_PV_BODY_PATH:-}" ]]; then patch=$(printf '%s' "$patch" | jq -c --rawfile b "$ORDO_PV_BODY_PATH" '.description = $b'); changes=1; fi
  if [[ "$topic" == pr && -n "$ORDO_PV_BASE" ]]; then patch=$(printf '%s' "$patch" | jq -c --arg b "$ORDO_PV_BASE" '.target_branch = $b'); changes=1; fi
  if [[ -n "$ORDO_PV_MILESTONE" ]]; then
    local ms
    ms=$(_ordo_provider_gitlab_milestone_id "$pp" "$ORDO_PV_MILESTONE") || return $?
    patch=$(printf '%s' "$patch" | jq -c --argjson m "$ms" '.milestone_id = $m'); changes=1
  fi
  if [[ "${#ORDO_PV_ADD_LABELS[@]}" -gt 0 ]]; then
    patch=$(printf '%s' "$patch" | jq -c --arg l "$(IFS=,; printf '%s' "${ORDO_PV_ADD_LABELS[*]}")" '.add_labels = $l'); changes=1
  fi
  if [[ "${#ORDO_PV_REMOVE_LABELS[@]}" -gt 0 ]]; then
    patch=$(printf '%s' "$patch" | jq -c --arg l "$(IFS=,; printf '%s' "${ORDO_PV_REMOVE_LABELS[*]}")" '.remove_labels = $l'); changes=1
  fi
  if [[ "${#ORDO_PV_ADD_ASSIGNEES[@]}" -gt 0 || "${#ORDO_PV_REMOVE_ASSIGNEES[@]}" -gt 0 ]]; then
    # assignee_ids replaces the list: read, merge, resolve ids, write back.
    local current wanted ids
    current=$(_ordo_provider_gitlab_get "$op" "$path" | jq -c '[.assignees[]?.username]') || return $?
    wanted=$(jq -cn --argjson cur "$current" --argjson add "$(_ordo_provider_gitlab_json_list "${ORDO_PV_ADD_ASSIGNEES[@]}")" \
      --argjson remove "$(_ordo_provider_gitlab_json_list "${ORDO_PV_REMOVE_ASSIGNEES[@]}")" '(($cur + $add) | unique) - $remove')
    mapfile -t wanted_arr < <(printf '%s' "$wanted" | jq -r '.[]')
    ids=$(_ordo_provider_gitlab_user_ids "${wanted_arr[@]}") || return $?
    patch=$(printf '%s' "$patch" | jq -c --argjson ids "$ids" '.assignee_ids = (if ($ids | length) == 0 then [0] else $ids end)'); changes=1
  fi
  if [[ "$changes" -eq 0 ]]; then
    ordo_provider_adapter_error usage "${op} needs at least one change (--title, --body, --add-label, --state, ...)" false \
      "$(jq -cn --arg op "$op" '{"op": $op, "missing": "change"}')"
    return $?
  fi
  _ordo_provider_gitlab_call "$op" PUT "$path" --body "$patch" --mutation || return $?
  ordo_provider_http_json | jq -c --argjson n "$ORDO_PV_NUMBER" \
    --argjson add "$(_ordo_provider_gitlab_json_list "${ORDO_PV_ADD_LABELS[@]}")" \
    --argjson remove "$(_ordo_provider_gitlab_json_list "${ORDO_PV_REMOVE_LABELS[@]}")" \
    '{"number": $n, "url": (.web_url // ""), "labels_added": $add, "labels_removed": $remove}'
}

ordo_provider_adapter_gitlab_issue_edit() { _ordo_provider_gitlab_edit_common issue; }
ordo_provider_adapter_gitlab_pr_edit() { _ordo_provider_gitlab_edit_common pr; }

ordo_provider_adapter_gitlab_issue_labels() {
  if [[ "${#ORDO_PV_ADD_LABELS[@]}" -eq 0 && "${#ORDO_PV_REMOVE_LABELS[@]}" -eq 0 ]]; then
    ordo_provider_adapter_error usage "issue_labels needs --add <label> and/or --remove <label>" false '{"missing":"labels"}'
    return $?
  fi
  ORDO_PV_ADD_ASSIGNEES=() ORDO_PV_REMOVE_ASSIGNEES=() ORDO_PV_TITLE="" ORDO_PV_BODY_PATH="" ORDO_PV_MILESTONE="" ORDO_PV_STATE=""
  _ordo_provider_gitlab_edit_common issue
}

_ordo_provider_gitlab_is_draft_title() {
  local lower
  lower=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  [[ "$lower" == draft:* || "$lower" == "[draft]"* || "$lower" == "(draft)"* || "$lower" == wip:* || "$lower" == "[wip]"* ]]
}

_ordo_provider_gitlab_strip_draft() {
  local title="$1"
  title=$(printf '%s' "$title" | sed -E 's/^[[:space:]]*(\[draft\]|\(draft\)|draft:|\[wip\]|wip:)[[:space:]]*//I')
  printf '%s\n' "$title"
}

ordo_provider_adapter_gitlab_pr_create() {
  local pp base title body assignee_ids labels
  pp=$(_ordo_provider_gitlab_project_path) || return $?
  base="$ORDO_PV_BASE"
  if [[ -z "$base" ]]; then
    base=$(_ordo_provider_gitlab_get pr_create "$pp" | jq -r '.default_branch // ""') || return $?
  fi
  title="$ORDO_PV_TITLE"
  if [[ "$ORDO_PV_DRAFT" -eq 1 ]] && ! _ordo_provider_gitlab_is_draft_title "$title"; then
    title="${ORDO_GITLAB_DRAFT_PREFIX} $title"
  fi
  assignee_ids=$(_ordo_provider_gitlab_user_ids "${ORDO_PV_ADD_ASSIGNEES[@]}") || return $?
  labels=$(IFS=,; printf '%s' "${ORDO_PV_LABELS[*]:-}")
  body=$(jq -cn --arg title "$title" --rawfile desc "$(ordo_provider_http_body_path)" --arg head "$ORDO_PV_HEAD" --arg base "$base" \
    --arg labels "$labels" --argjson a "$assignee_ids" \
    '{"source_branch": $head, "target_branch": $base, "title": $title, "description": $desc}
     + (if $labels != "" then {"labels": $labels} else {} end) + (if ($a | length) > 0 then {"assignee_ids": $a} else {} end)')
  _ordo_provider_gitlab_call pr_create POST "$pp/merge_requests" --body "$body" --mutation || return $?
  ordo_provider_http_json | jq -c --arg head "$ORDO_PV_HEAD" --arg base "$base" --argjson draft "$([[ "$ORDO_PV_DRAFT" -eq 1 ]] && echo true || echo false)" \
    '{"number": (.iid // null), "url": (.web_url // ""), "head": {"ref": (.source_branch // $head)}, "base": {"ref": (.target_branch // $base)}, "draft": (.draft // $draft)}'
}

ordo_provider_adapter_gitlab_pr_ready() {
  local pp mr title new_title
  pp=$(_ordo_provider_gitlab_project_path) || return $?
  mr=$(_ordo_provider_gitlab_get pr_ready "$pp/merge_requests/$ORDO_PV_NUMBER") || return $?
  title=$(printf '%s' "$mr" | jq -r '.title // ""')
  if [[ "$ORDO_PV_UNDO" -eq 1 ]]; then
    new_title="$title"
    _ordo_provider_gitlab_is_draft_title "$title" || new_title="${ORDO_GITLAB_DRAFT_PREFIX} $title"
  else
    new_title=$(_ordo_provider_gitlab_strip_draft "$title")
  fi
  if [[ "$new_title" != "$title" ]]; then
    _ordo_provider_gitlab_call pr_ready PUT "$pp/merge_requests/$ORDO_PV_NUMBER" --body "$(jq -cn --arg t "$new_title" '{"title": $t}')" --mutation || return $?
  fi
  jq -cn --argjson n "$ORDO_PV_NUMBER" --argjson draft "$([[ "$ORDO_PV_UNDO" -eq 1 ]] && echo true || echo false)" '{"number": $n, "draft": $draft}'
}

ordo_provider_adapter_gitlab_pr_merge() {
  local pp method="${ORDO_PV_METHOD:-squash}"
  pp=$(_ordo_provider_gitlab_project_path) || return $?
  case "$method" in
    squash|merge|rebase) ;;
    *)
      ordo_provider_adapter_error bad_argument "unknown merge method '${method}' (squash|merge|rebase)" false "$(jq -cn --arg m "$method" '{"method": $m}')"
      return $?
      ;;
  esac
  local merged=true action=merged
  if [[ "$ORDO_PV_DISABLE_AUTO" -eq 1 ]]; then
    _ordo_provider_gitlab_call pr_merge POST "$pp/merge_requests/$ORDO_PV_NUMBER/cancel_merge_when_pipeline_succeeds" --mutation || return $?
    merged=false; action=auto_merge_disabled
  else
    local body
    body=$(jq -cn --argjson squash "$([[ "$method" == squash ]] && echo true || echo false)" \
      --argjson del "$([[ "$ORDO_PV_DELETE_BRANCH" -eq 1 ]] && echo true || echo false)" \
      --argjson auto "$([[ "$ORDO_PV_AUTO" -eq 1 ]] && echo true || echo false)" \
      '{"squash": $squash, "should_remove_source_branch": $del, "merge_when_pipeline_succeeds": $auto}')
    _ordo_provider_gitlab_call pr_merge PUT "$pp/merge_requests/$ORDO_PV_NUMBER/merge" --body "$body" --mutation || return $?
    if [[ "$ORDO_PV_AUTO" -eq 1 ]]; then
      merged=false; action=auto_merge_enabled
    elif [[ "$(ordo_provider_http_json 2>/dev/null | jq -r '.state // "merged"')" != merged ]]; then
      # GitLab answers 200 with the MR; auto-merge scheduled by a project setting shows as not merged yet
      merged=false; action=auto_merge_enabled
    fi
  fi
  jq -cn --argjson n "$ORDO_PV_NUMBER" --arg m "$method" --argjson merged "$merged" --arg action "$action" \
    --argjson admin "$([[ "$ORDO_PV_ADMIN" -eq 1 ]] && echo true || echo false)" \
    '{"number": $n, "merged": $merged, "action": $action, "method": $m, "admin": $admin}'
}

ordo_provider_adapter_gitlab_mutate() {
  ordo_provider_http_native_mutate gitlab "/api/v4" "$_ORDO_GITLAB_AUTH"
}

# pr_review <n> --event approve|request_changes|comment [--body] (#818).
ordo_provider_adapter_gitlab_pr_review() {
  local pp state url
  pp=$(_ordo_provider_gitlab_project_path) || return $?
  local mr_path="$pp/merge_requests/$ORDO_PV_NUMBER"
  local note_body=""
  [[ -n "${ORDO_PV_BODY_PATH:-}" ]] && note_body=$(jq -cn --rawfile b "$ORDO_PV_BODY_PATH" '{"body": $b}')
  case "$ORDO_PV_EVENT" in
    approve)
      state=approved
      _ordo_provider_gitlab_call pr_review POST "$mr_path/approve" --body '{}' --mutation --privileged || return $?
      ;;
    request_changes)
      state=changes_requested
      # No "request changes" endpoint: withdraw the approval (404 = none) and leave the note.
      _ordo_provider_gitlab_call pr_review POST "$mr_path/unapprove" --body '{}' --mutation --privileged --allow-404 || return $?
      ;;
    *) state=commented ;;
  esac
  if [[ -n "$note_body" ]]; then
    _ordo_provider_gitlab_call pr_review POST "$mr_path/notes" --body "$note_body" --mutation --privileged || return $?
  fi
  url="$(ordo_provider_http_web_root)/${ORDO_PV_REPO}/-/merge_requests/${ORDO_PV_NUMBER}"
  jq -cn --argjson n "$ORDO_PV_NUMBER" --arg e "$ORDO_PV_EVENT" --arg s "$state" --arg url "$url" \
    '{"number": $n, "event": $e, "state": $s, "url": $url}'
}
