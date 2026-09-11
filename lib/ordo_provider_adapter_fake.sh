#!/usr/bin/env bash
# lib/ordo_provider_adapter_fake.sh — fake backend of the provider adapter
# (#811). Serves normalised fixtures from $ORDO_FAKE_ADAPTER_DIR and records
# mutations; no CLI, no network. Used by the conformance suite, by #813's
# eval harness and by #816's "no gh on PATH" proof.
#
# Fixture layout ($ORDO_FAKE_ADAPTER_DIR):
#   auth_status/default.json            {"forge","authenticated","host","login","scopes"}
#   repo_get/<owner>__<repo>.json | repo_get/default.json
#   issue_get/<number>.json             normalised issue object
#   pr_get/<number>.json                normalised pr object
#   pr_files/<number>.json              {"number","files":[...],"count"}
#   checks_get/<number>.json            {"number","sha","checks":[...],"summary":{...}}
#   review_list/<number>.json           {"number","decision","reviews":[...]}
#   run_get/<id>.json                   normalised run object (+ jobs, log_failed, log)
#   issue_list/default.json             array of issues (filtered by --state/--label, paginated)
#   pr_list/default.json                array of prs (filtered by --state/--base/--label, paginated)
#   run_list/default.json               array of runs (filtered by --branch/--commit/--workflow)
#   label_list/default.json             array of {"name","color","description"} (#818)
#   repo_list/<owner>.json | default    array of repo items (#818)
#   workflow_list/default.json          array of {"id","name","path","state"} (#818)
#   branch_protection_get/<branch>.json protection object; missing => protected=false (#818)
#   check_annotations/<kind>_<id>.json  array of annotations for check_<id>, run_<id>, pr_<n>,
#                                       ref_<sha>; missing => no annotations (#818)
#   pr_files/<n>.json                   also serves pr_files_batch (missing numbers => "missing")
#   <mutating-op>/<number|default>.json optional result template for a mutation
#   mutations.jsonl                     appended by every executed mutation
#
# Any fixture whose content is {"error":{...}} is replayed as that error
# (code -> exit code from ordo_contracts, details.retryable preserved), which
# is how tests exercise retryable/non-retryable classification.
# A missing fixture is not_found (exit 4).
#
# Loaded on demand by lib/ordo_provider_adapter.sh; do not source directly.

# Backend availability hook of ordo_provider_backend_available.
ordo_provider_adapter_fake_available() { [[ -n "${ORDO_FAKE_ADAPTER_DIR:-}" ]]; }

_ordo_provider_fake_dir() {
  if [[ -z "${ORDO_FAKE_ADAPTER_DIR:-}" ]]; then
    ordo_provider_adapter_error bad_argument "ORDO_FAKE_ADAPTER_DIR must be set for the fake provider adapter" false \
      "$(jq -cn '{"missing": "ORDO_FAKE_ADAPTER_DIR"}')"
    return $?
  fi
  printf '%s\n' "$ORDO_FAKE_ADAPTER_DIR"
}

_ordo_provider_fake_safe_repo() {
  printf '%s' "${1:-default}" | tr -c 'A-Za-z0-9._-' '_'
}

# _ordo_provider_fake_fixture <op> <key> [alt-key]
#   Prints the fixture path if one exists (key, then alt-key, then default).
_ordo_provider_fake_fixture() {
  local dir op="$1" key="${2:-}" alt="${3:-default}" candidate
  dir=$(_ordo_provider_fake_dir) || return $?
  for candidate in "$dir/$op/$key.json" "$dir/$op/$alt.json" "$dir/$op/default.json"; do
    [[ -n "$key" || "$candidate" != "$dir/$op/.json" ]] || continue
    if [[ -f "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 4
}

# _ordo_provider_fake_load <op> <key> [alt-key] -> prints JSON or emits error
_ordo_provider_fake_load() {
  local op="$1" key="${2:-}" alt="${3:-default}" file rc=0
  # Capture the loader's status explicitly: inside `if ! cmd; then` the
  # value of $? is that of the negation (0), which used to turn a missing
  # fixture into a silent empty success (#816 review finding).
  file=$(_ordo_provider_fake_fixture "$op" "$key" "$alt") || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    [[ "$rc" -eq 4 ]] || return "$rc"
    ordo_provider_adapter_error not_found "fake fixture not found for ${op} ${key:-default}" false \
      "$(jq -cn --arg op "$op" --arg key "${key:-default}" --arg dir "${ORDO_FAKE_ADAPTER_DIR:-}" \
          '{"op": $op, "key": $key, "fixture_dir": $dir, "expected": ($dir + "/" + $op + "/" + $key + ".json")}')"
    return $?
  fi
  local doc
  if ! doc=$(jq -c . "$file" 2>/dev/null); then
    ordo_provider_adapter_error invalid_json "fake fixture is not valid JSON: ${file}" false \
      "$(jq -cn --arg f "$file" '{"fixture": $f}')"
    return $?
  fi
  if printf '%s' "$doc" | jq -e '.error? | type == "object"' >/dev/null 2>&1; then
    local code message retryable details
    code=$(printf '%s' "$doc" | jq -r '.error.code // "provider_error"')
    message=$(printf '%s' "$doc" | jq -r '.error.message // "fake error fixture"')
    retryable=$(printf '%s' "$doc" | jq -r '.error.details.retryable // false')
    details=$(printf '%s' "$doc" | jq -c '(.error.details // {}) + {"fixture": true}')
    ordo_provider_adapter_error "$code" "$message" "$retryable" "$details"
    return $?
  fi
  printf '%s\n' "$doc"
}

# _ordo_provider_fake_load_optional <op> <key>: like _ordo_provider_fake_load
# for an op that has a neutral default — a missing fixture is a silent 4;
# any other failure (no fixture root, invalid JSON, error fixture) propagates
# with its error object, it is never mistaken for "nothing there".
_ordo_provider_fake_load_optional() {
  local op="$1" key="$2" rc=0
  _ordo_provider_fake_fixture "$op" "$key" __none__ >/dev/null || rc=$?
  [[ "$rc" -ne 4 ]] || return 4
  [[ "$rc" -eq 0 ]] || return "$rc"
  _ordo_provider_fake_load "$op" "$key" __none__
}

# _ordo_provider_fake_record <extra-json>  -> appends to mutations.jsonl
_ordo_provider_fake_record() {
  local dir extra="${1:-{\}}"
  dir=$(_ordo_provider_fake_dir) || return $?
  jq -cn --arg ts "$(ordo_contracts_now)" --arg op "$ORDO_PV_OP" --arg repo "$ORDO_PV_REPO" \
    --arg key "$ORDO_PV_KEY" --arg scope "${ORDO_PV_SCOPE_RESOLVED:-}" --arg n "$ORDO_PV_NUMBER" --argjson extra "$extra" \
    '{"ts": $ts, "op": $op, "adapter": "fake", "repo": $repo, "idempotency_key": $key, "scope": $scope,
      "number": (if $n == "" then null else ($n | tonumber) end)} + $extra' >> "$dir/mutations.jsonl"
}

# _ordo_provider_fake_update_fixture <op> <key> <jq-filter>  (best effort)
_ordo_provider_fake_update_fixture() {
  local op="$1" key="$2" filter="$3" dir file tmp
  dir=$(_ordo_provider_fake_dir) || return 0
  file="$dir/$op/$key.json"
  [[ -f "$file" ]] || return 0
  tmp=$(mktemp)
  if jq -c "$filter" "$file" > "$tmp" 2>/dev/null; then mv "$tmp" "$file"; else rm -f "$tmp"; fi
  return 0
}

_ordo_provider_fake_next_number() {
  local dir n
  dir=$(_ordo_provider_fake_dir) || return $?
  n=$( (find "$dir/issue_get" "$dir/pr_get" -maxdepth 1 -name '*.json' 2>/dev/null | sed -E 's#.*/##; s#\.json$##' | grep -E '^[0-9]+$';
        [[ -f "$dir/mutations.jsonl" ]] && jq -r '.result.number // empty' "$dir/mutations.jsonl" 2>/dev/null) | sort -n | tail -n 1)
  printf '%s\n' "$(( ${n:-1000} + 1 ))"
}

_ordo_provider_fake_labels_json() {
  printf '%s\n' "$@" | jq -R . | jq -sc 'map(select(. != ""))'
}

# ---------------------------------------------------------------------------
# Read ops
# ---------------------------------------------------------------------------
ordo_provider_adapter_fake_auth_status() {
  local doc
  if doc=$(_ordo_provider_fake_load auth_status default 2>/dev/null); then
    printf '%s' "$doc" | jq -c '{"forge": (.forge // "fake"), "authenticated": (.authenticated // true), "host": (.host // "fake.invalid"), "login": (.login // "fake-user"), "scopes": (.scopes // []), "backend": "fixtures"}'
  else
    jq -cn '{"forge": "fake", "authenticated": true, "host": "fake.invalid", "login": "fake-user", "scopes": [], "backend": "fixtures"}'
  fi
}

ordo_provider_adapter_fake_repo_get() {
  _ordo_provider_fake_load repo_get "$(_ordo_provider_fake_safe_repo "$ORDO_PV_REPO")"
}

ordo_provider_adapter_fake_issue_get() {
  local doc
  doc=$(_ordo_provider_fake_load issue_get "$ORDO_PV_NUMBER") || return $?
  if [[ ",$ORDO_PV_WITH," == *,comments,* ]]; then
    printf '%s' "$doc" | jq -c '.comments = (.comments // [])'
  else
    printf '%s' "$doc" | jq -c 'del(.comments)'
  fi
}

_ordo_provider_fake_list() {
  # <op> <jq-filter-on-item>
  local op="$1" filter="$2" doc
  doc=$(_ordo_provider_fake_load "$op" default) || return $?
  printf '%s' "$doc" | jq -c --argjson page "$ORDO_PV_PAGE" --argjson limit "$ORDO_PV_LIMIT" \
    --arg state "${ORDO_PV_STATE:-}" --arg base "$ORDO_PV_BASE" --arg branch "$ORDO_PV_BRANCH" \
    --arg commit "$ORDO_PV_COMMIT" --arg workflow "$ORDO_PV_WORKFLOW" --arg author "$ORDO_PV_AUTHOR" \
    --argjson labels "$(_ordo_provider_fake_labels_json "${ORDO_PV_LABELS[@]}")" "
    (if type == \"array\" then . else (.items // []) end)
    | map(select(${filter}))
    | {\"items\": .[((\$page - 1) * \$limit):(\$page * \$limit)], \"page\": \$page, \"limit\": \$limit, \"has_more\": (length > (\$page * \$limit))}
    | .count = (.items | length)"
}

ordo_provider_adapter_fake_issue_list() {
  # shellcheck disable=SC2016 # jq filter
  _ordo_provider_fake_list issue_list '
    (($state == "" and .state == "open") or $state == "all" or .state == $state)
    and ($author == "" or .author == $author)
    and (($labels | length) == 0 or (($labels - (.labels // [])) | length) == 0)'
}

ordo_provider_adapter_fake_pr_get() { _ordo_provider_fake_load pr_get "$ORDO_PV_NUMBER"; }

ordo_provider_adapter_fake_pr_list() {
  # shellcheck disable=SC2016 # jq filter
  _ordo_provider_fake_list pr_list '
    (($state == "" and .state == "open") or $state == "all" or .state == $state)
    and ($base == "" or .base.ref == $base)
    and ($author == "" or .author == $author)
    and (($labels | length) == 0 or (($labels - (.labels // [])) | length) == 0)'
}

ordo_provider_adapter_fake_pr_files() { _ordo_provider_fake_load pr_files "$ORDO_PV_NUMBER"; }
ordo_provider_adapter_fake_checks_get() { _ordo_provider_fake_load checks_get "$ORDO_PV_NUMBER"; }
ordo_provider_adapter_fake_review_list() { _ordo_provider_fake_load review_list "$ORDO_PV_NUMBER"; }

ordo_provider_adapter_fake_run_list() {
  # shellcheck disable=SC2016 # jq filter
  _ordo_provider_fake_list run_list '
    ($branch == "" or .head_branch == $branch)
    and ($commit == "" or .head_sha == $commit)
    and ($workflow == "" or .workflow == $workflow or .name == $workflow)
    and ($state == "" or .status == $state)'
}

ordo_provider_adapter_fake_run_get() {
  local doc
  doc=$(_ordo_provider_fake_load run_get "$ORDO_PV_NUMBER") || return $?
  if [[ ",$ORDO_PV_WITH," == *,log_failed,* ]]; then
    doc=$(printf '%s' "$doc" | jq -c '.log_failed = (.log_failed // "")')
  else
    doc=$(printf '%s' "$doc" | jq -c 'del(.log_failed)')
  fi
  if [[ ",$ORDO_PV_WITH," == *,log,* ]]; then
    doc=$(printf '%s' "$doc" | jq -c '.log = (.log // "")')
  else
    doc=$(printf '%s' "$doc" | jq -c 'del(.log)')
  fi
  printf '%s\n' "$doc"
}

# --- read ops added by #818 --------------------------------------------------
ordo_provider_adapter_fake_label_list() {
  # shellcheck disable=SC2016 # jq filter
  _ordo_provider_fake_list label_list 'true'
}

ordo_provider_adapter_fake_repo_list() {
  local doc
  doc=$(_ordo_provider_fake_load repo_list "$(_ordo_provider_fake_safe_repo "$ORDO_PV_OWNER")") || return $?
  printf '%s' "$doc" | jq -c --argjson page "$ORDO_PV_PAGE" --argjson limit "$ORDO_PV_LIMIT" --arg owner "$ORDO_PV_OWNER" '
    (if type == "array" then . else (.items // []) end)
    | {"owner": $owner, "items": .[(($page - 1) * $limit):($page * $limit)], "page": $page, "limit": $limit, "has_more": (length > ($page * $limit))}
    | .count = (.items | length)'
}

ordo_provider_adapter_fake_workflow_list() {
  # shellcheck disable=SC2016 # jq filter
  _ordo_provider_fake_list workflow_list '($state == "" or $state == "all" or .state == $state)'
}

ordo_provider_adapter_fake_branch_protection_get() {
  local doc rc=0
  doc=$(_ordo_provider_fake_load_optional branch_protection_get "$(_ordo_provider_fake_safe_repo "$ORDO_PV_BRANCH")") || rc=$?
  case "$rc" in
    0)
      printf '%s' "$doc" | jq -c --arg b "$ORDO_PV_BRANCH" '{"branch": $b, "protected": (.protected // true),
        "required_checks": (.required_checks // []), "required_reviews": (.required_reviews // 0), "enforce_admins": (.enforce_admins // false)}' ;;
    4) jq -cn --arg b "$ORDO_PV_BRANCH" '{"branch": $b, "protected": false, "required_checks": [], "required_reviews": 0, "enforce_admins": false}' ;;
    *) return "$rc" ;;
  esac
}

ordo_provider_adapter_fake_check_annotations() {
  local key subject doc
  case "$ORDO_PV_SUBJECT" in
    check) key="check_${ORDO_PV_CHECK}"; subject=$(jq -cn --argjson id "$ORDO_PV_CHECK" '{"kind": "check", "id": $id}') ;;
    run) key="run_${ORDO_PV_RUN}"; subject=$(jq -cn --argjson id "$ORDO_PV_RUN" '{"kind": "run", "id": $id}') ;;
    pr) key="pr_${ORDO_PV_NUMBER}"; subject=$(jq -cn --argjson n "$ORDO_PV_NUMBER" '{"kind": "pr", "id": $n}') ;;
    *) key="ref_$(_ordo_provider_fake_safe_repo "$ORDO_PV_REF")"; subject=$(jq -cn --arg sha "$ORDO_PV_REF" '{"kind": "ref", "id": $sha, "sha": $sha}') ;;
  esac
  local rc=0
  doc=$(_ordo_provider_fake_load_optional check_annotations "$key") || rc=$?
  case "$rc" in
    0) printf '%s' "$doc" | jq -c --argjson s "$subject" '(if type == "array" then . else (.annotations // []) end) as $a | {"subject": $s, "annotations": $a, "count": ($a | length)}' ;;
    4) jq -cn --argjson s "$subject" '{"subject": $s, "annotations": [], "count": 0}' ;;
    *) return "$rc" ;;
  esac
}

ordo_provider_adapter_fake_pr_files_batch() {
  local items='[]' missing='[]' n doc
  local rc
  for n in "${ORDO_PV_NUMBERS[@]}"; do
    rc=0
    doc=$(_ordo_provider_fake_load_optional pr_files "$n") || rc=$?
    case "$rc" in
      0) items=$(jq -cn --argjson a "$items" --argjson d "$doc" '$a + [$d]') ;;
      4) missing=$(jq -cn --argjson m "$missing" --argjson n "$n" '$m + [$n]') ;;
      *) return "$rc" ;;
    esac
  done
  jq -cn --argjson items "$items" --argjson missing "$missing" \
    '{"items": ($items | sort_by(.number)), "count": ($items | length), "missing": ($missing | unique)}'
}

# ---------------------------------------------------------------------------
# Mutations: record, best-effort fixture update, return the result
# ---------------------------------------------------------------------------
_ordo_provider_fake_result_template() {
  # <op> <key> ; prints {} when no template fixture exists
  local doc
  if doc=$(_ordo_provider_fake_load "$1" "$2" 2>/dev/null); then printf '%s\n' "$doc"; else printf '{}\n'; fi
}

ordo_provider_adapter_fake_issue_create() {
  local n result
  n=$(_ordo_provider_fake_next_number) || return $?
  result=$(_ordo_provider_fake_result_template issue_create default | jq -c --argjson n "$n" --arg repo "$ORDO_PV_REPO" \
    --arg title "$ORDO_PV_TITLE" --argjson labels "$(_ordo_provider_fake_labels_json "${ORDO_PV_LABELS[@]}")" \
    '{"number": $n, "url": ("https://fake.invalid/" + $repo + "/issues/" + ($n | tostring)), "title": $title, "labels": $labels} + .')
  _ordo_provider_fake_record "$(jq -cn --argjson r "$result" --arg body "$(cat "${ORDO_PV_BODY_PATH:-/dev/null}")" '{"result": $r, "body": $body}')"
  printf '%s\n' "$result"
}

ordo_provider_adapter_fake_issue_comment() {
  local result
  result=$(jq -cn --argjson n "$ORDO_PV_NUMBER" --arg repo "$ORDO_PV_REPO" \
    '{"number": $n, "url": ("https://fake.invalid/" + $repo + "/issues/" + ($n | tostring) + "#comment")}')
  _ordo_provider_fake_record "$(jq -cn --argjson r "$result" --arg body "$(cat "${ORDO_PV_BODY_PATH:-/dev/null}")" '{"result": $r, "body": $body}')"
  printf '%s\n' "$result"
}

_ordo_provider_fake_edit_common() {
  local topic="$1" fixture_op="${1}_get" add remove result
  add=$(_ordo_provider_fake_labels_json "${ORDO_PV_ADD_LABELS[@]}")
  remove=$(_ordo_provider_fake_labels_json "${ORDO_PV_REMOVE_LABELS[@]}")
  _ordo_provider_fake_update_fixture "$fixture_op" "$ORDO_PV_NUMBER" \
    "$(jq -cn --argjson add "$add" --argjson remove "$remove" --arg state "$ORDO_PV_STATE" --arg title "$ORDO_PV_TITLE" \
        '"(.labels = ((.labels // []) + \($add) | unique) - \($remove))"
         + (if $state != "" then " | .state = \($state | tojson)" else "" end)
         + (if $title != "" then " | .title = \($title | tojson)" else "" end)' -r)"
  result=$(jq -cn --argjson n "$ORDO_PV_NUMBER" --arg repo "$ORDO_PV_REPO" --arg topic "$topic" --argjson add "$add" --argjson remove "$remove" --arg state "$ORDO_PV_STATE" \
    '{"number": $n, "url": ("https://fake.invalid/" + $repo + "/" + (if $topic == "pr" then "pull" else "issues" end) + "/" + ($n | tostring)),
      "labels_added": $add, "labels_removed": $remove} + (if $state != "" then {"state": $state} else {} end)')
  _ordo_provider_fake_record "$(jq -cn --argjson r "$result" '{"result": $r}')"
  printf '%s\n' "$result"
}

ordo_provider_adapter_fake_issue_edit() { _ordo_provider_fake_edit_common issue; }
ordo_provider_adapter_fake_pr_edit() { _ordo_provider_fake_edit_common pr; }

ordo_provider_adapter_fake_issue_labels() {
  if [[ "${#ORDO_PV_ADD_LABELS[@]}" -eq 0 && "${#ORDO_PV_REMOVE_LABELS[@]}" -eq 0 ]]; then
    ordo_provider_adapter_error usage "issue_labels needs --add <label> and/or --remove <label>" false '{"missing":"labels"}'
    return $?
  fi
  ORDO_PV_STATE="" ORDO_PV_TITLE=""
  _ordo_provider_fake_edit_common issue
}

ordo_provider_adapter_fake_pr_create() {
  local n result
  n=$(_ordo_provider_fake_next_number) || return $?
  result=$(_ordo_provider_fake_result_template pr_create default | jq -c --argjson n "$n" --arg repo "$ORDO_PV_REPO" \
    --arg head "$ORDO_PV_HEAD" --arg base "$ORDO_PV_BASE" --argjson draft "$([[ "$ORDO_PV_DRAFT" -eq 1 ]] && echo true || echo false)" \
    '{"number": $n, "url": ("https://fake.invalid/" + $repo + "/pull/" + ($n | tostring)), "head": {"ref": $head}, "base": {"ref": $base}, "draft": $draft} + .')
  _ordo_provider_fake_record "$(jq -cn --argjson r "$result" --arg title "$ORDO_PV_TITLE" '{"result": $r, "title": $title}')"
  printf '%s\n' "$result"
}

ordo_provider_adapter_fake_pr_ready() {
  local draft result
  draft=$([[ "$ORDO_PV_UNDO" -eq 1 ]] && echo true || echo false)
  _ordo_provider_fake_update_fixture pr_get "$ORDO_PV_NUMBER" ".draft = ${draft}"
  result=$(jq -cn --argjson n "$ORDO_PV_NUMBER" --argjson d "$draft" '{"number": $n, "draft": $d}')
  _ordo_provider_fake_record "$(jq -cn --argjson r "$result" '{"result": $r}')"
  printf '%s\n' "$result"
}

ordo_provider_adapter_fake_pr_merge() {
  local method="${ORDO_PV_METHOD:-squash}" result
  case "$method" in
    squash|merge|rebase) ;;
    *)
      ordo_provider_adapter_error bad_argument "unknown merge method '${method}' (squash|merge|rebase)" false "$(jq -cn --arg m "$method" '{"method": $m}')"
      return $?
      ;;
  esac
  local pr
  if pr=$(_ordo_provider_fake_load pr_get "$ORDO_PV_NUMBER" 2>/dev/null); then
    local state
    state=$(printf '%s' "$pr" | jq -r '.state // "open"')
    if [[ "$ORDO_PV_DISABLE_AUTO" -eq 0 && "$ORDO_PV_AUTO" -eq 0 && "$state" != "open" ]]; then
      ordo_provider_adapter_error conflict "pull request #${ORDO_PV_NUMBER} is ${state}, not mergeable" false \
        "$(jq -cn --argjson n "$ORDO_PV_NUMBER" --arg s "$state" '{"number": $n, "state": $s, "category": "conflict"}')"
      return $?
    fi
  fi
  local merged=true action=merged
  if [[ "$ORDO_PV_DISABLE_AUTO" -eq 1 ]]; then merged=false; action=auto_merge_disabled
  elif [[ "$ORDO_PV_AUTO" -eq 1 ]]; then merged=false; action=auto_merge_enabled
  else
    _ordo_provider_fake_update_fixture pr_get "$ORDO_PV_NUMBER" ".state = \"merged\" | .merged_at = \"$(ordo_contracts_now)\""
  fi
  result=$(jq -cn --argjson n "$ORDO_PV_NUMBER" --arg m "$method" --argjson merged "$merged" --arg action "$action" \
    --argjson admin "$([[ "$ORDO_PV_ADMIN" -eq 1 ]] && echo true || echo false)" \
    '{"number": $n, "merged": $merged, "action": $action, "method": $m, "admin": $admin}')
  _ordo_provider_fake_record "$(jq -cn --argjson r "$result" '{"result": $r}')"
  printf '%s\n' "$result"
}

ordo_provider_adapter_fake_pr_review() {
  local state result
  case "$ORDO_PV_EVENT" in
    approve) state=approved ;;
    request_changes) state=changes_requested ;;
    *) state=commented ;;
  esac
  _ordo_provider_fake_update_fixture pr_get "$ORDO_PV_NUMBER" \
    "$(jq -cn --arg s "$state" '"if \($s | tojson) == \"commented\" then . else .review_decision = \($s | tojson) end"' -r)"
  result=$(jq -cn --argjson n "$ORDO_PV_NUMBER" --arg e "$ORDO_PV_EVENT" --arg s "$state" --arg repo "$ORDO_PV_REPO" \
    '{"number": $n, "event": $e, "state": $s, "url": ("https://fake.invalid/" + $repo + "/pull/" + ($n | tostring) + "#review")}')
  _ordo_provider_fake_record "$(jq -cn --argjson r "$result" --arg body "$(cat "${ORDO_PV_BODY_PATH:-/dev/null}")" '{"result": $r, "body": $body}')"
  printf '%s\n' "$result"
}

ordo_provider_adapter_fake_mutate() {
  local result
  result=$(jq -cn --argjson args "$(printf '%s\n' "${ORDO_PV_NATIVE[@]}" | jq -R . | jq -sc .)" \
    '{"backend": "fixtures", "args": $args, "stdout": ""}')
  _ordo_provider_fake_record "$(jq -cn --argjson r "$result" '{"result": $r}')"
  printf '%s\n' "$result"
}
