#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2153 # jq programs use $vars; ORDO_PV_* are set by the generic layer
# lib/ordo_provider_adapter_forgejo.sh — Forgejo / Gitea backend of the
# provider adapter (#815, epic #806). REST API v1 through curl
# (lib/ordo_provider_adapter_http.sh); no CLI, no `gh`.
#
# Configuration:
#   ORDO_FORGE_URL         instance base (https://forge.example); the API base
#                          is $ORDO_FORGE_URL/api/v1 (a URL already ending in
#                          /api/v1 is accepted as-is)
#   ORDO_FORGE_REPO        owner/repo (or --repo)
#   ORDO_FORGE_TOKEN_FILE  0600 file holding an access token ("Authorization:
#                          token <t>"); ORDO_FORGE_TOKEN env is the fallback
#   ORDO_FORGEJO_WIP_PREFIXES  "|"-separated draft prefixes recognised on PR
#                          titles (default "WIP:|[WIP]|Draft:|[Draft]"); the
#                          first one is used by pr_ready --undo / pr_create --draft
#
# Every op prints the bare normalised payload of docs/architecture/adapters.md;
# the generic layer adds the envelope / receipt, asserts the mutation policy
# and keeps the idempotency ledger — this file never calls the gate itself.
#
# Native mapping (see docs/architecture/providers.md for the capability matrix):
#   auth_status   GET /user
#   repo_get      GET /repos/{o}/{r}
#   issue_get     GET /repos/{o}/{r}/issues/{n} [+ /comments]
#   issue_list    GET /repos/{o}/{r}/issues?type=issues&state=&labels=&q=&page=&limit=
#   pr_get        GET /repos/{o}/{r}/pulls/{n} + /reviews (review_decision derived)
#   pr_list       GET /repos/{o}/{r}/pulls?state=&labels=&page=&limit= (base/head/author/
#                 assignee/search filtered locally over up to ORDO_PROVIDER_HTTP_MAX_PAGES pages)
#   pr_files      GET /repos/{o}/{r}/pulls/{n}/files (all pages)
#   checks_get    GET /repos/{o}/{r}/commits/{sha}/status (combined statuses; Forgejo
#                 Actions jobs appear as "<workflow> / <job> (<event>)" contexts)
#   review_list   GET /repos/{o}/{r}/pulls/{n}/reviews
#   run_list      GET /repos/{o}/{r}/actions/runs (fallback /actions/tasks; absent =>
#                 empty list with details.capability="unsupported")
#   run_get       GET /repos/{o}/{r}/actions/runs/{id} [+ /jobs, + /actions/jobs/{id}/logs]
#   issue_create  POST /repos/{o}/{r}/issues (label names resolved to ids)
#   issue_edit    PATCH /repos/{o}/{r}/issues/{n} (+ label add/remove endpoints)
#   issue_comment POST /repos/{o}/{r}/issues/{n}/comments
#   issue_labels  POST /repos/{o}/{r}/issues/{n}/labels / DELETE .../labels/{id}
#   pr_create     POST /repos/{o}/{r}/pulls (draft = WIP title prefix)
#   pr_edit       PATCH /repos/{o}/{r}/pulls/{n}
#   pr_ready      PATCH title without/with the WIP prefix (no draft field in the API)
#   pr_merge      POST /repos/{o}/{r}/pulls/{n}/merge {Do, delete_branch_after_merge,
#                 merge_when_checks_succeed, force_merge}; --disable-auto = DELETE .../merge
#   mutate        native REST passthrough: -- --method M --path P [--body J|--body-file F]
#   label_list    GET /repos/{o}/{r}/labels?page=&limit= (#818)
#   repo_list     GET /orgs/{owner}/repos (404 -> GET /users/{owner}/repos) (#818)
#   workflow_list GET /repos/{o}/{r}/actions/workflows (Forgejo >= v12 / Gitea >= 1.24);
#                 404 -> emulated from the tree (.forgejo/workflows, .github/workflows) (#818)
#   branch_protection_get  GET /repos/{o}/{r}/branch_protections/{name}; 404 -> the rule list,
#                 matched by rule_name glob; none -> protected=false (#818)
#   check_annotations  unsupported (no annotation API): empty + details.capability="unsupported" (#818)
#   run_get --with log  GET /actions/jobs/{id}/logs of every job (#818)
#   pr_review     POST /repos/{o}/{r}/pulls/{n}/reviews {event, body} (privileged token) (#818)
#   pr_files_batch  GET /repos/{o}/{r}/pulls/{n}/files per number (404 -> "missing") (#818)
#
# Privileged paths (pr_merge --admin, pr_review) send ORDO_FORGE_ADMIN_TOKEN_FILE /
# ORDO_FORGE_ADMIN_TOKEN when configured (lib/ordo_provider_adapter_http.sh).
#
# Loaded on demand by lib/ordo_provider_adapter.sh; do not source directly.

# shellcheck source=lib/ordo_provider_adapter_http.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ordo_provider_adapter_http.sh"

: "${ORDO_FORGEJO_WIP_PREFIXES:=WIP:|[WIP]|Draft:|[Draft]}"
_ORDO_FORGEJO_AUTH="token"

# shellcheck disable=SC2016 # jq programs
_ORDO_PROVIDER_FORGEJO_JQ_LIB='
def lc: if . == null then "" else (tostring | ascii_downcase) end;
def ts: if . == null or . == "" or . == "0001-01-01T00:00:00Z" then null else . end;
def label_names: [.labels[]? | if type == "object" then .name else . end];
def logins: [.[]? | if type == "object" then .login else . end];
def norm_issue: {
  "number": .number, "title": (.title // ""),
  "state": (if (.state | lc) == "closed" then "closed" else "open" end),
  "labels": label_names, "assignees": (.assignees | logins),
  "url": (.html_url // ""), "body": (.body // ""), "author": (.user.login // ""),
  "created_at": (.created_at | ts), "updated_at": (.updated_at | ts), "closed_at": (.closed_at | ts),
  "milestone": (.milestone.title // null),
  "closed_by_prs": []};
def norm_comment: {"author": (.user.login // ""), "body": (.body // ""), "created_at": (.created_at | ts), "url": (.html_url // "")};
def pr_state: if .merged == true then "merged" elif (.state | lc) == "closed" then "closed" else "open" end;
def pr_mergeable:
  if .merged == true then "mergeable"
  elif .mergeable == true then "mergeable"
  elif .mergeable == false then "conflicting"
  else "unknown" end;
def pr_merge_state:
  if .merged == true then "clean"
  elif (.state | lc) == "closed" then "unknown"
  elif .mergeable == false then "dirty"
  elif .draft == true then "draft"
  elif .mergeable == true then "clean"
  else "unknown" end;
def review_state:
  (.state | lc) as $s
  | if .dismissed == true then "dismissed"
    elif $s == "approved" then "approved"
    elif $s == "request_changes" then "changes_requested"
    elif $s == "comment" then "commented"
    elif $s == "pending" or $s == "request_review" then "pending"
    else "commented" end;
def decision_from_reviews($requested):
  ([.[]? | select(.dismissed != true) | select((.state | lc) != "request_review")]
   | group_by(.user.login) | map(sort_by(.submitted_at // "") | last)) as $latest
  | if any($latest[]; (.state | lc) == "request_changes") then "changes_requested"
    elif any($latest[]; (.state | lc) == "approved") then "approved"
    elif ($requested | length) > 0 or any($latest[]; (.state | lc) == "pending") then "review_required"
    else "none" end;
def decision_from_pr: if ((.requested_reviewers // []) | length) > 0 then "review_required" else "none" end;
def norm_pr($decision): {
  "number": .number, "title": (.title // ""), "state": pr_state, "draft": (.draft // false),
  "head": {"ref": (.head.ref // ""), "sha": (.head.sha // "")},
  "base": {"ref": (.base.ref // "")},
  "url": (.html_url // ""), "mergeable": pr_mergeable, "merge_state": pr_merge_state,
  "author": (.user.login // ""),
  "labels": label_names, "assignees": (.assignees | logins),
  "review_decision": $decision, "auto_merge": false,
  "created_at": (.created_at | ts), "updated_at": (.updated_at | ts),
  "merged_at": (.merged_at | ts), "closed_at": (.closed_at | ts),
  "merge_commit": (if .merged == true then (.merge_commit_sha // null) else null end),
  "body": (.body // ""), "changed_files": (.changed_files // null)};
def norm_status:
  (.state // .status | lc) as $s
  | ((.context // "") | capture("^(?<wf>.+) / (?<job>.+) \\((?<ev>[^)]+)\\)$")? // null) as $actions
  | {"name": (if $actions != null then $actions.job else (.context // "") end),
     "kind": (if $actions != null then "check_run" else "status" end),
     "status": (if $s == "pending" then "queued" else "completed" end),
     "conclusion": (if $s == "success" then "success" elif $s == "pending" then null
                    elif $s == "warning" then "neutral" elif $s == "error" or $s == "failure" then "failure" else $s end),
     "url": (.target_url // ""), "workflow": (if $actions != null then $actions.wf else null end),
     "started_at": (.created_at | ts),
     "completed_at": (if $s == "pending" then null else (.updated_at | ts) end)};
def checks_summary:
  {"total": length,
   "passed": ([.[] | select(.status == "completed" and (.conclusion == "success" or .conclusion == "neutral" or .conclusion == "skipped"))] | length),
   "failed": ([.[] | select(.status == "completed" and (.conclusion == "failure" or .conclusion == "timed_out" or .conclusion == "cancelled" or .conclusion == "action_required" or .conclusion == "startup_failure" or .conclusion == "stale"))] | length),
   "pending": ([.[] | select(.status != "completed")] | length)}
  | .state = (if .total == 0 then "none" elif .failed > 0 then "fail" elif .pending > 0 then "pending" else "pass" end);
def norm_review: {
  "author": (.user.login // ""), "state": review_state, "body": (.body // ""),
  "submitted_at": (.submitted_at | ts), "url": (.html_url // "")};
def run_status:
  (.status | lc) as $s
  | if $s == "completed" or $s == "success" or $s == "failure" or $s == "failed" or $s == "cancelled" or $s == "skipped" then "completed"
    elif $s == "in_progress" or $s == "running" then "in_progress"
    elif $s == "queued" or $s == "waiting" or $s == "blocked" or $s == "pending" then "queued"
    elif $s == "" then "unknown" else $s end;
def run_conclusion:
  (.conclusion | lc) as $c | (.status | lc) as $s
  | ($c | if . == "" then (if $s == "success" or $s == "failure" or $s == "cancelled" or $s == "skipped" or $s == "failed" then $s else "" end) else . end)
  | if . == "" then null elif . == "failed" then "failure" else . end;
def workflow_name: ((.workflow_id // .path // "") | tostring | split("/") | last | sub("\\.ya?ml$"; ""));
def norm_run: {
  "id": (.id // null), "run_number": (.run_number // null),
  "name": (if (.name // "") != "" then .name else workflow_name end),
  "workflow": (if workflow_name != "" then workflow_name else (.name // "") end),
  "title": (.display_title // .title // ""), "status": run_status, "conclusion": run_conclusion,
  "head_sha": (.head_sha // ""), "head_branch": (.head_branch // ""), "url": (.html_url // .url // ""),
  "created_at": ((.created_at // .started_at // .run_started_at) | ts), "updated_at": ((.updated_at // .completed_at) | ts),
  "event": (.event // "")};
def norm_job: {
  "id": (.id // null), "name": (.name // ""), "status": run_status, "conclusion": run_conclusion,
  "url": (.html_url // .url // ""), "started_at": (.started_at | ts), "completed_at": (.completed_at | ts),
  "steps": [ (.steps // [])[] | {"name": (.name // ""), "number": (.number // null), "status": run_status, "conclusion": run_conclusion} ]};
def norm_label: {"name": (.name // ""), "color": ((.color // "") | ltrimstr("#") | ascii_downcase), "description": (.description // "")};
def norm_repo_item: {
  "name": (.name // ""), "full_name": (.full_name // ""), "default_branch": (.default_branch // ""),
  "private": (.private // false), "url": (.html_url // ""), "clone_url": (.clone_url // ""),
  "archived": (.archived // false), "description": (.description // "")};
def norm_workflow: {
  "id": (.id // null), "name": (if (.name // "") != "" then .name else ((.path // "") | split("/") | last | sub("\\.ya?ml$"; "")) end),
  "path": (.path // ""),
  "state": ((.state | lc) as $s | if $s == "active" or $s == "" then "active" elif ($s | startswith("disabled")) then "disabled" else "unknown" end)};
def norm_protection($branch): {
  "branch": $branch, "protected": true,
  "required_checks": (if .enable_status_check == true then (.status_check_contexts // []) else [] end),
  "required_reviews": (.required_approvals // 0),
  "enforce_admins": (.block_admin_merge_override // false)};
'

# _ordo_provider_forgejo_jq [jq options...] <program>   (the program is the last argument)
_ordo_provider_forgejo_jq() {
  local prog="${*: -1}"
  if [[ $# -gt 1 ]]; then
    jq -c "${@:1:$#-1}" "${_ORDO_PROVIDER_FORGEJO_JQ_LIB}${prog}"
  else
    jq -c "${_ORDO_PROVIDER_FORGEJO_JQ_LIB}${prog}"
  fi
}

_ordo_provider_forgejo_api() {
  ordo_provider_http_base_url "/api/v1"
}

# Backend availability hook of ordo_provider_backend_available.
ordo_provider_adapter_forgejo_available() { command -v "${ORDO_PROVIDER_HTTP_CURL:-curl}" >/dev/null 2>&1; }

# repos/{owner}/{repo} path segment, URL-encoded.
_ordo_provider_forgejo_repo_path() {
  local repo="${ORDO_PV_REPO:?}"
  local owner="${repo%%/*}" name="${repo#*/}"
  if [[ -z "$owner" || -z "$name" || "$name" == */* ]]; then
    ordo_provider_adapter_error bad_argument "repository must be owner/repo, got '${repo}'" false "$(jq -cn --arg r "$repo" '{"repo": $r}')"
    return $?
  fi
  printf 'repos/%s/%s\n' "$(ordo_provider_http_urlencode "$owner")" "$(ordo_provider_http_urlencode "$name")"
}

# _ordo_provider_forgejo_call <op> <method> <relative-path> [request options...]
_ordo_provider_forgejo_call() {
  local op="$1" method="$2" rel="$3"
  shift 3
  local base
  base=$(_ordo_provider_forgejo_api) || return $?
  ordo_provider_http_request "$op" "$_ORDO_FORGEJO_AUTH" "$method" "${base}/${rel#/}" "$@"
}

# _ordo_provider_forgejo_get <op> <relative-path> -> JSON body
_ordo_provider_forgejo_get() {
  _ordo_provider_forgejo_call "$1" GET "$2" || return $?
  ordo_provider_http_json
}

_ordo_provider_forgejo_get_all() {
  # <op> <relative-path(with optional ?query)> [jq-items-expr]
  local base
  base=$(_ordo_provider_forgejo_api) || return $?
  ordo_provider_http_get_all "$1" "$_ORDO_FORGEJO_AUTH" "${base}/${2#/}" page limit "${3:-.}"
}

# has_more of the last server-side page (X-Total-Count, else Link rel=next).
_ordo_provider_forgejo_has_more() {
  local total
  total=$(ordo_provider_http_total)
  if [[ "$total" =~ ^[0-9]+$ ]]; then
    (( ORDO_PV_PAGE * ORDO_PV_LIMIT < total )) && return 0
    return 1
  fi
  ordo_provider_http_has_next
}

_ordo_provider_forgejo_json_list() {
  printf '%s\n' "$@" | jq -R . | jq -sc 'map(select(. != ""))'
}

_ordo_provider_forgejo_issue_url() {
  # <kind:issues|pulls> <number>
  printf '%s/%s/%s/%s\n' "$(ordo_provider_http_web_root)" "$ORDO_PV_REPO" "$1" "$2"
}

# ---------------------------------------------------------------------------
# Read ops
# ---------------------------------------------------------------------------
ordo_provider_adapter_forgejo_auth_status() {
  local base host
  base=$(_ordo_provider_forgejo_api) || return $?
  host=$(ordo_provider_http_host)
  ordo_provider_http_token >/dev/null || return $?
  local rc=0 err
  err=$(mktemp)
  ordo_provider_http_request auth_status "$_ORDO_FORGEJO_AUTH" GET "${base}/user" 2> "$err" || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    if [[ "${ORDO_HTTP_STATUS:-}" == 401 || "${ORDO_HTTP_STATUS:-}" == 403 ]]; then
      rm -f "$err"
      jq -cn --arg host "$host" --argjson status "${ORDO_HTTP_STATUS#0}" \
        '{"forge": "forgejo", "authenticated": false, "host": $host, "login": "", "scopes": [], "backend": "rest", "http_status": $status}'
      return 0
    fi
    cat "$err" >&2; rm -f "$err"
    return "$rc"
  fi
  rm -f "$err"
  local user
  user=$(ordo_provider_http_json) || return $?
  printf '%s' "$user" | jq -c --arg host "$host" \
    '{"forge": "forgejo", "authenticated": true, "host": $host, "login": (.login // ""), "scopes": [], "backend": "rest"}'
}

ordo_provider_adapter_forgejo_repo_get() {
  local rp raw
  rp=$(_ordo_provider_forgejo_repo_path) || return $?
  raw=$(_ordo_provider_forgejo_get repo_get "$rp") || return $?
  printf '%s' "$raw" | _ordo_provider_forgejo_jq '{
    "name": (.name // ""), "owner": (.owner.login // ""), "full_name": (.full_name // ""),
    "default_branch": (.default_branch // ""), "url": (.html_url // ""), "private": (.private // false),
    "permission": (if .permissions.admin == true then "admin" elif .permissions.push == true then "write" elif .permissions.pull == true then "read" else "" end),
    "description": (.description // "")}'
}

ordo_provider_adapter_forgejo_issue_get() {
  local rp raw
  rp=$(_ordo_provider_forgejo_repo_path) || return $?
  raw=$(_ordo_provider_forgejo_get issue_get "$rp/issues/$ORDO_PV_NUMBER") || return $?
  if [[ ",$ORDO_PV_WITH," == *,comments,* ]]; then
    local comments
    comments=$(_ordo_provider_forgejo_get_all issue_get "$rp/issues/$ORDO_PV_NUMBER/comments") || return $?
    printf '%s' "$raw" | _ordo_provider_forgejo_jq --argjson c "$comments" 'norm_issue + {"comments": [ $c[] | norm_comment ]}'
  else
    printf '%s' "$raw" | _ordo_provider_forgejo_jq 'norm_issue'
  fi
}

_ordo_provider_forgejo_state_param() {
  case "${ORDO_PV_STATE:-open}" in
    open|closed|all) printf '%s\n' "${ORDO_PV_STATE:-open}" ;;
    merged) printf 'closed\n' ;;
    *) printf 'open\n' ;;
  esac
}

ordo_provider_adapter_forgejo_issue_list() {
  local rp query labels
  rp=$(_ordo_provider_forgejo_repo_path) || return $?
  labels=$(IFS=,; printf '%s' "${ORDO_PV_LABELS[*]:-}")
  query=$(ordo_provider_http_query "type=issues" "state=$(_ordo_provider_forgejo_state_param)" "labels=$labels" \
    "q=$ORDO_PV_SEARCH" "created_by=$ORDO_PV_AUTHOR" "assigned_by=$ORDO_PV_ASSIGNEE" "milestones=$ORDO_PV_MILESTONE" \
    "page=$ORDO_PV_PAGE" "limit=$ORDO_PV_LIMIT")
  _ordo_provider_forgejo_call issue_list GET "$rp/issues$query" || return $?
  local body has_more=false total
  body=$(ordo_provider_http_json) || return $?
  total=$(ordo_provider_http_total)
  if [[ "$total" =~ ^[0-9]+$ ]]; then
    (( ORDO_PV_PAGE * ORDO_PV_LIMIT < total )) && has_more=true
  elif ordo_provider_http_has_next; then
    has_more=true
  fi
  ordo_provider_http_page_shape "$(printf '%s' "$body" | _ordo_provider_forgejo_jq 'map(norm_issue)')" "$ORDO_PV_PAGE" "$ORDO_PV_LIMIT" "$has_more"
}

_ordo_provider_forgejo_pr_decision() {
  # <pr-json> -> review decision derived from the PR's reviews
  local rp reviews requested
  rp=$(_ordo_provider_forgejo_repo_path) || return $?
  reviews=$(_ordo_provider_forgejo_get_all pr_get "$rp/pulls/$ORDO_PV_NUMBER/reviews") || return $?
  requested=$(printf '%s' "$1" | jq -c '.requested_reviewers // []')
  printf '%s' "$reviews" | _ordo_provider_forgejo_jq -r --argjson r "$requested" 'decision_from_reviews($r)'
}

ordo_provider_adapter_forgejo_pr_get() {
  local rp raw decision
  rp=$(_ordo_provider_forgejo_repo_path) || return $?
  raw=$(_ordo_provider_forgejo_get pr_get "$rp/pulls/$ORDO_PV_NUMBER") || return $?
  decision=$(_ordo_provider_forgejo_pr_decision "$raw") || return $?
  printf '%s' "$raw" | _ordo_provider_forgejo_jq --arg d "$decision" 'norm_pr($d)'
}

ordo_provider_adapter_forgejo_pr_list() {
  local rp labels state
  rp=$(_ordo_provider_forgejo_repo_path) || return $?
  labels=$(IFS=,; printf '%s' "${ORDO_PV_LABELS[*]:-}")
  state="${ORDO_PV_STATE:-open}"
  local server_state
  case "$state" in
    open|closed|all) server_state="$state" ;;
    merged) server_state="closed" ;;
    *) server_state="open" ;;
  esac
  # shellcheck disable=SC2016 # jq filter
  local local_filter='(($state != "merged") or .state == "merged")
    and ($base == "" or .base.ref == $base) and ($head == "" or .head.ref == $head)
    and ($author == "" or .author == $author) and ($assignee == "" or (.assignees | index($assignee)) != null)
    and ($search == "" or ((.title + " " + .body) | ascii_downcase | contains($search | ascii_downcase)))'
  if [[ "$state" != merged && -z "$ORDO_PV_BASE" && -z "$ORDO_PV_HEAD" && -z "$ORDO_PV_AUTHOR" && -z "$ORDO_PV_ASSIGNEE" && -z "$ORDO_PV_SEARCH" ]]; then
    # Pure server-side page.
    local query body has_more=false total
    query=$(ordo_provider_http_query "state=$server_state" "labels=$labels" "page=$ORDO_PV_PAGE" "limit=$ORDO_PV_LIMIT")
    _ordo_provider_forgejo_call pr_list GET "$rp/pulls$query" || return $?
    body=$(ordo_provider_http_json) || return $?
    total=$(ordo_provider_http_total)
    if [[ "$total" =~ ^[0-9]+$ ]]; then
      (( ORDO_PV_PAGE * ORDO_PV_LIMIT < total )) && has_more=true
    elif ordo_provider_http_has_next; then
      has_more=true
    fi
    ordo_provider_http_page_shape "$(printf '%s' "$body" | _ordo_provider_forgejo_jq 'map(norm_pr(decision_from_pr))')" "$ORDO_PV_PAGE" "$ORDO_PV_LIMIT" "$has_more"
    return 0
  fi
  # Filters Forgejo cannot apply server-side: walk the pages, filter locally,
  # slice locally (exact has_more, like the github backend).
  local query all
  query=$(ordo_provider_http_query "state=$server_state" "labels=$labels")
  all=$(_ordo_provider_forgejo_get_all pr_list "$rp/pulls$query") || return $?
  all=$(printf '%s' "$all" | _ordo_provider_forgejo_jq --arg state "$state" --arg base "$ORDO_PV_BASE" --arg head "$ORDO_PV_HEAD" \
    --arg author "$ORDO_PV_AUTHOR" --arg assignee "$ORDO_PV_ASSIGNEE" --arg search "$ORDO_PV_SEARCH" \
    "map(norm_pr(decision_from_pr)) | map(select(${local_filter}))")
  ordo_provider_http_paginate_local "$all" "$ORDO_PV_PAGE" "$ORDO_PV_LIMIT"
}

ordo_provider_adapter_forgejo_pr_files() {
  local rp files
  rp=$(_ordo_provider_forgejo_repo_path) || return $?
  files=$(_ordo_provider_forgejo_get_all pr_files "$rp/pulls/$ORDO_PV_NUMBER/files") || return $?
  printf '%s' "$files" | jq -c --argjson n "$ORDO_PV_NUMBER" '{
    "number": $n,
    "files": [ .[] | {"path": (.filename // ""), "additions": (.additions // 0), "deletions": (.deletions // 0)} ],
    "count": length}'
}

ordo_provider_adapter_forgejo_checks_get() {
  local rp pr sha combined
  rp=$(_ordo_provider_forgejo_repo_path) || return $?
  pr=$(_ordo_provider_forgejo_get checks_get "$rp/pulls/$ORDO_PV_NUMBER") || return $?
  sha=$(printf '%s' "$pr" | jq -r '.head.sha // ""')
  if [[ -z "$sha" ]]; then
    jq -cn --argjson n "$ORDO_PV_NUMBER" '{"number": $n, "sha": "", "checks": [], "summary": {"total": 0, "passed": 0, "failed": 0, "pending": 0, "state": "none"}}'
    return 0
  fi
  combined=$(_ordo_provider_forgejo_get checks_get "$rp/commits/$(ordo_provider_http_urlencode "$sha")/status") || return $?
  printf '%s' "$combined" | _ordo_provider_forgejo_jq --argjson n "$ORDO_PV_NUMBER" --arg sha "$sha" '
    ([ (.statuses // [])[] | norm_status ]) as $checks
    | {"number": $n, "sha": $sha, "checks": $checks, "summary": ($checks | checks_summary)}'
}

ordo_provider_adapter_forgejo_review_list() {
  local rp pr reviews requested
  rp=$(_ordo_provider_forgejo_repo_path) || return $?
  pr=$(_ordo_provider_forgejo_get review_list "$rp/pulls/$ORDO_PV_NUMBER") || return $?
  reviews=$(_ordo_provider_forgejo_get_all review_list "$rp/pulls/$ORDO_PV_NUMBER/reviews") || return $?
  requested=$(printf '%s' "$pr" | jq -c '.requested_reviewers // []')
  printf '%s' "$reviews" | _ordo_provider_forgejo_jq --argjson n "$ORDO_PV_NUMBER" --argjson r "$requested" '{
    "number": $n, "decision": decision_from_reviews($r),
    "reviews": [ .[] | select((.state | lc) != "request_review") | norm_review ]}'
}

# Runs: Forgejo/Gitea >= 1.24 expose /actions/runs (GitHub-like
# {"workflow_runs":[],"total_count"}); older instances expose /actions/tasks
# with the same envelope; both may be absent (404) => unsupported.
_ordo_provider_forgejo_runs_endpoint() {
  # Prints the relative endpoint that answers, or "" when none does.
  local rp="$1" candidate
  for candidate in "actions/runs" "actions/tasks"; do
    _ordo_provider_forgejo_call run_list GET "$rp/$candidate?page=1&limit=1" --allow-404 || return $?
    [[ "$ORDO_HTTP_STATUS" == 404 ]] || { printf '%s\n' "$candidate"; return 0; }
  done
  printf '\n'
}

ordo_provider_adapter_forgejo_run_list() {
  local rp endpoint
  rp=$(_ordo_provider_forgejo_repo_path) || return $?
  endpoint=$(_ordo_provider_forgejo_runs_endpoint "$rp") || return $?
  if [[ -z "$endpoint" ]]; then
    jq -cn --argjson page "$ORDO_PV_PAGE" --argjson limit "$ORDO_PV_LIMIT" \
      '{"items": [], "count": 0, "page": $page, "limit": $limit, "has_more": false, "details": {"capability": "unsupported", "reason": "this Forgejo/Gitea instance exposes neither /actions/runs nor /actions/tasks"}}'
    return 0
  fi
  local status_param=""
  case "$ORDO_PV_STATE" in
    queued) status_param="waiting" ;;
    in_progress) status_param="running" ;;
    completed) status_param="" ;;  # filtered locally below
    *) status_param="$ORDO_PV_STATE" ;;
  esac
  local query all
  query=$(ordo_provider_http_query "head_branch=$ORDO_PV_BRANCH" "head_sha=$ORDO_PV_COMMIT" "status=$status_param")
  all=$(_ordo_provider_forgejo_get_all run_list "$rp/$endpoint$query" '(if type == "array" then . else (.workflow_runs // []) end)') || return $?
  all=$(printf '%s' "$all" | _ordo_provider_forgejo_jq --arg wf "$ORDO_PV_WORKFLOW" --arg st "$ORDO_PV_STATE" --arg branch "$ORDO_PV_BRANCH" --arg commit "$ORDO_PV_COMMIT" '
    map(norm_run)
    | map(select(($wf == "" or .workflow == $wf or .name == $wf)
                 and ($st == "" or .status == $st)
                 and ($branch == "" or .head_branch == $branch)
                 and ($commit == "" or .head_sha == $commit)))')
  ordo_provider_http_paginate_local "$all" "$ORDO_PV_PAGE" "$ORDO_PV_LIMIT"
}

ordo_provider_adapter_forgejo_run_get() {
  local rp raw jobs payload
  rp=$(_ordo_provider_forgejo_repo_path) || return $?
  raw=$(_ordo_provider_forgejo_get run_get "$rp/actions/runs/$ORDO_PV_NUMBER") || return $?
  _ordo_provider_forgejo_call run_get GET "$rp/actions/runs/$ORDO_PV_NUMBER/jobs" --allow-404 || return $?
  if [[ "$ORDO_HTTP_STATUS" == 404 ]]; then jobs='[]'; else
    jobs=$(ordo_provider_http_json | jq -c 'if type == "array" then . else (.jobs // []) end')
  fi
  payload=$(printf '%s' "$raw" | _ordo_provider_forgejo_jq --argjson jobs "$jobs" 'norm_run + {"jobs": [ $jobs[] | norm_job ]}')
  if [[ ",$ORDO_PV_WITH," == *,log_failed,* ]]; then
    local log="" job_id job_name chunk
    while IFS=$'\t' read -r job_id job_name; do
      [[ -n "$job_id" ]] || continue
      _ordo_provider_forgejo_call run_get GET "$rp/actions/jobs/$job_id/logs" --accept "text/plain" --allow-404 2>/dev/null || continue
      [[ "$ORDO_HTTP_STATUS" == 2* ]] || continue
      chunk=$(printf '%s\n' "$ORDO_HTTP_BODY" | sed "s/^/${job_name//\//\\/}\t/")
      log="${log}${chunk}"$'\n'
    done < <(printf '%s' "$payload" | jq -r '.jobs[] | select(.conclusion == "failure" or .conclusion == "timed_out" or .conclusion == "cancelled") | [(.id | tostring), .name] | @tsv')
    log=$(ordo_provider_http_mask "$(printf '%s' "$log" | head -c "${ORDO_PROVIDER_LOG_MAX_BYTES:-200000}")")
    payload=$(printf '%s' "$payload" | jq -c --arg log "$log" '.log_failed = $log')
  fi
  if [[ ",$ORDO_PV_WITH," == *,log,* ]]; then
    local full
    full=$(_ordo_provider_forgejo_job_logs "$rp" "$(printf '%s' "$payload" | jq -r '.jobs[] | [(.id | tostring), .name] | @tsv')")
    payload=$(printf '%s' "$payload" | jq -c --arg log "$full" '.log = $log')
  fi
  printf '%s\n' "$payload"
}

# _ordo_provider_forgejo_job_logs <rp> <tsv id\tname lines> -> masked, capped text
_ordo_provider_forgejo_job_logs() {
  local rp="$1" log="" job_id job_name chunk
  while IFS=$'\t' read -r job_id job_name; do
    [[ -n "$job_id" ]] || continue
    _ordo_provider_forgejo_call run_get GET "$rp/actions/jobs/$job_id/logs" --accept "text/plain" --allow-404 2>/dev/null || continue
    [[ "$ORDO_HTTP_STATUS" == 2* ]] || continue
    chunk=$(printf '%s\n' "$ORDO_HTTP_BODY" | sed "s/^/${job_name//\//\\/}\t/")
    log="${log}${chunk}"$'\n'
  done <<< "$2"
  ordo_provider_http_mask "$(printf '%s' "$log" | head -c "${ORDO_PROVIDER_LOG_MAX_BYTES:-200000}")"
}

# ---------------------------------------------------------------------------
# Read ops added by #818
# ---------------------------------------------------------------------------
ordo_provider_adapter_forgejo_label_list() {
  local rp query body has_more=false
  rp=$(_ordo_provider_forgejo_repo_path) || return $?
  query=$(ordo_provider_http_query "page=$ORDO_PV_PAGE" "limit=$ORDO_PV_LIMIT")
  _ordo_provider_forgejo_call label_list GET "$rp/labels$query" || return $?
  body=$(ordo_provider_http_json) || return $?
  _ordo_provider_forgejo_has_more && has_more=true
  ordo_provider_http_page_shape "$(printf '%s' "$body" | _ordo_provider_forgejo_jq 'map(norm_label)')" "$ORDO_PV_PAGE" "$ORDO_PV_LIMIT" "$has_more"
}

ordo_provider_adapter_forgejo_repo_list() {
  local owner query body has_more=false
  owner=$(ordo_provider_http_urlencode "$ORDO_PV_OWNER")
  query=$(ordo_provider_http_query "page=$ORDO_PV_PAGE" "limit=$ORDO_PV_LIMIT")
  _ordo_provider_forgejo_call repo_list GET "orgs/$owner/repos$query" --allow-404 || return $?
  if [[ "$ORDO_HTTP_STATUS" == 404 ]]; then
    _ordo_provider_forgejo_call repo_list GET "users/$owner/repos$query" || return $?
  fi
  body=$(ordo_provider_http_json) || return $?
  _ordo_provider_forgejo_has_more && has_more=true
  ordo_provider_http_page_shape "$(printf '%s' "$body" | _ordo_provider_forgejo_jq 'map(norm_repo_item)')" "$ORDO_PV_PAGE" "$ORDO_PV_LIMIT" "$has_more" \
    | jq -c --arg owner "$ORDO_PV_OWNER" '{"owner": $owner} + .'
}

ordo_provider_adapter_forgejo_workflow_list() {
  local rp all capability=native
  rp=$(_ordo_provider_forgejo_repo_path) || return $?
  _ordo_provider_forgejo_call workflow_list GET "$rp/actions/workflows?page=1&limit=50" --allow-404 || return $?
  if [[ "$ORDO_HTTP_STATUS" == 404 ]]; then
    # No workflow API on this instance: the workflow files in the tree are the
    # honest approximation (state is unknown -> reported "active").
    capability=emulated
    all='[]'
    local dir entries
    for dir in ".forgejo/workflows" ".gitea/workflows" ".github/workflows"; do
      _ordo_provider_forgejo_call workflow_list GET "$rp/contents/$(ordo_provider_http_urlencode "$dir")" --allow-404 2>/dev/null || continue
      [[ "$ORDO_HTTP_STATUS" == 2* ]] || continue
      entries=$(ordo_provider_http_json 2>/dev/null) || continue
      all=$(jq -cn --argjson a "$all" --argjson e "$entries" '$a + [ ($e | if type == "array" then .[] else empty end)
        | select((.type // "") == "file" and ((.name // "") | test("\\.ya?ml$")))
        | {"id": null, "name": (.name | sub("\\.ya?ml$"; "")), "path": (.path // .name), "state": "active"} ]')
    done
  else
    all=$(ordo_provider_http_json | _ordo_provider_forgejo_jq '(if type == "array" then . else (.workflows // []) end) | map(norm_workflow)') || return $?
  fi
  all=$(printf '%s' "$all" | jq -c --arg st "$ORDO_PV_STATE" 'map(select($st == "" or $st == "all" or .state == $st))')
  ordo_provider_http_paginate_local "$all" "$ORDO_PV_PAGE" "$ORDO_PV_LIMIT" | jq -c --arg c "$capability" '. + {"details": {"capability": $c}}'
}

ordo_provider_adapter_forgejo_branch_protection_get() {
  local rp branch="$ORDO_PV_BRANCH" rule
  rp=$(_ordo_provider_forgejo_repo_path) || return $?
  _ordo_provider_forgejo_call branch_protection_get GET "$rp/branch_protections/$(ordo_provider_http_urlencode "$branch")" --allow-404 || return $?
  if [[ "$ORDO_HTTP_STATUS" == 2* ]]; then
    ordo_provider_http_json | _ordo_provider_forgejo_jq --arg b "$branch" 'norm_protection($b)'
    return 0
  fi
  # Rules are named by glob (rule_name); walk them and match the branch.
  local rules pattern
  rules=$(_ordo_provider_forgejo_get_all branch_protection_get "$rp/branch_protections") || return $?
  rule=""
  while IFS= read -r pattern; do
    [[ -n "$pattern" ]] || continue
    [[ -z "$rule" || "$rule" == null ]] || continue  # first match wins; keep draining the producer
    # shellcheck disable=SC2254 # the rule name is a glob by design
    case "$branch" in
      $pattern) rule=$(printf '%s' "$rules" | jq -c --arg p "$pattern" '[ .[] | select((.rule_name // .branch_name // "") == $p) ][0]') ;;
    esac
  done < <(printf '%s' "$rules" | jq -r '.[] | (.rule_name // .branch_name // "") | select(. != "")')
  if [[ -n "$rule" && "$rule" != null ]]; then
    printf '%s' "$rule" | _ordo_provider_forgejo_jq --arg b "$branch" 'norm_protection($b)'
  else
    jq -cn --arg b "$branch" '{"branch": $b, "protected": false, "required_checks": [], "required_reviews": 0, "enforce_admins": false}'
  fi
}

ordo_provider_adapter_forgejo_check_annotations() {
  local subject
  case "$ORDO_PV_SUBJECT" in
    check) subject=$(jq -cn --argjson id "$ORDO_PV_CHECK" '{"kind": "check", "id": $id}') ;;
    run) subject=$(jq -cn --argjson id "$ORDO_PV_RUN" '{"kind": "run", "id": $id}') ;;
    pr) subject=$(jq -cn --argjson n "$ORDO_PV_NUMBER" '{"kind": "pr", "id": $n}') ;;
    *) subject=$(jq -cn --arg sha "$ORDO_PV_REF" '{"kind": "ref", "id": $sha, "sha": $sha}') ;;
  esac
  jq -cn --argjson s "$subject" '{"subject": $s, "annotations": [], "count": 0,
    "details": {"capability": "unsupported", "reason": "Forgejo Actions exposes no check-run annotation API; read run_get --with log_failed instead"}}'
}

ordo_provider_adapter_forgejo_pr_files_batch() {
  local rp n files items='[]' missing='[]'
  rp=$(_ordo_provider_forgejo_repo_path) || return $?
  for n in "${ORDO_PV_NUMBERS[@]}"; do
    _ordo_provider_forgejo_call pr_files_batch GET "$rp/pulls/$n/files?page=1&limit=1" --allow-404 || return $?
    if [[ "$ORDO_HTTP_STATUS" == 404 ]]; then
      missing=$(jq -cn --argjson m "$missing" --argjson n "$n" '$m + [$n]')
      continue
    fi
    files=$(_ordo_provider_forgejo_get_all pr_files_batch "$rp/pulls/$n/files") || return $?
    items=$(jq -cn --argjson a "$items" --argjson n "$n" --argjson f "$files" '$a + [{"number": $n,
      "files": [ $f[] | {"path": (.filename // ""), "additions": (.additions // 0), "deletions": (.deletions // 0)} ], "count": ($f | length)}]')
  done
  jq -cn --argjson items "$items" --argjson missing "$missing" \
    '{"items": ($items | sort_by(.number)), "count": ($items | length), "missing": ($missing | unique)}'
}

# ---------------------------------------------------------------------------
# Mutations
# ---------------------------------------------------------------------------
# Label names -> ids (repository labels, then organisation labels). Unknown
# name => not_found.
_ordo_provider_forgejo_label_ids() {
  # <rp> <names...> -> JSON array of ids
  local rp="$1"; shift
  [[ $# -gt 0 ]] || { printf '[]\n'; return 0; }
  local repo_labels org_labels owner
  repo_labels=$(_ordo_provider_forgejo_get_all issue_labels "$rp/labels") || return $?
  owner="${ORDO_PV_REPO%%/*}"
  org_labels='[]'
  if _ordo_provider_forgejo_call issue_labels GET "orgs/$(ordo_provider_http_urlencode "$owner")/labels?page=1&limit=50" --allow-404 2>/dev/null \
    && [[ "$ORDO_HTTP_STATUS" == 2* ]]; then
    org_labels=$(ordo_provider_http_json 2>/dev/null) || org_labels='[]'
  fi
  local wanted ids missing
  wanted=$(_ordo_provider_forgejo_json_list "$@")
  ids=$(jq -cn --argjson repo "$repo_labels" --argjson org "$org_labels" --argjson wanted "$wanted" '
    (($repo + $org) | map({key: (.name | ascii_downcase), value: .id}) | from_entries) as $byname
    | [ $wanted[] | . as $w | $byname[$w | ascii_downcase] ] | map(select(. != null))')
  missing=$(jq -cn --argjson repo "$repo_labels" --argjson org "$org_labels" --argjson wanted "$wanted" '
    (($repo + $org) | map(.name | ascii_downcase)) as $known
    | [ $wanted[] | . as $w | select(($known | index($w | ascii_downcase)) == null) ]')
  if [[ "$(printf '%s' "$missing" | jq 'length')" -gt 0 ]]; then
    ordo_provider_adapter_error not_found "label(s) not found in ${ORDO_PV_REPO}: $(printf '%s' "$missing" | jq -r 'join(", ")')" false \
      "$(jq -cn --argjson m "$missing" --arg repo "$ORDO_PV_REPO" '{"labels": $m, "repo": $repo, "fix": "create the label on the forge first"}')"
    return $?
  fi
  printf '%s\n' "$ids"
}

_ordo_provider_forgejo_milestone_id() {
  # <rp> <title> -> id or null
  local rp="$1" title="$2" all
  [[ -n "$title" ]] || { printf 'null\n'; return 0; }
  if [[ "$title" =~ ^[0-9]+$ ]]; then printf '%s\n' "$title"; return 0; fi
  all=$(_ordo_provider_forgejo_get_all issue_edit "$rp/milestones?state=all") || return $?
  local id
  id=$(printf '%s' "$all" | jq -r --arg t "$title" '[.[] | select(.title == $t)][0].id // empty')
  if [[ -z "$id" ]]; then
    ordo_provider_adapter_error not_found "milestone not found: ${title}" false "$(jq -cn --arg t "$title" '{"milestone": $t}')"
    return $?
  fi
  printf '%s\n' "$id"
}

ordo_provider_adapter_forgejo_issue_create() {
  local rp ids body ms
  rp=$(_ordo_provider_forgejo_repo_path) || return $?
  ids=$(_ordo_provider_forgejo_label_ids "$rp" "${ORDO_PV_LABELS[@]}") || return $?
  ms=$(_ordo_provider_forgejo_milestone_id "$rp" "$ORDO_PV_MILESTONE") || return $?
  body=$(jq -cn --arg title "$ORDO_PV_TITLE" --rawfile body "$(ordo_provider_http_body_path)" --argjson labels "$ids" \
    --argjson assignees "$(_ordo_provider_forgejo_json_list "${ORDO_PV_ADD_ASSIGNEES[@]}")" --argjson ms "$ms" \
    '{"title": $title, "body": $body, "labels": $labels, "assignees": $assignees} + (if $ms != null then {"milestone": $ms} else {} end)')
  _ordo_provider_forgejo_call issue_create POST "$rp/issues" --body "$body" --mutation || return $?
  ordo_provider_http_json | jq -c '{"number": (.number // null), "url": (.html_url // "")}'
}

ordo_provider_adapter_forgejo_issue_comment() {
  if [[ -z "${ORDO_PV_BODY_PATH:-}" ]]; then
    ordo_provider_adapter_error usage "issue_comment requires --body or --body-file" false '{"missing":"body"}'
    return $?
  fi
  local rp body
  rp=$(_ordo_provider_forgejo_repo_path) || return $?
  body=$(jq -cn --rawfile body "$ORDO_PV_BODY_PATH" '{"body": $body}')
  _ordo_provider_forgejo_call issue_comment POST "$rp/issues/$ORDO_PV_NUMBER/comments" --body "$body" --mutation || return $?
  ordo_provider_http_json | jq -c --argjson n "$ORDO_PV_NUMBER" '{"number": $n, "url": (.html_url // "")}'
}

# Apply --add-label / --remove-label on issue-or-pr <n> (shared index).
_ordo_provider_forgejo_apply_labels() {
  local rp="$1" op="$2"
  if [[ "${#ORDO_PV_ADD_LABELS[@]}" -gt 0 ]]; then
    local ids
    ids=$(_ordo_provider_forgejo_label_ids "$rp" "${ORDO_PV_ADD_LABELS[@]}") || return $?
    _ordo_provider_forgejo_call "$op" POST "$rp/issues/$ORDO_PV_NUMBER/labels" --body "$(jq -cn --argjson l "$ids" '{"labels": $l}')" --mutation || return $?
  fi
  if [[ "${#ORDO_PV_REMOVE_LABELS[@]}" -gt 0 ]]; then
    local ids id
    ids=$(_ordo_provider_forgejo_label_ids "$rp" "${ORDO_PV_REMOVE_LABELS[@]}") || return $?
    for id in $(printf '%s' "$ids" | jq -r '.[]'); do
      _ordo_provider_forgejo_call "$op" DELETE "$rp/issues/$ORDO_PV_NUMBER/labels/$id" --mutation --allow-404 || return $?
    done
  fi
  return 0
}

_ordo_provider_forgejo_edit_common() {
  # <topic:issue|pr>
  local topic="$1" rp kind path
  rp=$(_ordo_provider_forgejo_repo_path) || return $?
  if [[ "$topic" == pr ]]; then kind=pulls; else kind=issues; fi
  path="$rp/$kind/$ORDO_PV_NUMBER"
  local op="${topic}_edit"
  case "$ORDO_PV_STATE" in
    closed|open)
      _ordo_provider_forgejo_call "$op" PATCH "$path" --body "$(jq -cn --arg s "$ORDO_PV_STATE" '{"state": $s}')" --mutation || return $?
      if [[ "$ORDO_PV_STATE" == closed && -n "${ORDO_PV_BODY_PATH:-}" ]]; then
        _ordo_provider_forgejo_call "$op" POST "$rp/issues/$ORDO_PV_NUMBER/comments" --body "$(jq -cn --rawfile b "$ORDO_PV_BODY_PATH" '{"body": $b}')" --mutation || return $?
      fi
      jq -cn --argjson n "$ORDO_PV_NUMBER" --arg s "$ORDO_PV_STATE" '{"number": $n, "state": $s}'
      return 0
      ;;
  esac
  local changes=0 patch='{}'
  if [[ -n "$ORDO_PV_TITLE" ]]; then patch=$(printf '%s' "$patch" | jq -c --arg t "$ORDO_PV_TITLE" '.title = $t'); changes=1; fi
  if [[ -n "${ORDO_PV_BODY_PATH:-}" ]]; then patch=$(printf '%s' "$patch" | jq -c --rawfile b "$ORDO_PV_BODY_PATH" '.body = $b'); changes=1; fi
  if [[ "$topic" == pr && -n "$ORDO_PV_BASE" ]]; then patch=$(printf '%s' "$patch" | jq -c --arg b "$ORDO_PV_BASE" '.base = $b'); changes=1; fi
  if [[ -n "$ORDO_PV_MILESTONE" ]]; then
    local ms
    ms=$(_ordo_provider_forgejo_milestone_id "$rp" "$ORDO_PV_MILESTONE") || return $?
    patch=$(printf '%s' "$patch" | jq -c --argjson m "$ms" '.milestone = $m'); changes=1
  fi
  if [[ "${#ORDO_PV_ADD_ASSIGNEES[@]}" -gt 0 || "${#ORDO_PV_REMOVE_ASSIGNEES[@]}" -gt 0 ]]; then
    # The API replaces the assignee list: read it, merge, write it back.
    local current
    current=$(_ordo_provider_forgejo_get "$op" "$path") || return $?
    patch=$(printf '%s' "$patch" | jq -c --argjson cur "$(printf '%s' "$current" | jq -c '[.assignees[]?.login]')" \
      --argjson add "$(_ordo_provider_forgejo_json_list "${ORDO_PV_ADD_ASSIGNEES[@]}")" \
      --argjson remove "$(_ordo_provider_forgejo_json_list "${ORDO_PV_REMOVE_ASSIGNEES[@]}")" \
      '.assignees = (($cur + $add) | unique) - $remove')
    changes=1
  fi
  [[ "${#ORDO_PV_ADD_LABELS[@]}" -gt 0 || "${#ORDO_PV_REMOVE_LABELS[@]}" -gt 0 ]] && changes=1
  if [[ "$changes" -eq 0 ]]; then
    ordo_provider_adapter_error usage "${op} needs at least one change (--title, --body, --add-label, --state, ...)" false \
      "$(jq -cn --arg op "$op" '{"op": $op, "missing": "change"}')"
    return $?
  fi
  if [[ "$patch" != '{}' ]]; then
    _ordo_provider_forgejo_call "$op" PATCH "$path" --body "$patch" --mutation || return $?
  fi
  _ordo_provider_forgejo_apply_labels "$rp" "$op" || return $?
  jq -cn --argjson n "$ORDO_PV_NUMBER" --arg url "$(_ordo_provider_forgejo_issue_url "$kind" "$ORDO_PV_NUMBER")" \
    --argjson add "$(_ordo_provider_forgejo_json_list "${ORDO_PV_ADD_LABELS[@]}")" \
    --argjson remove "$(_ordo_provider_forgejo_json_list "${ORDO_PV_REMOVE_LABELS[@]}")" \
    '{"number": $n, "url": $url, "labels_added": $add, "labels_removed": $remove}'
}

ordo_provider_adapter_forgejo_issue_edit() { _ordo_provider_forgejo_edit_common issue; }
ordo_provider_adapter_forgejo_pr_edit() { _ordo_provider_forgejo_edit_common pr; }

ordo_provider_adapter_forgejo_issue_labels() {
  if [[ "${#ORDO_PV_ADD_LABELS[@]}" -eq 0 && "${#ORDO_PV_REMOVE_LABELS[@]}" -eq 0 ]]; then
    ordo_provider_adapter_error usage "issue_labels needs --add <label> and/or --remove <label>" false '{"missing":"labels"}'
    return $?
  fi
  local rp
  rp=$(_ordo_provider_forgejo_repo_path) || return $?
  _ordo_provider_forgejo_apply_labels "$rp" issue_labels || return $?
  jq -cn --argjson n "$ORDO_PV_NUMBER" --arg url "$(_ordo_provider_forgejo_issue_url issues "$ORDO_PV_NUMBER")" \
    --argjson add "$(_ordo_provider_forgejo_json_list "${ORDO_PV_ADD_LABELS[@]}")" \
    --argjson remove "$(_ordo_provider_forgejo_json_list "${ORDO_PV_REMOVE_LABELS[@]}")" \
    '{"number": $n, "url": $url, "labels_added": $add, "labels_removed": $remove}'
}

_ordo_provider_forgejo_wip_prefix() { printf '%s\n' "${ORDO_FORGEJO_WIP_PREFIXES%%|*}"; }

# _ordo_provider_forgejo_strip_wip <title> -> title without any known prefix
_ordo_provider_forgejo_strip_wip() {
  local title="$1" prefix lower
  local IFS='|'
  for prefix in $ORDO_FORGEJO_WIP_PREFIXES; do
    lower=$(printf '%s' "${title:0:${#prefix}}" | tr '[:upper:]' '[:lower:]')
    if [[ "$lower" == "$(printf '%s' "$prefix" | tr '[:upper:]' '[:lower:]')" ]]; then
      title="${title:${#prefix}}"
      title="${title#"${title%%[![:space:]]*}"}"
      break
    fi
  done
  printf '%s\n' "$title"
}

_ordo_provider_forgejo_is_wip() {
  [[ "$(_ordo_provider_forgejo_strip_wip "$1")" != "$1" ]]
}

ordo_provider_adapter_forgejo_pr_create() {
  local rp ids base title body
  rp=$(_ordo_provider_forgejo_repo_path) || return $?
  ids=$(_ordo_provider_forgejo_label_ids "$rp" "${ORDO_PV_LABELS[@]}") || return $?
  base="$ORDO_PV_BASE"
  if [[ -z "$base" ]]; then
    base=$(_ordo_provider_forgejo_get pr_create "$rp" | jq -r '.default_branch // ""') || return $?
  fi
  title="$ORDO_PV_TITLE"
  if [[ "$ORDO_PV_DRAFT" -eq 1 ]] && ! _ordo_provider_forgejo_is_wip "$title"; then
    title="$(_ordo_provider_forgejo_wip_prefix) $title"
  fi
  body=$(jq -cn --arg title "$title" --rawfile body "$(ordo_provider_http_body_path)" --arg head "$ORDO_PV_HEAD" --arg base "$base" \
    --argjson labels "$ids" --argjson assignees "$(_ordo_provider_forgejo_json_list "${ORDO_PV_ADD_ASSIGNEES[@]}")" \
    '{"title": $title, "body": $body, "head": $head, "base": $base, "labels": $labels, "assignees": $assignees}')
  _ordo_provider_forgejo_call pr_create POST "$rp/pulls" --body "$body" --mutation || return $?
  ordo_provider_http_json | jq -c --arg head "$ORDO_PV_HEAD" --arg base "$base" --argjson draft "$([[ "$ORDO_PV_DRAFT" -eq 1 ]] && echo true || echo false)" \
    '{"number": (.number // null), "url": (.html_url // ""), "head": {"ref": (.head.ref // $head)}, "base": {"ref": (.base.ref // $base)}, "draft": (.draft // $draft)}'
}

# Forgejo has no draft field on the edit API: draft status is the WIP title
# prefix (repository setting, default "WIP:"). pr_ready strips it; --undo adds it.
ordo_provider_adapter_forgejo_pr_ready() {
  local rp pr title new_title
  rp=$(_ordo_provider_forgejo_repo_path) || return $?
  pr=$(_ordo_provider_forgejo_get pr_ready "$rp/pulls/$ORDO_PV_NUMBER") || return $?
  title=$(printf '%s' "$pr" | jq -r '.title // ""')
  if [[ "$ORDO_PV_UNDO" -eq 1 ]]; then
    new_title="$title"
    _ordo_provider_forgejo_is_wip "$title" || new_title="$(_ordo_provider_forgejo_wip_prefix) $title"
  else
    new_title=$(_ordo_provider_forgejo_strip_wip "$title")
  fi
  if [[ "$new_title" != "$title" ]]; then
    _ordo_provider_forgejo_call pr_ready PATCH "$rp/pulls/$ORDO_PV_NUMBER" --body "$(jq -cn --arg t "$new_title" '{"title": $t}')" --mutation || return $?
  fi
  jq -cn --argjson n "$ORDO_PV_NUMBER" --argjson draft "$([[ "$ORDO_PV_UNDO" -eq 1 ]] && echo true || echo false)" '{"number": $n, "draft": $draft}'
}

ordo_provider_adapter_forgejo_pr_merge() {
  local rp method="${ORDO_PV_METHOD:-squash}"
  rp=$(_ordo_provider_forgejo_repo_path) || return $?
  case "$method" in
    squash|merge|rebase) ;;
    *)
      ordo_provider_adapter_error bad_argument "unknown merge method '${method}' (squash|merge|rebase)" false "$(jq -cn --arg m "$method" '{"method": $m}')"
      return $?
      ;;
  esac
  local merged=true action=merged
  if [[ "$ORDO_PV_DISABLE_AUTO" -eq 1 ]]; then
    _ordo_provider_forgejo_call pr_merge DELETE "$rp/pulls/$ORDO_PV_NUMBER/merge" --mutation || return $?
    merged=false; action=auto_merge_disabled
  else
    local body
    body=$(jq -cn --arg merge_do "$method" \
      --argjson del "$([[ "$ORDO_PV_DELETE_BRANCH" -eq 1 ]] && echo true || echo false)" \
      --argjson auto "$([[ "$ORDO_PV_AUTO" -eq 1 ]] && echo true || echo false)" \
      --argjson force "$([[ "$ORDO_PV_ADMIN" -eq 1 ]] && echo true || echo false)" \
      '{"Do": $merge_do, "delete_branch_after_merge": $del, "merge_when_checks_succeed": $auto, "force_merge": $force}')
    local -a priv=()
    [[ "$ORDO_PV_ADMIN" -eq 1 ]] && priv=(--privileged)
    _ordo_provider_forgejo_call pr_merge POST "$rp/pulls/$ORDO_PV_NUMBER/merge" --body "$body" --mutation ${priv[@]+"${priv[@]}"} || return $?
    [[ "$ORDO_PV_AUTO" -eq 1 ]] && { merged=false; action=auto_merge_enabled; }
  fi
  jq -cn --argjson n "$ORDO_PV_NUMBER" --arg m "$method" --argjson merged "$merged" --arg action "$action" \
    --argjson admin "$([[ "$ORDO_PV_ADMIN" -eq 1 ]] && echo true || echo false)" \
    '{"number": $n, "merged": $merged, "action": $action, "method": $m, "admin": $admin}'
}

# mutate --scope S -k K -- --method M --path P [--body JSON | --body-file F]
#   P is relative to the API base (repos/...) or absolute (/api/v1/...). The
#   method+path are classified and must be compatible with the declared
#   scope (the REST counterpart of the gh double gate).
ordo_provider_adapter_forgejo_mutate() {
  ordo_provider_http_native_mutate forgejo "/api/v1" "$_ORDO_FORGEJO_AUTH"
}

# pr_review <n> --event approve|request_changes|comment [--body] (#818):
# POST .../pulls/{n}/reviews with the privileged token when configured.
ordo_provider_adapter_forgejo_pr_review() {
  local rp event state body
  rp=$(_ordo_provider_forgejo_repo_path) || return $?
  case "$ORDO_PV_EVENT" in
    approve) event=APPROVED; state=approved ;;
    request_changes) event=REQUEST_CHANGES; state=changes_requested ;;
    *) event=COMMENT; state=commented ;;
  esac
  body=$(jq -cn --arg e "$event" --rawfile b "$(ordo_provider_http_body_path)" '{"event": $e, "body": $b}')
  _ordo_provider_forgejo_call pr_review POST "$rp/pulls/$ORDO_PV_NUMBER/reviews" --body "$body" --mutation --privileged || return $?
  ordo_provider_http_json | jq -c --argjson n "$ORDO_PV_NUMBER" --arg e "$ORDO_PV_EVENT" --arg s "$state" \
    '{"number": $n, "event": $e, "state": $s, "url": (.html_url // "")}'
}
