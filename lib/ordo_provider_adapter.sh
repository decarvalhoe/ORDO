#!/usr/bin/env bash
# lib/ordo_provider_adapter.sh — forge-neutral provider adapter boundary
# (#811, epic #806).
#
# One generic entry point, `ordo_provider <op> [args]`, dispatching on
# ORDO_PROVIDER_ADAPTER=github|forgejo|gitlab|fake (default github for
# backward compatibility). The vocabulary is generic: issue, pr (pull request
# on GitHub/Forgejo, merge request on GitLab), check, review, run, mutation.
# No `gh`-specific concept crosses this boundary: every adapter returns the
# SAME normalised JSON shape per op (documented in docs/architecture/adapters.md)
# and every failure is a typed error object with `details.retryable`.
#
# Ops (read):  auth_status repo_get issue_get issue_list pr_get pr_list
#              pr_files checks_get review_list run_list run_get
# Ops (mutate): issue_create issue_edit issue_comment issue_labels
#              pr_create pr_edit pr_ready pr_merge mutate
#
# Mutation policy (authoritative, never bypassed):
#   1. every mutating op requires --idempotency-key <K>;
#   2. the per-project ledger <state_dir>/ordo-provider-idempotency.jsonl is
#      consulted first: a known key returns the recorded receipt without
#      re-executing (exit 0, details.replayed=true); the same key with a
#      different op is a conflict (exit 5);
#   3. the scope is asserted through lib/external_mutation_gate.sh
#      (external_pr_mutation_assert) — audit-only by default, authorised via
#      ORCH_EXTERNAL_PR_MUTATIONS — a refusal is exit 3 (policy_refused);
#   4. only then does the backend execute; the github backend additionally
#      runs every gh mutation through external_pr_mutation_run so the
#      existing classification of gh arguments stays in force;
#   5. the receipt is appended to the ledger.
#
# Registry: ORDO_PROVIDER_ADAPTER_REGISTRY lists <name>|<status>. A backend
# is implemented by lib/ordo_provider_adapter_<name>.sh defining
# `ordo_provider_adapter_<name>_<op>` functions that print the bare payload;
# this file adds the envelope {"op","adapter","repo"} (reads) or the
# mutation receipt {"op","adapter","repo","details":{...},"result":{...}}.
# forgejo and gitlab are implemented by #815 (REST through curl, see
# lib/ordo_provider_adapter_http.sh); a registered name whose file is
# missing falls back to a stub returning provider_not_available (exit 6).
#
# Config knobs:
#   ORDO_PROVIDER_ADAPTER    github|forgejo|gitlab|fake (default github)
#   ORDO_FORGE_REPO          owner/repo used when --repo is absent (falls back to GH_REPO)
#   ORDO_FORGE_URL           forge base URL (REST adapters; for github it sets GH_HOST)
#   ORDO_FORGE_TOKEN_FILE    path to a token file (read by REST adapters, never logged)
#   ORDO_FAKE_ADAPTER_DIR    fixture root of the fake adapter
#   ORDO_PROVIDER_TIMEOUT_SEC  per-call timeout for the backend CLI/HTTP (default 30)
#   ORDO_PROVIDER_LEDGER_FILE  override of the idempotency ledger path
#
# Public API:
#   ordo_provider <op> [args...]
#   ordo_provider_adapter_name / _ops / _mutating_ops / _names / _status <name>
#   ordo_provider_adapter_error <code> <message> <retryable> [details-json]
#   ordo_provider_adapter_scope_for <op>        # gate scope of a parsed mutation
#   ordo_provider_adapter_ledger_file
#   ordo_provider_adapter_token                 # prints the token from ORDO_FORGE_TOKEN_FILE
#   ordo_provider_adapter_parse_args <op> [args...]   # sets ORDO_PV_* for backends
#
# Dependencies: bash >= 4, jq, coreutils. gh only inside the github backend.

if [[ -n "${ORDO_PROVIDER_ADAPTER_LIB_LOADED:-}" ]]; then
  return 0
fi
ORDO_PROVIDER_ADAPTER_LIB_LOADED=1

_ORDO_PROVIDER_ADAPTER_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/ordo_contracts.sh
source "$_ORDO_PROVIDER_ADAPTER_LIB_DIR/ordo_contracts.sh"
# shellcheck source=lib/external_mutation_gate.sh
source "$_ORDO_PROVIDER_ADAPTER_LIB_DIR/external_mutation_gate.sh"

ORDO_PROVIDER_ADAPTER_MODULE="provider_adapter"
ORDO_PROVIDER_ADAPTER_OPS="auth_status repo_get issue_get issue_list issue_create issue_edit issue_comment issue_labels pr_get pr_list pr_create pr_edit pr_ready pr_merge pr_files checks_get review_list run_list run_get mutate"
ORDO_PROVIDER_ADAPTER_MUTATING_OPS="issue_create issue_edit issue_comment issue_labels pr_create pr_edit pr_ready pr_merge mutate"
# <name>|<status>; status = implemented | stub:<issue>. forgejo and gitlab
# were stubs until #815 added lib/ordo_provider_adapter_<name>.sh — the
# loader prefers the file whenever it exists, so the line is documentation.
ORDO_PROVIDER_ADAPTER_REGISTRY="github|implemented forgejo|implemented gitlab|implemented fake|implemented"
: "${ORDO_PROVIDER_ADAPTER:=github}"
: "${ORDO_PROVIDER_TIMEOUT_SEC:=30}"
: "${ORDO_PROVIDER_DEFAULT_LIMIT:=30}"

ordo_provider_adapter_name() { printf '%s\n' "${ORDO_PROVIDER_ADAPTER:-github}"; }

ordo_provider_adapter_ops() {
  local op
  for op in $ORDO_PROVIDER_ADAPTER_OPS; do printf '%s\n' "$op"; done
}

ordo_provider_adapter_mutating_ops() {
  local op
  for op in $ORDO_PROVIDER_ADAPTER_MUTATING_OPS; do printf '%s\n' "$op"; done
}

ordo_provider_adapter_names() {
  local entry
  for entry in $ORDO_PROVIDER_ADAPTER_REGISTRY; do printf '%s\n' "${entry%%|*}"; done
}

# ordo_provider_adapter_status <name>  -> implemented | stub:<issue> | unknown
ordo_provider_adapter_status() {
  local name="${1-}" entry
  for entry in $ORDO_PROVIDER_ADAPTER_REGISTRY; do
    if [[ "${entry%%|*}" == "$name" ]]; then
      if [[ -f "$_ORDO_PROVIDER_ADAPTER_LIB_DIR/ordo_provider_adapter_${name}.sh" ]]; then
        printf 'implemented\n'
      else
        printf '%s\n' "${entry#*|}"
      fi
      return 0
    fi
  done
  printf 'unknown\n'
  return 1
}

ordo_provider_adapter_is_op() {
  local op="${1-}" o
  for o in $ORDO_PROVIDER_ADAPTER_OPS; do [[ "$o" == "$op" ]] && return 0; done
  return 1
}

ordo_provider_adapter_is_mutating() {
  local op="${1-}" o
  for o in $ORDO_PROVIDER_ADAPTER_MUTATING_OPS; do [[ "$o" == "$op" ]] && return 0; done
  return 1
}

# ordo_provider_adapter_error <code> <message> <retryable:true|false> [details-json]
ordo_provider_adapter_error() {
  local code="${1:?}" message="${2:?}" retryable="${3:-false}" details="${4:-{\}}"
  local merged
  merged=$(printf '%s' "$details" | jq -c --arg r "$retryable" --arg a "$(ordo_provider_adapter_name)" \
    '(if type == "object" then . else {"value": .} end) + {"retryable": ($r == "true"), "adapter": $a}' 2>/dev/null) \
    || merged=$(jq -cn --arg r "$retryable" --arg a "$(ordo_provider_adapter_name)" '{"retryable": ($r == "true"), "adapter": $a}')
  ordo_contracts_error "$ORDO_PROVIDER_ADAPTER_MODULE" "$code" "$message" "$merged"
}

# Token access for REST adapters: read from ORDO_FORGE_TOKEN_FILE, never
# echoed by this library anywhere else. Returns 4 when the file is unreadable.
ordo_provider_adapter_token() {
  local file="${ORDO_FORGE_TOKEN_FILE:-}"
  [[ -n "$file" && -r "$file" ]] || return 4
  tr -d '\r\n' < "$file"
}

ordo_provider_adapter_forge_url() { printf '%s\n' "${ORDO_FORGE_URL:-}"; }

ordo_provider_adapter_ledger_file() {
  local file
  if [[ -n "${ORDO_PROVIDER_LEDGER_FILE:-}" ]]; then
    file="$ORDO_PROVIDER_LEDGER_FILE"
  elif declare -F state_dir >/dev/null 2>&1; then
    file="$(state_dir)/ordo-provider-idempotency.jsonl"
  else
    file="${ORCH_STATE_BASE:-${XDG_DATA_HOME:-$HOME/.local/share}/orch-state}/${PROJECT:-default}/ordo-provider-idempotency.jsonl"
  fi
  mkdir -p "$(dirname "$file")" 2>/dev/null || true
  printf '%s\n' "$file"
}

# ordo_provider_adapter_run_with_timeout <cmd...>  (backend helper)
ordo_provider_adapter_run_with_timeout() {
  if declare -F orch_run_timeout >/dev/null 2>&1; then
    orch_run_timeout "$ORDO_PROVIDER_TIMEOUT_SEC" "$@"
  elif command -v timeout >/dev/null 2>&1; then
    timeout "$ORDO_PROVIDER_TIMEOUT_SEC" "$@"
  else
    "$@"
  fi
}

# ---------------------------------------------------------------------------
# Argument parsing shared by all backends. Sets ORDO_PV_* globals.
# ---------------------------------------------------------------------------
# shellcheck disable=SC2034 # ORDO_PV_* are consumed by the backend files
ordo_provider_adapter_parse_args() {
  local op="${1:?}"
  shift
  ORDO_PV_OP="$op"
  ORDO_PV_NUMBER="" ORDO_PV_REPO="" ORDO_PV_KEY="" ORDO_PV_STATE="" ORDO_PV_LIMIT="" ORDO_PV_PAGE=""
  ORDO_PV_ASSIGNEE="" ORDO_PV_AUTHOR="" ORDO_PV_SEARCH="" ORDO_PV_BASE="" ORDO_PV_HEAD="" ORDO_PV_BRANCH=""
  ORDO_PV_COMMIT="" ORDO_PV_WORKFLOW="" ORDO_PV_TITLE="" ORDO_PV_BODY="" ORDO_PV_BODY_FILE="" ORDO_PV_BODY_SET=0
  ORDO_PV_DRAFT=0 ORDO_PV_METHOD="" ORDO_PV_ADMIN=0 ORDO_PV_AUTO=0 ORDO_PV_DISABLE_AUTO=0 ORDO_PV_DELETE_BRANCH=0
  ORDO_PV_UNDO=0 ORDO_PV_REASON="" ORDO_PV_SCOPE="" ORDO_PV_REF="" ORDO_PV_WITH="" ORDO_PV_MILESTONE=""
  ORDO_PV_LABELS=() ORDO_PV_ADD_LABELS=() ORDO_PV_REMOVE_LABELS=() ORDO_PV_ADD_ASSIGNEES=() ORDO_PV_REMOVE_ASSIGNEES=()
  ORDO_PV_NATIVE=() ORDO_PV_POSITIONAL=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo|-R) ORDO_PV_REPO="${2-}"; shift 2 ;;
      --idempotency-key|-k) ORDO_PV_KEY="${2-}"; shift 2 ;;
      --state) ORDO_PV_STATE="${2-}"; shift 2 ;;
      --limit) ORDO_PV_LIMIT="${2-}"; shift 2 ;;
      --page) ORDO_PV_PAGE="${2-}"; shift 2 ;;
      --label) ORDO_PV_LABELS+=("${2-}"); shift 2 ;;
      --add-label) ORDO_PV_ADD_LABELS+=("${2-}"); shift 2 ;;
      --remove-label) ORDO_PV_REMOVE_LABELS+=("${2-}"); shift 2 ;;
      --add) ORDO_PV_ADD_LABELS+=("${2-}"); shift 2 ;;
      --remove) ORDO_PV_REMOVE_LABELS+=("${2-}"); shift 2 ;;
      --assignee) ORDO_PV_ASSIGNEE="${2-}"; ORDO_PV_ADD_ASSIGNEES+=("${2-}"); shift 2 ;;
      --add-assignee) ORDO_PV_ADD_ASSIGNEES+=("${2-}"); shift 2 ;;
      --remove-assignee) ORDO_PV_REMOVE_ASSIGNEES+=("${2-}"); shift 2 ;;
      --author) ORDO_PV_AUTHOR="${2-}"; shift 2 ;;
      --search) ORDO_PV_SEARCH="${2-}"; shift 2 ;;
      --base) ORDO_PV_BASE="${2-}"; shift 2 ;;
      --head) ORDO_PV_HEAD="${2-}"; shift 2 ;;
      --branch) ORDO_PV_BRANCH="${2-}"; shift 2 ;;
      --commit) ORDO_PV_COMMIT="${2-}"; shift 2 ;;
      --workflow) ORDO_PV_WORKFLOW="${2-}"; shift 2 ;;
      --title) ORDO_PV_TITLE="${2-}"; shift 2 ;;
      --body) ORDO_PV_BODY="${2-}"; ORDO_PV_BODY_SET=1; shift 2 ;;
      --body-file) ORDO_PV_BODY_FILE="${2-}"; ORDO_PV_BODY_SET=1; shift 2 ;;
      --milestone) ORDO_PV_MILESTONE="${2-}"; shift 2 ;;
      --draft) ORDO_PV_DRAFT=1; shift ;;
      --method) ORDO_PV_METHOD="${2-}"; shift 2 ;;
      --squash|--merge|--rebase) ORDO_PV_METHOD="${1#--}"; shift ;;
      --admin) ORDO_PV_ADMIN=1; shift ;;
      --auto) ORDO_PV_AUTO=1; shift ;;
      --disable-auto) ORDO_PV_DISABLE_AUTO=1; shift ;;
      --delete-branch) ORDO_PV_DELETE_BRANCH=1; shift ;;
      --undo) ORDO_PV_UNDO=1; shift ;;
      --reason) ORDO_PV_REASON="${2-}"; shift 2 ;;
      --scope) ORDO_PV_SCOPE="${2-}"; shift 2 ;;
      --ref) ORDO_PV_REF="${2-}"; shift 2 ;;
      --with) ORDO_PV_WITH="${2-}"; shift 2 ;;
      --) shift; ORDO_PV_NATIVE=("$@"); break ;;
      -*)
        ordo_provider_adapter_error bad_argument "unknown argument for ${op}: $1" false \
          "$(jq -cn --arg op "$op" --arg arg "$1" '{"op": $op, "argument": $arg}')"
        return $?
        ;;
      *) ORDO_PV_POSITIONAL+=("$1"); shift ;;
    esac
  done
  ORDO_PV_NUMBER="${ORDO_PV_POSITIONAL[0]:-}"
  ORDO_PV_REPO="${ORDO_PV_REPO:-${ORDO_FORGE_REPO:-${GH_REPO:-}}}"
  ORDO_PV_LIMIT="${ORDO_PV_LIMIT:-$ORDO_PROVIDER_DEFAULT_LIMIT}"
  ORDO_PV_PAGE="${ORDO_PV_PAGE:-1}"
  local v
  for v in "$ORDO_PV_LIMIT" "$ORDO_PV_PAGE"; do
    if ! [[ "$v" =~ ^[1-9][0-9]*$ ]]; then
      ordo_provider_adapter_error bad_argument "--limit and --page must be positive integers" false \
        "$(jq -cn --arg limit "$ORDO_PV_LIMIT" --arg page "$ORDO_PV_PAGE" '{"limit": $limit, "page": $page}')"
      return $?
    fi
  done
  case "$op" in
    issue_get|issue_edit|issue_comment|issue_labels|pr_get|pr_edit|pr_ready|pr_merge|pr_files|checks_get|review_list|run_get)
      if ! [[ "$ORDO_PV_NUMBER" =~ ^[0-9]+$ ]]; then
        ordo_provider_adapter_error usage "usage: ordo_provider ${op} <number> [--repo owner/repo] [flags]" false \
          "$(jq -cn --arg op "$op" --arg n "$ORDO_PV_NUMBER" '{"op": $op, "number": $n, "missing": "number"}')"
        return $?
      fi
      ;;
    issue_create|pr_create)
      if [[ -z "$ORDO_PV_TITLE" ]]; then
        ordo_provider_adapter_error usage "usage: ordo_provider ${op} --title T [--body B|--body-file F] ... --idempotency-key K" false \
          "$(jq -cn --arg op "$op" '{"op": $op, "missing": "title"}')"
        return $?
      fi
      if [[ "$op" == pr_create && -z "$ORDO_PV_HEAD" ]]; then
        ordo_provider_adapter_error usage "usage: ordo_provider pr_create --title T --head BRANCH [--base BRANCH] ... --idempotency-key K" false \
          "$(jq -cn '{"op": "pr_create", "missing": "head"}')"
        return $?
      fi
      ;;
    mutate)
      if [[ -z "$ORDO_PV_SCOPE" || "${#ORDO_PV_NATIVE[@]}" -eq 0 ]]; then
        ordo_provider_adapter_error usage "usage: ordo_provider mutate --scope <gate-scope> --idempotency-key K -- <adapter-native args>" false \
          "$(jq -cn --arg s "$ORDO_PV_SCOPE" '{"op": "mutate", "scope": $s, "missing": (if $s == "" then "scope" else "native args" end)}')"
        return $?
      fi
      ;;
  esac
  if [[ "$op" != auth_status && -z "$ORDO_PV_REPO" ]]; then
    ordo_provider_adapter_error usage "no repository: pass --repo owner/repo or set ORDO_FORGE_REPO (GH_REPO is honoured as a fallback)" false \
      "$(jq -cn --arg op "$op" '{"op": $op, "missing": "repo"}')"
    return $?
  fi
  if [[ -n "$ORDO_PV_BODY_FILE" && ! -r "$ORDO_PV_BODY_FILE" ]]; then
    ordo_provider_adapter_error not_found "body file not readable: ${ORDO_PV_BODY_FILE}" false \
      "$(jq -cn --arg f "$ORDO_PV_BODY_FILE" '{"body_file": $f}')"
    return $?
  fi
  return 0
}

# Gate scope of the parsed mutation (uses ORDO_PV_*). Mirrors the
# classification of external_pr_mutation_classify_gh_args so the same
# policy names apply whatever the backend.
ordo_provider_adapter_scope_for() {
  case "${1:?}" in
    issue_create) printf 'issue_create\n' ;;
    issue_comment) printf 'issue_comment\n' ;;
    issue_labels) printf 'issue_labels\n' ;;
    pr_create) printf 'pr_state\n' ;;
    pr_ready) printf 'pr_ready\n' ;;
    pr_merge) printf 'pr_merge\n' ;;
    issue_edit|pr_edit)
      local subject="${1%%_edit}"
      case "$ORDO_PV_STATE" in
        closed) printf '%s_close\n' "$subject"; return 0 ;;
        open) printf '%s_reopen\n' "$subject"; return 0 ;;
      esac
      if [[ -z "$ORDO_PV_TITLE" && "$ORDO_PV_BODY_SET" -eq 0 && -z "$ORDO_PV_BASE" && -z "$ORDO_PV_MILESTONE" ]]; then
        if [[ "${#ORDO_PV_ADD_LABELS[@]}" -gt 0 || "${#ORDO_PV_REMOVE_LABELS[@]}" -gt 0 ]] \
          && [[ "${#ORDO_PV_ADD_ASSIGNEES[@]}" -eq 0 && "${#ORDO_PV_REMOVE_ASSIGNEES[@]}" -eq 0 ]]; then
          printf '%s_labels\n' "$subject"; return 0
        fi
        if [[ "${#ORDO_PV_ADD_ASSIGNEES[@]}" -gt 0 || "${#ORDO_PV_REMOVE_ASSIGNEES[@]}" -gt 0 ]] \
          && [[ "${#ORDO_PV_ADD_LABELS[@]}" -eq 0 && "${#ORDO_PV_REMOVE_LABELS[@]}" -eq 0 ]]; then
          printf '%s_assignees\n' "$subject"; return 0
        fi
      fi
      printf '%s_edit\n' "$subject"
      ;;
    mutate) printf '%s\n' "$ORDO_PV_SCOPE" ;;
    *) return 1 ;;
  esac
}

# Materialise --body into a temp file (gh_body_helpers doctrine: bodies
# travel by file, never through argv). Sets ORDO_PV_BODY_PATH (the file the
# backend must use, or empty) and ORDO_PV_BODY_TMP (the temp file to remove
# afterwards, or empty). Runs in the caller's shell so the globals stick.
# shellcheck disable=SC2034 # ORDO_PV_BODY_PATH is read by the backends
_ordo_provider_adapter_body_file() {
  ORDO_PV_BODY_PATH="" ORDO_PV_BODY_TMP=""
  if [[ -n "$ORDO_PV_BODY_FILE" ]]; then
    ORDO_PV_BODY_PATH="$ORDO_PV_BODY_FILE"
  elif [[ "$ORDO_PV_BODY_SET" -eq 1 ]]; then
    ORDO_PV_BODY_TMP=$(mktemp "${TMPDIR:-/tmp}/ordo_provider_body.XXXXXX") || return 1
    printf '%s\n' "$ORDO_PV_BODY" > "$ORDO_PV_BODY_TMP"
    ORDO_PV_BODY_PATH="$ORDO_PV_BODY_TMP"
  fi
}

_ordo_provider_adapter_load() {
  local name="$1"
  local file="$_ORDO_PROVIDER_ADAPTER_LIB_DIR/ordo_provider_adapter_${name}.sh"
  if declare -F "ordo_provider_adapter_${name}_auth_status" >/dev/null 2>&1; then
    return 0
  fi
  if [[ -f "$file" ]]; then
    # shellcheck disable=SC1090 # adapter file selected at runtime
    source "$file"
    return 0
  fi
  return 1
}

_ordo_provider_adapter_envelope() {
  local op="$1" repo="$2" payload="$3"
  jq -cn --arg op "$op" --arg adapter "$(ordo_provider_adapter_name)" --arg repo "$repo" --argjson payload "$payload" \
    '{"op": $op, "adapter": $adapter, "repo": $repo} + $payload'
}

# ordo_provider <op> [args...]
ordo_provider() {
  local op="${1-}"
  if [[ -z "$op" ]]; then
    ordo_provider_adapter_error usage "usage: ordo_provider <op> [args] (ops: ${ORDO_PROVIDER_ADAPTER_OPS})" false
    return $?
  fi
  shift
  case "$op" in
    ops) ordo_provider_adapter_ops; return 0 ;;
    adapters) ordo_provider_adapter_names; return 0 ;;
  esac
  if ! ordo_provider_adapter_is_op "$op"; then
    ordo_provider_adapter_error unknown_command "unknown provider op: '${op}'" false \
      "$(jq -cn --arg op "$op" --arg ops "$ORDO_PROVIDER_ADAPTER_OPS" '{"op": $op, "known": ($ops | split(" "))}')"
    return $?
  fi
  local name status
  name=$(ordo_provider_adapter_name)
  status=$(ordo_provider_adapter_status "$name") || {
    ordo_provider_adapter_error bad_argument "unknown provider adapter: '${name}' (ORDO_PROVIDER_ADAPTER)" false \
      "$(jq -cn --arg name "$name" --arg known "$(ordo_provider_adapter_names | paste -sd' ' -)" '{"adapter": $name, "known": ($known | split(" "))}')"
    return $?
  }
  if ! _ordo_provider_adapter_load "$name"; then
    ordo_provider_adapter_error provider_not_available "provider adapter '${name}' is registered but not implemented yet (${status#stub:} adds it)" false \
      "$(jq -cn --arg name "$name" --arg status "$status" --arg op "$op" \
          '{"adapter": $name, "status": $status, "op": $op, "implemented_by": ($status | sub("^stub:"; "")), "expected_file": ("lib/ordo_provider_adapter_" + $name + ".sh")}')"
    return $?
  fi
  local fn="ordo_provider_adapter_${name}_${op}"
  if ! declare -F "$fn" >/dev/null 2>&1; then
    ordo_provider_adapter_error not_implemented "provider adapter '${name}' does not implement op '${op}'" false \
      "$(jq -cn --arg name "$name" --arg op "$op" '{"adapter": $name, "op": $op}')"
    return $?
  fi
  ordo_provider_adapter_parse_args "$op" "$@" || return $?
  if [[ "$status" == stub:* ]]; then
    # Registered stub (#815 not landed): typed provider_not_available, before
    # any policy or ledger side effect.
    "$fn"
    return $?
  fi
  if ordo_provider_adapter_is_mutating "$op"; then
    _ordo_provider_adapter_mutate "$name" "$op" "$fn"
    return $?
  fi
  local payload rc=0
  payload=$("$fn") || rc=$?
  [[ "$rc" -eq 0 ]] || return "$rc"
  if ! printf '%s' "$payload" | jq -e 'type == "object"' >/dev/null 2>&1; then
    ordo_provider_adapter_error internal_error "backend ${name} returned a non-object payload for ${op}" false \
      "$(jq -cn --arg op "$op" '{"op": $op}')"
    return $?
  fi
  _ordo_provider_adapter_envelope "$op" "$ORDO_PV_REPO" "$payload"
}

# shellcheck disable=SC2034 # ORDO_PV_BODY_PATH/SCOPE_RESOLVED/CONTEXT are read by the backends
_ordo_provider_adapter_mutate() {
  local name="$1" op="$2" fn="$3"
  if [[ -z "$ORDO_PV_KEY" ]]; then
    ordo_provider_adapter_error usage "${op} is a mutation and requires --idempotency-key <key>" false \
      "$(jq -cn --arg op "$op" '{"op": $op, "missing": "idempotency_key"}')"
    return $?
  fi
  local scope
  scope=$(ordo_provider_adapter_scope_for "$op") || scope=""
  if ! external_pr_mutation_scope_known "$scope"; then
    ordo_provider_adapter_error bad_argument "unknown mutation scope '${scope}' for ${op}" false \
      "$(jq -cn --arg op "$op" --arg scope "$scope" --arg known "$(external_pr_mutation_known_scopes | paste -sd' ' -)" \
          '{"op": $op, "scope": $scope, "known": ($known | split(" "))}')"
    return $?
  fi
  # 1. idempotency ledger: replay a known key without re-executing.
  local ledger recorded
  ledger=$(ordo_provider_adapter_ledger_file)
  if [[ -f "$ledger" ]]; then
    recorded=$(jq -c --arg k "$ORDO_PV_KEY" 'select(.idempotency_key == $k)' "$ledger" 2>/dev/null | tail -n 1)
    if [[ -n "$recorded" ]]; then
      local recorded_op
      recorded_op=$(printf '%s' "$recorded" | jq -r '.op')
      if [[ "$recorded_op" != "$op" ]]; then
        ordo_provider_adapter_error conflict "idempotency key '${ORDO_PV_KEY}' was already used for op ${recorded_op}" false \
          "$(printf '%s' "$recorded" | jq -c --arg op "$op" '{"idempotency_key": .idempotency_key, "recorded_op": .op, "requested_op": $op, "recorded_at": .ts}')"
        return $?
      fi
      printf '%s' "$recorded" | jq -c '.receipt | .details.replayed = true'
      return 0
    fi
  fi
  # 2. policy gate (authoritative): audit-only unless the scope is authorised.
  local context="provider_adapter:${name}:${op}:${ORDO_PV_REPO}${ORDO_PV_NUMBER:+#$ORDO_PV_NUMBER}"
  local gate_rc=0
  external_pr_mutation_assert "$scope" "$context" 2>/dev/null || gate_rc=$?
  if [[ "$gate_rc" -ne 0 ]]; then
    ordo_provider_adapter_error policy_refused "mutation ${op} (scope ${scope}) refused by the external mutation policy" false \
      "$(jq -cn --arg op "$op" --arg scope "$scope" --argjson gate_exit "$gate_rc" --arg ctx "$context" \
          '{"op": $op, "scope": $scope, "gate_exit": $gate_exit, "context": $ctx, "authorize_via": "ORCH_EXTERNAL_PR_MUTATIONS"}')"
    return $?
  fi
  # 3. execute through the backend.
  if ! _ordo_provider_adapter_body_file; then
    ordo_provider_adapter_error internal_error "could not stage the body file" false
    return $?
  fi
  ORDO_PV_SCOPE_RESOLVED="$scope"
  ORDO_PV_CONTEXT="$context"
  local payload rc=0
  payload=$("$fn") || rc=$?
  [[ -z "${ORDO_PV_BODY_TMP:-}" ]] || rm -f "$ORDO_PV_BODY_TMP"
  [[ "$rc" -eq 0 ]] || return "$rc"
  if ! printf '%s' "$payload" | jq -e 'type == "object"' >/dev/null 2>&1; then
    payload=$(jq -cn --arg raw "$payload" '{"raw": $raw}')
  fi
  # 4. receipt + ledger.
  local ts receipt
  ts=$(ordo_contracts_now)
  receipt=$(jq -cn --arg op "$op" --arg adapter "$name" --arg repo "$ORDO_PV_REPO" --arg key "$ORDO_PV_KEY" \
    --arg scope "$scope" --arg ts "$ts" --argjson result "$payload" \
    '{"op": $op, "adapter": $adapter, "repo": $repo,
      "details": {"idempotency_key": $key, "replayed": false, "scope": $scope, "recorded_at": $ts},
      "result": $result}')
  jq -cn --arg key "$ORDO_PV_KEY" --arg op "$op" --arg adapter "$name" --arg repo "$ORDO_PV_REPO" --arg scope "$scope" \
    --arg ts "$ts" --argjson receipt "$receipt" \
    '{"idempotency_key": $key, "op": $op, "adapter": $adapter, "repo": $repo, "scope": $scope, "ts": $ts, "receipt": $receipt}' \
    >> "$ledger"
  printf '%s\n' "$receipt"
}

# ---------------------------------------------------------------------------
# Stubs for registered-but-unimplemented adapters (#815 replaces them by
# adding lib/ordo_provider_adapter_forgejo.sh / _gitlab.sh; the loader
# prefers a file over these functions).
# ---------------------------------------------------------------------------
_ordo_provider_adapter_define_stub() {
  local name="$1" issue="$2" op
  for op in $ORDO_PROVIDER_ADAPTER_OPS; do
    eval "ordo_provider_adapter_${name}_${op}() {
      ordo_provider_adapter_error provider_not_available \
        \"provider adapter '${name}' is not implemented yet: ${issue} adds it (op ${op})\" false \
        \"\$(jq -cn '{\"adapter\": \"${name}\", \"op\": \"${op}\", \"implemented_by\": \"${issue}\"}')\"
    }"
  done
}
if [[ ! -f "$_ORDO_PROVIDER_ADAPTER_LIB_DIR/ordo_provider_adapter_forgejo.sh" ]]; then
  _ordo_provider_adapter_define_stub forgejo '#815'
fi
if [[ ! -f "$_ORDO_PROVIDER_ADAPTER_LIB_DIR/ordo_provider_adapter_gitlab.sh" ]]; then
  _ordo_provider_adapter_define_stub gitlab '#815'
fi
