#!/usr/bin/env bash
# lib/ordo_provider_adapter_github.sh — GitHub backend of the provider
# adapter (#811). The ONLY place in the adapter code that invokes `gh`.
#
# Every op maps 1:1 onto the `gh` invocation the existing call sites use
# today (gh pr view --json ..., gh issue list --json ..., gh run list ...),
# then normalises the payload into the forge-neutral shapes documented in
# docs/architecture/adapters.md. Mutations go through
# external_pr_mutation_run (lib/external_mutation_gate.sh) so the existing
# fail-closed policy and its gh-argument classification stay authoritative
# — the generic layer has already asserted the scope and consulted the
# idempotency ledger before this file runs.
#
# Failure classification (details.retryable): transport/rate-limit/5xx and
# timeouts are retryable; auth, permission, not-found, conflicts are not.
#
# Honoured environment: GH_CONFIG_DIR, GH_TOKEN, GH_HOST (derived from
# ORDO_FORGE_URL when set), ORDO_PROVIDER_TIMEOUT_SEC.
#
# Loaded on demand by lib/ordo_provider_adapter.sh; do not source directly.

_ORDO_PROVIDER_GITHUB_PR_FIELDS="number,title,state,isDraft,headRefName,headRefOid,baseRefName,url,mergeable,mergeStateStatus,author,labels,assignees,reviewDecision,autoMergeRequest,createdAt,updatedAt,mergedAt,closedAt,mergeCommit,body,changedFiles"
_ORDO_PROVIDER_GITHUB_ISSUE_FIELDS="number,title,state,labels,assignees,url,body,author,createdAt,updatedAt,closedAt,milestone"
_ORDO_PROVIDER_GITHUB_RUN_FIELDS="databaseId,number,name,workflowName,displayTitle,status,conclusion,headSha,headBranch,url,createdAt,updatedAt,event"

# shellcheck disable=SC2016 # jq programs
_ORDO_PROVIDER_GITHUB_JQ_LIB='
def lc: if . == null then "" else (tostring | ascii_downcase) end;
def ts: if . == null or . == "" then null else . end;
def pr_state:
  if ((.mergedAt // "") != "") or ((.state | lc) == "merged") then "merged"
  elif (.state | lc) == "closed" then "closed" else "open" end;
def mergeable_state:
  (.mergeable | lc) as $m
  | if $m == "mergeable" then "mergeable" elif $m == "conflicting" then "conflicting" else "unknown" end;
def review_decision:
  (.reviewDecision | lc) as $d | if $d == "" then "none" else $d end;
def norm_pr: {
  "number": .number, "title": (.title // ""), "state": pr_state, "draft": (.isDraft // false),
  "head": {"ref": (.headRefName // ""), "sha": (.headRefOid // "")},
  "base": {"ref": (.baseRefName // "")},
  "url": (.url // ""), "mergeable": mergeable_state,
  "merge_state": ((.mergeStateStatus | lc) | if . == "" then "unknown" else . end),
  "author": (.author.login // ""),
  "labels": [.labels[]?.name], "assignees": [.assignees[]?.login],
  "review_decision": review_decision, "auto_merge": (.autoMergeRequest != null),
  "created_at": (.createdAt // null), "updated_at": (.updatedAt // null),
  "merged_at": (.mergedAt // null), "closed_at": (.closedAt // null),
  "merge_commit": (.mergeCommit.oid // .mergeCommit // null),
  "body": (.body // ""), "changed_files": (.changedFiles // null)};
def norm_issue: {
  "number": .number, "title": (.title // ""),
  "state": (if (.state | lc) == "closed" then "closed" else "open" end),
  "labels": [.labels[]?.name], "assignees": [.assignees[]?.login],
  "url": (.url // ""), "body": (.body // ""), "author": (.author.login // ""),
  "created_at": (.createdAt // null), "updated_at": (.updatedAt // null), "closed_at": (.closedAt // null),
  "milestone": (.milestone.title // null),
  "closed_by_prs": [ (.closedByPullRequestsReferences // [])[] | {"number": .number, "state": (.state | lc)} ]}
  + (if has("comments") then {"comments": [ (.comments // [])[] | {"author": (.author.login // ""), "body": (.body // ""), "created_at": (.createdAt // null), "url": (.url // "")} ]} else {} end);
def norm_check:
  if (.__typename // "") == "StatusContext" then
    ((.state | lc) as $s |
     {"name": (.context // ""), "kind": "status",
      "status": (if $s == "pending" or $s == "expected" then "queued" else "completed" end),
      "conclusion": (if $s == "success" then "success" elif $s == "pending" or $s == "expected" then null elif $s == "error" then "failure" else $s end),
      "url": (.targetUrl // ""), "workflow": null, "started_at": (.startedAt | ts), "completed_at": null})
  else
    {"name": (.name // ""), "kind": "check_run",
     "status": ((.status | lc) | if . == "" then "queued" else . end),
     "conclusion": (if (.conclusion // "") == "" then null else (.conclusion | lc) end),
     "url": (.detailsUrl // ""), "workflow": (.workflowName // null),
     "started_at": (.startedAt | ts), "completed_at": (.completedAt | ts)}
  end;
def checks_summary:
  {"total": length,
   "passed": ([.[] | select(.status == "completed" and (.conclusion == "success" or .conclusion == "neutral" or .conclusion == "skipped"))] | length),
   "failed": ([.[] | select(.status == "completed" and (.conclusion == "failure" or .conclusion == "timed_out" or .conclusion == "cancelled" or .conclusion == "action_required" or .conclusion == "startup_failure" or .conclusion == "stale"))] | length),
   "pending": ([.[] | select(.status != "completed")] | length)}
  | .state = (if .total == 0 then "none" elif .failed > 0 then "fail" elif .pending > 0 then "pending" else "pass" end);
def norm_review: {
  "author": (.author.login // ""), "state": (.state | lc), "body": (.body // ""),
  "submitted_at": (.submittedAt // null), "url": (.url // "")};
def norm_run: {
  "id": (.databaseId // .id // null), "run_number": (.number // null),
  "name": (.name // .workflowName // ""), "workflow": (.workflowName // .name // ""),
  "title": (.displayTitle // ""), "status": ((.status | lc) | if . == "" then "unknown" else . end),
  "conclusion": (if (.conclusion // "") == "" then null else (.conclusion | lc) end),
  "head_sha": (.headSha // ""), "head_branch": (.headBranch // ""), "url": (.url // ""),
  "created_at": (.createdAt // null), "updated_at": (.updatedAt // null), "event": (.event // "")};
def norm_job: {
  "id": (.databaseId // null), "name": (.name // ""), "status": (.status | lc),
  "conclusion": (if (.conclusion // "") == "" then null else (.conclusion | lc) end),
  "url": (.url // ""), "started_at": (.startedAt | ts), "completed_at": (.completedAt | ts),
  "steps": [ (.steps // [])[] | {"name": (.name // ""), "number": (.number // null), "status": (.status | lc), "conclusion": (if (.conclusion // "") == "" then null else (.conclusion | lc) end)} ]};
def paginate($page; $limit):
  {"items": .[(($page - 1) * $limit):($page * $limit)], "page": $page, "limit": $limit, "has_more": (length > ($page * $limit))}
  | .count = (.items | length);
'

_ordo_provider_github_env() {
  # GH_HOST from ORDO_FORGE_URL when a GitHub Enterprise host is configured.
  if [[ -n "${ORDO_FORGE_URL:-}" && -z "${GH_HOST:-}" ]]; then
    local host="${ORDO_FORGE_URL#*://}"
    host="${host%%/*}"
    [[ -n "$host" && "$host" != "github.com" && "$host" != "api.github.com" ]] && export GH_HOST="$host"
  fi
  return 0
}

_ordo_provider_github_require() {
  if ! command -v gh >/dev/null 2>&1; then
    ordo_provider_adapter_error missing_dependency "the GitHub CLI (gh) is not on PATH" false \
      "$(jq -cn '{"dependency": "gh"}')"
    return $?
  fi
  _ordo_provider_github_env
}

# _ordo_provider_github_classify <rc> <stderr>
#   Prints "<code> <retryable> <category>".
_ordo_provider_github_classify() {
  local rc="$1" err="$2"
  local lower
  lower=$(printf '%s' "$err" | tr '[:upper:]' '[:lower:]')
  if [[ "$rc" -eq 124 ]]; then printf 'provider_error true timeout\n'; return; fi
  case "$lower" in
    *"not found"*|*"could not resolve"*|*"no pull requests"*|*"no issues"*|*"http 404"*|*"could not find"*|*"no pull request"*|*"no issue"*)
      printf 'not_found false not_found\n' ;;
    *"rate limit"*|*"http 5"*|*"timeout"*|*"timed out"*|*"connection reset"*|*"connection refused"*|*"network"*|*"eof"*|*"temporar"*|*"tls handshake"*|*"bad gateway"*|*"service unavailable"*)
      printf 'provider_error true transient\n' ;;
    *"not logged in"*|*"authentication"*|*"http 401"*|*"gh auth login"*|*"bad credentials"*|*"gh_token"*)
      printf 'provider_error false auth\n' ;;
    *"http 403"*|*"permission"*|*"forbidden"*|*"resource not accessible"*)
      printf 'provider_error false permission\n' ;;
    *"not mergeable"*|*"already merged"*|*"merge conflict"*|*"http 405"*|*"http 409"*|*"http 422"*|*"is closed"*|*"is a draft"*|*"already exists"*|*"validation failed"*)
      printf 'conflict false conflict\n' ;;
    *) printf 'provider_error false unknown\n' ;;
  esac
}

# _ordo_provider_github_fail <op> <rc> <stderr>
_ordo_provider_github_fail() {
  local op="$1" rc="$2" err="$3" code retryable category msg
  read -r code retryable category <<< "$(_ordo_provider_github_classify "$rc" "$err")"
  msg=$(printf '%s' "$err" | sed -E "s/${ORDO_CONTRACTS_REDACT_VALUE_RE}/${ORDO_CONTRACTS_REDACT_MASK}/g" | head -c 400 | tr '\n' ' ')
  ordo_provider_adapter_error "$code" "gh ${op} failed (${category}): ${msg:-exit $rc}" "$retryable" \
    "$(jq -cn --arg op "$op" --argjson rc "$rc" --arg category "$category" --arg stderr "$msg" \
        '{"op": $op, "backend": "gh", "exit": $rc, "category": $category, "stderr": $stderr}')"
}

# _ordo_provider_github_read <op> <gh-args...>   (read-only gh call, prints stdout)
_ordo_provider_github_read() {
  local op="$1"; shift
  _ordo_provider_github_require || return $?
  local out err rc=0
  err=$(mktemp)
  out=$(ordo_provider_adapter_run_with_timeout gh "$@" 2> "$err") || rc=$?
  local err_text
  err_text=$(cat "$err"); rm -f "$err"
  if [[ "$rc" -ne 0 ]]; then
    _ordo_provider_github_fail "$op" "$rc" "$err_text"
    return $?
  fi
  printf '%s\n' "$out"
}

# _ordo_provider_github_mutate <op> <gh-args...>
#   Runs the gh mutation THROUGH external_pr_mutation_run (Rule 11 gate).
_ordo_provider_github_mutate() {
  local op="$1"; shift
  _ordo_provider_github_require || return $?
  local out err rc=0
  err=$(mktemp)
  # No timeout wrapper here: external_pr_mutation_run is a shell function and
  # a mutation killed mid-flight would leave the forge state ambiguous.
  out=$(external_pr_mutation_run "${ORDO_PV_CONTEXT:-provider_adapter:github:$op}" -- "$@" 2> "$err") || rc=$?
  local err_text
  err_text=$(cat "$err"); rm -f "$err"
  if [[ "$rc" -eq "${ORCH_EXTERNAL_PR_MUTATION_EXIT_CODE:-80}" ]]; then
    ordo_provider_adapter_error policy_refused "gh ${op} refused by external_pr_mutation_run" false \
      "$(jq -cn --arg op "$op" --argjson rc "$rc" '{"op": $op, "gate_exit": $rc, "authorize_via": "ORCH_EXTERNAL_PR_MUTATIONS"}')"
    return $?
  fi
  if [[ "$rc" -ne 0 ]]; then
    _ordo_provider_github_fail "$op" "$rc" "$err_text"
    return $?
  fi
  printf '%s\n' "$out"
}

_ordo_provider_github_jq() {
  jq -c "${_ORDO_PROVIDER_GITHUB_JQ_LIB}$1" "${@:2}"
}

_ordo_provider_github_number_from_url() {
  printf '%s\n' "$1" | tr -d '\r' | grep -Eo '[0-9]+$' | tail -n 1
}

# ---------------------------------------------------------------------------
# Read ops
# ---------------------------------------------------------------------------
ordo_provider_adapter_github_auth_status() {
  _ordo_provider_github_require || return $?
  local out rc=0
  out=$(ordo_provider_adapter_run_with_timeout gh auth status 2>&1) || rc=$?
  local login host scopes
  login=$(grep -oE 'account [^ ]+' <<< "$out" | head -1 | awk '{print $2}')
  host=$(grep -oE 'Logged in to [^ ]+' <<< "$out" | head -1 | awk '{print $4}')
  scopes=$(grep -oE "Token scopes: .*" <<< "$out" | head -1 | sed -E "s/^Token scopes: //; s/'//g")
  local authenticated=true
  [[ "$rc" -eq 0 ]] || authenticated=false
  jq -cn --argjson ok "$authenticated" --arg login "${login:-}" --arg host "${host:-github.com}" --arg scopes "${scopes:-}" \
    '{"forge": "github", "authenticated": $ok, "host": $host, "login": $login,
      "scopes": ($scopes | split(", ") | map(select(. != ""))), "backend": "gh"}'
}

ordo_provider_adapter_github_repo_get() {
  local raw
  raw=$(_ordo_provider_github_read repo_get repo view "$ORDO_PV_REPO" \
    --json name,owner,nameWithOwner,defaultBranchRef,url,isPrivate,viewerPermission,description) || return $?
  printf '%s' "$raw" | _ordo_provider_github_jq '{
    "name": (.name // ""), "owner": (.owner.login // ""), "full_name": (.nameWithOwner // ""),
    "default_branch": (.defaultBranchRef.name // ""), "url": (.url // ""), "private": (.isPrivate // false),
    "permission": (.viewerPermission | lc), "description": (.description // "")}'
}

ordo_provider_adapter_github_issue_get() {
  local fields="$_ORDO_PROVIDER_GITHUB_ISSUE_FIELDS,closedByPullRequestsReferences"
  [[ ",$ORDO_PV_WITH," == *,comments,* ]] && fields="$fields,comments"
  local raw
  raw=$(_ordo_provider_github_read issue_get issue view "$ORDO_PV_NUMBER" --repo "$ORDO_PV_REPO" --json "$fields") || return $?
  printf '%s' "$raw" | _ordo_provider_github_jq 'norm_issue'
}

ordo_provider_adapter_github_issue_list() {
  local -a args=(issue list --repo "$ORDO_PV_REPO" --json "$_ORDO_PROVIDER_GITHUB_ISSUE_FIELDS")
  args+=(--state "${ORDO_PV_STATE:-open}")
  args+=(--limit "$((ORDO_PV_PAGE * ORDO_PV_LIMIT + 1))")
  local l
  for l in "${ORDO_PV_LABELS[@]}"; do args+=(--label "$l"); done
  [[ -n "$ORDO_PV_ASSIGNEE" ]] && args+=(--assignee "$ORDO_PV_ASSIGNEE")
  [[ -n "$ORDO_PV_AUTHOR" ]] && args+=(--author "$ORDO_PV_AUTHOR")
  [[ -n "$ORDO_PV_SEARCH" ]] && args+=(--search "$ORDO_PV_SEARCH")
  [[ -n "$ORDO_PV_MILESTONE" ]] && args+=(--milestone "$ORDO_PV_MILESTONE")
  local raw
  raw=$(_ordo_provider_github_read issue_list "${args[@]}") || return $?
  printf '%s' "$raw" | _ordo_provider_github_jq "map(norm_issue) | paginate(${ORDO_PV_PAGE}; ${ORDO_PV_LIMIT})"
}

ordo_provider_adapter_github_pr_get() {
  local raw
  raw=$(_ordo_provider_github_read pr_get pr view "$ORDO_PV_NUMBER" --repo "$ORDO_PV_REPO" --json "$_ORDO_PROVIDER_GITHUB_PR_FIELDS") || return $?
  printf '%s' "$raw" | _ordo_provider_github_jq 'norm_pr'
}

ordo_provider_adapter_github_pr_list() {
  local -a args=(pr list --repo "$ORDO_PV_REPO" --json "$_ORDO_PROVIDER_GITHUB_PR_FIELDS")
  args+=(--state "${ORDO_PV_STATE:-open}")
  args+=(--limit "$((ORDO_PV_PAGE * ORDO_PV_LIMIT + 1))")
  local l
  for l in "${ORDO_PV_LABELS[@]}"; do args+=(--label "$l"); done
  [[ -n "$ORDO_PV_BASE" ]] && args+=(--base "$ORDO_PV_BASE")
  [[ -n "$ORDO_PV_HEAD" ]] && args+=(--head "$ORDO_PV_HEAD")
  [[ -n "$ORDO_PV_AUTHOR" ]] && args+=(--author "$ORDO_PV_AUTHOR")
  [[ -n "$ORDO_PV_ASSIGNEE" ]] && args+=(--assignee "$ORDO_PV_ASSIGNEE")
  [[ -n "$ORDO_PV_SEARCH" ]] && args+=(--search "$ORDO_PV_SEARCH")
  local raw
  raw=$(_ordo_provider_github_read pr_list "${args[@]}") || return $?
  printf '%s' "$raw" | _ordo_provider_github_jq "map(norm_pr) | paginate(${ORDO_PV_PAGE}; ${ORDO_PV_LIMIT})"
}

ordo_provider_adapter_github_pr_files() {
  local raw
  raw=$(_ordo_provider_github_read pr_files pr view "$ORDO_PV_NUMBER" --repo "$ORDO_PV_REPO" --json number,files,changedFiles) || return $?
  printf '%s' "$raw" | _ordo_provider_github_jq '{
    "number": .number,
    "files": [ (.files // [])[] | {"path": .path, "additions": (.additions // 0), "deletions": (.deletions // 0)} ],
    "count": (.changedFiles // ((.files // []) | length))}'
}

ordo_provider_adapter_github_checks_get() {
  local raw
  raw=$(_ordo_provider_github_read checks_get pr view "$ORDO_PV_NUMBER" --repo "$ORDO_PV_REPO" --json number,headRefOid,statusCheckRollup) || return $?
  # shellcheck disable=SC2016 # jq program
  printf '%s' "$raw" | _ordo_provider_github_jq '
    ([ (.statusCheckRollup // [])[] | norm_check ]) as $checks
    | {"number": .number, "sha": (.headRefOid // ""), "checks": $checks, "summary": ($checks | checks_summary)}'
}

ordo_provider_adapter_github_review_list() {
  local raw
  raw=$(_ordo_provider_github_read review_list pr view "$ORDO_PV_NUMBER" --repo "$ORDO_PV_REPO" --json number,reviewDecision,reviews) || return $?
  printf '%s' "$raw" | _ordo_provider_github_jq '{
    "number": .number, "decision": review_decision,
    "reviews": [ (.reviews // [])[] | norm_review ]}'
}

ordo_provider_adapter_github_run_list() {
  local -a args=(run list --repo "$ORDO_PV_REPO" --json "$_ORDO_PROVIDER_GITHUB_RUN_FIELDS")
  args+=(--limit "$((ORDO_PV_PAGE * ORDO_PV_LIMIT + 1))")
  [[ -n "$ORDO_PV_BRANCH" ]] && args+=(--branch "$ORDO_PV_BRANCH")
  [[ -n "$ORDO_PV_COMMIT" ]] && args+=(--commit "$ORDO_PV_COMMIT")
  [[ -n "$ORDO_PV_WORKFLOW" ]] && args+=(--workflow "$ORDO_PV_WORKFLOW")
  [[ -n "$ORDO_PV_STATE" ]] && args+=(--status "$ORDO_PV_STATE")
  local raw
  raw=$(_ordo_provider_github_read run_list "${args[@]}") || return $?
  printf '%s' "$raw" | _ordo_provider_github_jq "map(norm_run) | paginate(${ORDO_PV_PAGE}; ${ORDO_PV_LIMIT})"
}

ordo_provider_adapter_github_run_get() {
  local raw
  raw=$(_ordo_provider_github_read run_get run view "$ORDO_PV_NUMBER" --repo "$ORDO_PV_REPO" --json "$_ORDO_PROVIDER_GITHUB_RUN_FIELDS,jobs") || return $?
  local payload
  payload=$(printf '%s' "$raw" | _ordo_provider_github_jq 'norm_run + {"jobs": [ (.jobs // [])[] | norm_job ]}')
  if [[ ",$ORDO_PV_WITH," == *,log_failed,* ]]; then
    local log
    log=$(_ordo_provider_github_read run_get run view "$ORDO_PV_NUMBER" --repo "$ORDO_PV_REPO" --log-failed 2>/dev/null || true)
    log=$(printf '%s' "$log" | head -c "${ORDO_PROVIDER_LOG_MAX_BYTES:-200000}" | sed -E "s/${ORDO_CONTRACTS_REDACT_VALUE_RE}/${ORDO_CONTRACTS_REDACT_MASK}/g")
    payload=$(printf '%s' "$payload" | jq -c --arg log "$log" '.log_failed = $log')
  fi
  printf '%s\n' "$payload"
}

# ---------------------------------------------------------------------------
# Mutations (all through _ordo_provider_github_mutate -> external_pr_mutation_run)
# ---------------------------------------------------------------------------
ordo_provider_adapter_github_issue_create() {
  local -a args=(issue create --repo "$ORDO_PV_REPO" --title "$ORDO_PV_TITLE")
  if [[ -n "${ORDO_PV_BODY_PATH:-}" ]]; then args+=(--body-file "$ORDO_PV_BODY_PATH"); else args+=(--body ""); fi
  local l
  for l in "${ORDO_PV_LABELS[@]}"; do args+=(--label "$l"); done
  for l in "${ORDO_PV_ADD_ASSIGNEES[@]}"; do args+=(--assignee "$l"); done
  [[ -n "$ORDO_PV_MILESTONE" ]] && args+=(--milestone "$ORDO_PV_MILESTONE")
  local out url number
  out=$(_ordo_provider_github_mutate issue_create "${args[@]}") || return $?
  url=$(printf '%s\n' "$out" | grep -E '^https?://' | tail -n 1)
  number=$(_ordo_provider_github_number_from_url "$url")
  jq -cn --arg url "$url" --arg n "$number" '{"number": (if $n == "" then null else ($n | tonumber) end), "url": $url}'
}

ordo_provider_adapter_github_issue_comment() {
  local -a args=(issue comment "$ORDO_PV_NUMBER" --repo "$ORDO_PV_REPO")
  if [[ -n "${ORDO_PV_BODY_PATH:-}" ]]; then args+=(--body-file "$ORDO_PV_BODY_PATH"); else
    ordo_provider_adapter_error usage "issue_comment requires --body or --body-file" false '{"missing":"body"}'
    return $?
  fi
  local out url
  out=$(_ordo_provider_github_mutate issue_comment "${args[@]}") || return $?
  url=$(printf '%s\n' "$out" | grep -E '^https?://' | tail -n 1)
  jq -cn --arg url "$url" --argjson n "$ORDO_PV_NUMBER" '{"number": $n, "url": $url}'
}

_ordo_provider_github_edit_args() {
  # Common --add-label/--remove-label/--add-assignee/--remove-assignee/--title/--body/--milestone args.
  local l
  for l in "${ORDO_PV_ADD_LABELS[@]}"; do printf '%s\n' --add-label "$l"; done
  for l in "${ORDO_PV_REMOVE_LABELS[@]}"; do printf '%s\n' --remove-label "$l"; done
  for l in "${ORDO_PV_ADD_ASSIGNEES[@]}"; do printf '%s\n' --add-assignee "$l"; done
  for l in "${ORDO_PV_REMOVE_ASSIGNEES[@]}"; do printf '%s\n' --remove-assignee "$l"; done
  [[ -n "$ORDO_PV_TITLE" ]] && printf '%s\n' --title "$ORDO_PV_TITLE"
  [[ -n "${ORDO_PV_BODY_PATH:-}" ]] && printf '%s\n' --body-file "$ORDO_PV_BODY_PATH"
  [[ -n "$ORDO_PV_MILESTONE" ]] && printf '%s\n' --milestone "$ORDO_PV_MILESTONE"
  return 0
}

_ordo_provider_github_edit_common() {
  # <topic:issue|pr>
  local topic="$1" out
  case "$ORDO_PV_STATE" in
    closed)
      local -a args=("$topic" close "$ORDO_PV_NUMBER" --repo "$ORDO_PV_REPO")
      [[ "$topic" == issue && -n "$ORDO_PV_REASON" ]] && args+=(--reason "$ORDO_PV_REASON")
      [[ -n "${ORDO_PV_BODY_PATH:-}" ]] && args+=(--comment "$(cat "$ORDO_PV_BODY_PATH")")
      out=$(_ordo_provider_github_mutate "${topic}_edit" "${args[@]}") || return $?
      jq -cn --argjson n "$ORDO_PV_NUMBER" '{"number": $n, "state": "closed"}'
      return 0
      ;;
    open)
      out=$(_ordo_provider_github_mutate "${topic}_edit" "$topic" reopen "$ORDO_PV_NUMBER" --repo "$ORDO_PV_REPO") || return $?
      jq -cn --argjson n "$ORDO_PV_NUMBER" '{"number": $n, "state": "open"}'
      return 0
      ;;
  esac
  local -a args=("$topic" edit "$ORDO_PV_NUMBER" --repo "$ORDO_PV_REPO")
  mapfile -t -O "${#args[@]}" args < <(_ordo_provider_github_edit_args)
  [[ "$topic" == pr && -n "$ORDO_PV_BASE" ]] && args+=(--base "$ORDO_PV_BASE")
  if [[ "${#args[@]}" -le 5 ]]; then
    ordo_provider_adapter_error usage "${topic}_edit needs at least one change (--title, --body, --add-label, --state, ...)" false \
      "$(jq -cn --arg op "${topic}_edit" '{"op": $op, "missing": "change"}')"
    return $?
  fi
  out=$(_ordo_provider_github_mutate "${topic}_edit" "${args[@]}") || return $?
  local url
  url=$(printf '%s\n' "$out" | grep -E '^https?://' | tail -n 1)
  jq -cn --argjson n "$ORDO_PV_NUMBER" --arg url "$url" \
    --argjson add "$(printf '%s\n' "${ORDO_PV_ADD_LABELS[@]}" | jq -R . | jq -sc 'map(select(. != ""))')" \
    --argjson remove "$(printf '%s\n' "${ORDO_PV_REMOVE_LABELS[@]}" | jq -R . | jq -sc 'map(select(. != ""))')" \
    '{"number": $n, "url": $url, "labels_added": $add, "labels_removed": $remove}'
}

ordo_provider_adapter_github_issue_edit() { _ordo_provider_github_edit_common issue; }
ordo_provider_adapter_github_pr_edit() { _ordo_provider_github_edit_common pr; }

ordo_provider_adapter_github_issue_labels() {
  if [[ "${#ORDO_PV_ADD_LABELS[@]}" -eq 0 && "${#ORDO_PV_REMOVE_LABELS[@]}" -eq 0 ]]; then
    ordo_provider_adapter_error usage "issue_labels needs --add <label> and/or --remove <label>" false '{"missing":"labels"}'
    return $?
  fi
  ORDO_PV_ADD_ASSIGNEES=() ORDO_PV_REMOVE_ASSIGNEES=() ORDO_PV_TITLE="" ORDO_PV_BODY_PATH="" ORDO_PV_MILESTONE="" ORDO_PV_STATE=""
  _ordo_provider_github_edit_common issue
}

ordo_provider_adapter_github_pr_create() {
  local -a args=(pr create --repo "$ORDO_PV_REPO" --title "$ORDO_PV_TITLE" --head "$ORDO_PV_HEAD")
  [[ -n "$ORDO_PV_BASE" ]] && args+=(--base "$ORDO_PV_BASE")
  if [[ -n "${ORDO_PV_BODY_PATH:-}" ]]; then args+=(--body-file "$ORDO_PV_BODY_PATH"); else args+=(--body ""); fi
  [[ "$ORDO_PV_DRAFT" -eq 1 ]] && args+=(--draft)
  local l
  for l in "${ORDO_PV_LABELS[@]}"; do args+=(--label "$l"); done
  for l in "${ORDO_PV_ADD_ASSIGNEES[@]}"; do args+=(--assignee "$l"); done
  local out url number
  out=$(_ordo_provider_github_mutate pr_create "${args[@]}") || return $?
  url=$(printf '%s\n' "$out" | grep -E '^https?://' | tail -n 1)
  number=$(_ordo_provider_github_number_from_url "$url")
  jq -cn --arg url "$url" --arg n "$number" --arg head "$ORDO_PV_HEAD" --arg base "$ORDO_PV_BASE" --argjson draft "$([[ "$ORDO_PV_DRAFT" -eq 1 ]] && echo true || echo false)" \
    '{"number": (if $n == "" then null else ($n | tonumber) end), "url": $url, "head": {"ref": $head}, "base": {"ref": $base}, "draft": $draft}'
}

ordo_provider_adapter_github_pr_ready() {
  local -a args=(pr ready "$ORDO_PV_NUMBER" --repo "$ORDO_PV_REPO")
  [[ "$ORDO_PV_UNDO" -eq 1 ]] && args+=(--undo)
  _ordo_provider_github_mutate pr_ready "${args[@]}" >/dev/null || return $?
  jq -cn --argjson n "$ORDO_PV_NUMBER" --argjson draft "$([[ "$ORDO_PV_UNDO" -eq 1 ]] && echo true || echo false)" \
    '{"number": $n, "draft": $draft}'
}

ordo_provider_adapter_github_pr_merge() {
  local -a args=(pr merge "$ORDO_PV_NUMBER" --repo "$ORDO_PV_REPO")
  local method="${ORDO_PV_METHOD:-squash}"
  if [[ "$ORDO_PV_DISABLE_AUTO" -eq 1 ]]; then
    args+=(--disable-auto)
  else
    case "$method" in
      squash|merge|rebase) args+=("--${method}") ;;
      *)
        ordo_provider_adapter_error bad_argument "unknown merge method '${method}' (squash|merge|rebase)" false \
          "$(jq -cn --arg m "$method" '{"method": $m}')"
        return $?
        ;;
    esac
    [[ "$ORDO_PV_ADMIN" -eq 1 ]] && args+=(--admin)
    # shellcheck disable=SC2153 # set by ordo_provider_adapter_parse_args
    [[ "$ORDO_PV_AUTO" -eq 1 ]] && args+=(--auto)
    [[ "$ORDO_PV_DELETE_BRANCH" -eq 1 ]] && args+=(--delete-branch)
  fi
  _ordo_provider_github_mutate pr_merge "${args[@]}" >/dev/null || return $?
  local merged=true action=merged
  if [[ "$ORDO_PV_DISABLE_AUTO" -eq 1 ]]; then merged=false; action=auto_merge_disabled
  elif [[ "$ORDO_PV_AUTO" -eq 1 ]]; then merged=false; action=auto_merge_enabled; fi
  jq -cn --argjson n "$ORDO_PV_NUMBER" --arg m "$method" --argjson merged "$merged" --arg action "$action" \
    --argjson admin "$([[ "$ORDO_PV_ADMIN" -eq 1 ]] && echo true || echo false)" \
    '{"number": $n, "merged": $merged, "action": $action, "method": $m, "admin": $admin}'
}

# mutate --scope S -k K -- <gh args>: escape hatch for call sites without a
# dedicated op. The generic layer asserted the scope; external_pr_mutation_run
# re-classifies the gh args and asserts again (authoritative).
ordo_provider_adapter_github_mutate() {
  local out
  out=$(_ordo_provider_github_mutate mutate "${ORDO_PV_NATIVE[@]}") || return $?
  jq -cn --arg out "$out" --argjson args "$(printf '%s\n' "${ORDO_PV_NATIVE[@]}" | jq -R . | jq -sc .)" \
    '{"backend": "gh", "args": $args, "stdout": $out}'
}
