#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2153 # jq programs use $vars; ORDO_PV_* are set by the generic layer
# lib/ordo_provider_adapter_http.sh — shared curl helper of the REST provider
# adapters (#815: forgejo, gitlab). Loaded by those backends; not a backend
# itself and not sourced by lib/ordo_provider_adapter.sh.
#
# Responsibilities:
#   - base URL (ORDO_FORGE_URL) and API path joining, URL encoding;
#   - the token: ORDO_FORGE_TOKEN_FILE (must be 0600-ish: group/other bits
#     => refused, exit 3) read through ordo_provider_adapter_token, else the
#     ORDO_FORGE_TOKEN environment variable. The token travels to curl through
#     a config document on stdin (`curl -K -`), never on the command line,
#     never in a file, never in a URL, never in any output, log or error;
#   - privileged requests (#818: pr_merge --admin, pr_review) may use a
#     separate credential: ORDO_FORGE_ADMIN_TOKEN_FILE (same mode rules) or
#     ORDO_FORGE_ADMIN_TOKEN, consulted first for requests made with
#     --privileged; when neither is set the ordinary token is used. This is
#     the REST counterpart of GH_TOKEN=<admin token> on the github backend;
#   - one request = one curl call with --max-time; the response status,
#     headers and body land in shell variables (ORDO_HTTP_STATUS,
#     ORDO_HTTP_HEADERS, ORDO_HTTP_BODY);
#   - classification of failures into the typed error objects of the
#     boundary: 404 -> not_found (4), 403 -> policy_refused (3, the forge
#     refused), 401 -> provider_error/auth (not retryable), 405/406/409/422 ->
#     conflict (5), 429 -> rate_limited (retryable, details.retry_after),
#     5xx -> provider_error/transient (retryable), curl transport errors ->
#     provider_error/transient or timeout (retryable for reads; a mutation
#     that timed out is NOT retryable because its outcome is unknown);
#   - optional bounded retries of *reads* on 429/5xx/transport errors
#     (ORDO_PROVIDER_HTTP_RETRIES, default 0; Retry-After honoured up to
#     ORDO_PROVIDER_HTTP_RETRY_MAX_SLEEP). Mutations are never retried here:
#     the idempotency key of the generic layer is the retry mechanism;
#   - pagination helpers: Link rel="next", X-Total-Count / X-Total /
#     X-Next-Page, and a "fetch every page" loop for small collections.
#
# Knobs: ORDO_FORGE_URL, ORDO_FORGE_TOKEN_FILE, ORDO_FORGE_TOKEN,
#   ORDO_PROVIDER_TIMEOUT_SEC (reads, default 30),
#   ORDO_PROVIDER_MUTATION_TIMEOUT_SEC (default 120),
#   ORDO_PROVIDER_HTTP_RETRIES (0), ORDO_PROVIDER_HTTP_RETRY_MAX_SLEEP (5),
#   ORDO_PROVIDER_HTTP_PAGE_SIZE (50), ORDO_PROVIDER_HTTP_MAX_PAGES (20),
#   ORDO_PROVIDER_HTTP_LOG (optional file: ts method url status ms — no
#   headers, no bodies), ORDO_PROVIDER_HTTP_CURL (binary, default curl).
#
# Public functions (all prefixed ordo_provider_http_):
#   ordo_provider_http_base_url <api-suffix>       # ORDO_FORGE_URL + /api/vN unless already present
#   ordo_provider_http_urlencode <string>
#   ordo_provider_http_query <k=v>...              # "?k=v&k2=v2" (encoded) or ""
#   ordo_provider_http_token [privileged]           # prints the token (mode-checked) or a typed error
#   ordo_provider_http_request <op> <auth-style> <method> <url> [--body-file F] [--body JSON] [--mutation] [--accept TYPE] [--allow-404] [--privileged]
#   ordo_provider_http_header <name>                # value of a response header (case-insensitive)
#   ordo_provider_http_has_next                     # 0 when the response has a next page
#   ordo_provider_http_json                         # response body as compact JSON (empty body -> null)
#   ordo_provider_http_get_all <op> <auth-style> <url> <page-param> <size-param> [jq-items-expr]
#   ordo_provider_http_mask <text>                  # masks the token and token-looking values

if [[ -n "${ORDO_PROVIDER_HTTP_LIB_LOADED:-}" ]]; then
  return 0
fi
ORDO_PROVIDER_HTTP_LIB_LOADED=1

: "${ORDO_PROVIDER_TIMEOUT_SEC:=30}"
: "${ORDO_PROVIDER_MUTATION_TIMEOUT_SEC:=120}"
: "${ORDO_PROVIDER_HTTP_RETRIES:=0}"
: "${ORDO_PROVIDER_HTTP_RETRY_MAX_SLEEP:=5}"
: "${ORDO_PROVIDER_HTTP_PAGE_SIZE:=50}"
: "${ORDO_PROVIDER_HTTP_MAX_PAGES:=20}"
: "${ORDO_PROVIDER_HTTP_CURL:=curl}"

# shellcheck disable=SC2034 # read by the backends
ORDO_HTTP_STATUS="" ORDO_HTTP_HEADERS="" ORDO_HTTP_BODY="" ORDO_HTTP_CURL_RC=0

ordo_provider_http_base_url() {
  # <api-suffix> e.g. "/api/v1": appended unless ORDO_FORGE_URL already ends with it.
  local suffix="${1:?}" url="${ORDO_FORGE_URL:-}"
  url="${url%/}"
  if [[ -z "$url" ]]; then
    ordo_provider_adapter_error bad_argument "ORDO_FORGE_URL must be set to the forge base URL (e.g. https://forge.example) for the $(ordo_provider_adapter_name) adapter" false \
      "$(jq -cn --arg a "$(ordo_provider_adapter_name)" '{"missing": "ORDO_FORGE_URL", "adapter": $a}')"
    return $?
  fi
  if [[ "$url" != http://* && "$url" != https://* ]]; then
    ordo_provider_adapter_error bad_argument "ORDO_FORGE_URL must start with http:// or https://" false \
      "$(jq -cn '{"invalid": "ORDO_FORGE_URL"}')"
    return $?
  fi
  [[ "$url" == *"$suffix" ]] || url="$url$suffix"
  printf '%s\n' "$url"
}

# Host part of ORDO_FORGE_URL (for auth_status.host).
ordo_provider_http_host() {
  local host="${ORDO_FORGE_URL:-}"
  host="${host#*://}"
  host="${host%%/*}"
  printf '%s\n' "$host"
}

# Web root of the forge (ORDO_FORGE_URL without a trailing /api/vN), used to
# rebuild html URLs the API does not return.
ordo_provider_http_web_root() {
  local url="${ORDO_FORGE_URL:-}"
  url="${url%/}"
  url="${url%/api/v[0-9]*}"
  printf '%s\n' "$url"
}

# Bodies travel by file and must reach the forge verbatim: backends read them
# with `jq --rawfile` (a $(cat ...) substitution would strip trailing
# newlines). ordo_provider_http_body_path prints ORDO_PV_BODY_PATH, or
# /dev/null when no body was given, so --rawfile always has a file.
ordo_provider_http_body_path() {
  if [[ -n "${ORDO_PV_BODY_PATH:-}" ]]; then printf '%s\n' "$ORDO_PV_BODY_PATH"; else printf '/dev/null\n'; fi
}

ordo_provider_http_urlencode() {
  printf '%s' "${1-}" | jq -sRr '@uri'
}

# ordo_provider_http_query k=v [k=v ...] -> "?k=v&..." (values URL-encoded); "" when no args.
ordo_provider_http_query() {
  local out="" kv
  for kv in "$@"; do
    [[ -n "$kv" ]] || continue
    local k="${kv%%=*}" v="${kv#*=}"
    [[ -n "$v" ]] || continue
    out="${out:+$out&}$k=$(ordo_provider_http_urlencode "$v")"
  done
  [[ -z "$out" ]] || printf '?%s' "$out"
  printf '\n'
}

# ---------------------------------------------------------------------------
# Token
# ---------------------------------------------------------------------------
_ordo_provider_http_file_mode() {
  local f="$1" mode
  mode=$(stat -c '%a' "$f" 2>/dev/null) || mode=$(stat -f '%Lp' "$f" 2>/dev/null) || mode=""
  printf '%s\n' "$mode"
}

# _ordo_provider_http_token_file <knob-name> <file>: prints the token held by
# <file>. Refuses (exit 3) a file readable by group/other.
_ordo_provider_http_token_file() {
  local knob="$1" file="$2"
  if [[ ! -r "$file" ]]; then
    ordo_provider_adapter_error not_found "${knob} is not readable: ${file}" false \
      "$(jq -cn --arg f "$file" '{"token_file": $f, "fix": "create the file with the token on one line and chmod 600 it"}')"
    return $?
  fi
  local mode
  mode=$(_ordo_provider_http_file_mode "$file")
  if [[ -n "$mode" ]] && (( 8#$mode & 8#077 )); then
    ordo_provider_adapter_error refused "${knob} is readable by group/other (mode ${mode}); refusing to use it" false \
      "$(jq -cn --arg f "$file" --arg m "$mode" '{"token_file": $f, "mode": $m, "reason": "token_file_permissive", "fix": ("chmod 600 " + $f)}')"
    return $?
  fi
  local tok
  tok=$(tr -d '\r\n' < "$file" 2>/dev/null) || {
    ordo_provider_adapter_error not_found "${knob} could not be read: ${file}" false \
      "$(jq -cn --arg f "$file" '{"token_file": $f}')"
    return $?
  }
  if [[ -z "$tok" ]]; then
    ordo_provider_adapter_error bad_argument "${knob} is empty: ${file}" false \
      "$(jq -cn --arg f "$file" '{"token_file": $f}')"
    return $?
  fi
  printf '%s\n' "$tok"
}

# Prints the token. Refuses (exit 3) a token file readable by group/other.
# With the argument "privileged", ORDO_FORGE_ADMIN_TOKEN_FILE /
# ORDO_FORGE_ADMIN_TOKEN are consulted first (admin merge, review approval);
# when neither is set the ordinary token is used.
ordo_provider_http_token() {
  local privileged="${1:-}"
  if [[ "$privileged" == privileged ]]; then
    if [[ -n "${ORDO_FORGE_ADMIN_TOKEN_FILE:-}" ]]; then
      _ordo_provider_http_token_file ORDO_FORGE_ADMIN_TOKEN_FILE "$ORDO_FORGE_ADMIN_TOKEN_FILE"
      return $?
    fi
    if [[ -n "${ORDO_FORGE_ADMIN_TOKEN:-}" ]]; then
      printf '%s\n' "$ORDO_FORGE_ADMIN_TOKEN"
      return 0
    fi
  fi
  local file="${ORDO_FORGE_TOKEN_FILE:-}"
  if [[ -n "$file" ]]; then
    _ordo_provider_http_token_file ORDO_FORGE_TOKEN_FILE "$file"
    return $?
  fi
  if [[ -n "${ORDO_FORGE_TOKEN:-}" ]]; then
    printf '%s\n' "$ORDO_FORGE_TOKEN"
    return 0
  fi
  ordo_provider_adapter_error bad_argument "no forge token: set ORDO_FORGE_TOKEN_FILE (a 0600 file holding the token) or ORDO_FORGE_TOKEN" false \
    "$(jq -cn '{"missing": "ORDO_FORGE_TOKEN_FILE", "fallback": "ORDO_FORGE_TOKEN"}')"
}

# 0 when a privileged credential is configured (so callers can tell whether
# an admin path has its own token or falls back to the ordinary one).
ordo_provider_http_has_admin_token() {
  [[ -n "${ORDO_FORGE_ADMIN_TOKEN_FILE:-}" || -n "${ORDO_FORGE_ADMIN_TOKEN:-}" ]]
}

# ordo_provider_http_mask <text>: masks the configured token (literal) and
# token-looking values (contracts regex). Used for every message that may
# carry provider text.
ordo_provider_http_mask() {
  local text="${1-}" tok
  tok=$(ordo_provider_http_token 2>/dev/null) || tok=""
  if [[ -n "$tok" ]]; then
    text="${text//"$tok"/${ORDO_CONTRACTS_REDACT_MASK:-[REDACTED]}}"
  fi
  if ordo_provider_http_has_admin_token; then
    tok=$(ordo_provider_http_token privileged 2>/dev/null) || tok=""
    if [[ -n "$tok" ]]; then
      text="${text//"$tok"/${ORDO_CONTRACTS_REDACT_MASK:-[REDACTED]}}"
    fi
  fi
  printf '%s' "$text" | sed -E "s/${ORDO_CONTRACTS_REDACT_VALUE_RE:-gh[pousr]_[A-Za-z0-9]{20,}}/${ORDO_CONTRACTS_REDACT_MASK:-[REDACTED]}/g; s/glpat-[A-Za-z0-9_-]{20,}/${ORDO_CONTRACTS_REDACT_MASK:-[REDACTED]}/g"
}

# ---------------------------------------------------------------------------
# Request
# ---------------------------------------------------------------------------
_ordo_provider_http_auth_header() {
  # <auth-style> <token> -> header line
  case "$1" in
    token) printf 'Authorization: token %s' "$2" ;;
    private-token) printf 'PRIVATE-TOKEN: %s' "$2" ;;
    bearer) printf 'Authorization: Bearer %s' "$2" ;;
    none) printf '' ;;
    *) return 1 ;;
  esac
}

_ordo_provider_http_curl_config_escape() {
  local s="${1-}"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '%s' "$s"
}

# Classification of a finished exchange.
# _ordo_provider_http_classify <curl_rc> <status> <mutation:0|1> -> "code retryable category"
_ordo_provider_http_classify() {
  local rc="$1" status="$2" mutation="$3"
  if [[ "$rc" -ne 0 ]]; then
    case "$rc" in
      28)
        if [[ "$mutation" -eq 1 ]]; then printf 'provider_error false timeout\n'; else printf 'provider_error true timeout\n'; fi ;;
      6|7|35|52|55|56|16|18|92)
        if [[ "$mutation" -eq 1 && "$rc" -ne 6 && "$rc" -ne 7 ]]; then printf 'provider_error false transient\n'; else printf 'provider_error true transient\n'; fi ;;
      *) printf 'provider_error false transport\n' ;;
    esac
    return 0
  fi
  case "$status" in
    2[0-9][0-9]) printf 'ok false ok\n' ;;
    401) printf 'provider_error false auth\n' ;;
    403) printf 'policy_refused false permission\n' ;;
    404|410) printf 'not_found false not_found\n' ;;
    405|406|409|422) printf 'conflict false conflict\n' ;;
    429) printf 'rate_limited true rate_limited\n' ;;
    5[0-9][0-9]) printf 'provider_error true transient\n' ;;
    4[0-9][0-9]) printf 'provider_error false client\n' ;;
    *) printf 'provider_error false unknown\n' ;;
  esac
}

# Message extracted from a forge error body (Forgejo {"message"}, GitLab
# {"message": str|object} or {"error"}), masked and truncated.
_ordo_provider_http_error_message() {
  local body="$1" msg
  msg=$(printf '%s' "$body" | jq -r '
    if type == "object" then
      (.message // .error // .errors // "") | if type == "string" then . else tojson end
    else "" end' 2>/dev/null) || msg=""
  if [[ -z "$msg" ]]; then
    msg=$(printf '%s' "$body" | head -c 300 | tr '\n' ' ')
  fi
  ordo_provider_http_mask "$(printf '%s' "$msg" | head -c 400)"
}

ordo_provider_http_header() {
  # <name> -> last value of that response header (case-insensitive), or empty
  local name="$1"
  printf '%s\n' "$ORDO_HTTP_HEADERS" | tr -d '\r' | awk -v n="$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')" '
    BEGIN { FS=": ?" }
    { key = tolower($1); if (key == n) { sub(/^[^:]*: ?/, ""); v = $0 } }
    END { print v }'
}

ordo_provider_http_has_next() {
  local link next
  link=$(ordo_provider_http_header Link)
  [[ "$link" == *'rel="next"'* ]] && return 0
  next=$(ordo_provider_http_header X-Next-Page)
  [[ -n "$next" ]] && return 0
  return 1
}

# Total count if the forge announced one (X-Total-Count / X-Total), else "".
ordo_provider_http_total() {
  local t
  t=$(ordo_provider_http_header X-Total-Count)
  [[ -n "$t" ]] || t=$(ordo_provider_http_header X-Total)
  printf '%s\n' "$t"
}

ordo_provider_http_json() {
  if [[ -z "${ORDO_HTTP_BODY//[[:space:]]/}" ]]; then
    printf 'null\n'
    return 0
  fi
  local out
  if ! out=$(printf '%s' "$ORDO_HTTP_BODY" | jq -c . 2>/dev/null); then
    ordo_provider_adapter_error invalid_json "the forge returned a body that is not JSON" false \
      "$(jq -cn --arg excerpt "$(ordo_provider_http_mask "$(printf '%s' "$ORDO_HTTP_BODY" | head -c 200)")" '{"excerpt": $excerpt}')"
    return $?
  fi
  printf '%s\n' "$out"
}

_ordo_provider_http_log() {
  # <method> <url> <status> <ms>
  [[ -n "${ORDO_PROVIDER_HTTP_LOG:-}" ]] || return 0
  printf '%s %s %s %s %sms\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$1" "$2" "$3" "$4" >> "$ORDO_PROVIDER_HTTP_LOG" 2>/dev/null || true
}

# ordo_provider_http_request <op> <auth-style> <method> <url> [--body-file F] [--body JSON] [--mutation] [--accept TYPE] [--allow-404]
#   Sets ORDO_HTTP_STATUS / ORDO_HTTP_HEADERS / ORDO_HTTP_BODY / ORDO_HTTP_CURL_RC.
#   Returns 0 on 2xx (and on 404 with --allow-404), else emits the typed error
#   and returns its exit code.
ordo_provider_http_request() {
  local op="${1:?}" auth="${2:?}" method="${3:?}" url="${4:?}"
  shift 4
  local body_file="" body_inline="" body_set=0 mutation=0 accept="application/json" allow_404=0 privileged=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --body-file) body_file="$2"; body_set=1; shift 2 ;;
      --body) body_inline="$2"; body_set=1; shift 2 ;;
      --mutation) mutation=1; shift ;;
      --accept) accept="$2"; shift 2 ;;
      --allow-404) allow_404=1; shift ;;
      --privileged) privileged=privileged; shift ;;
      *) shift ;;
    esac
  done
  case "$method" in GET|HEAD) ;; *) [[ "$mutation" -eq 1 ]] || mutation=1 ;; esac
  if [[ "$url" == *"access_token="* || "$url" == *"private_token="* ]]; then
    ordo_provider_adapter_error bad_argument "refusing a URL that carries credentials" false '{"reason":"token_in_url"}'
    return $?
  fi
  if ! command -v "$ORDO_PROVIDER_HTTP_CURL" >/dev/null 2>&1; then
    ordo_provider_adapter_error missing_dependency "curl is not on PATH (ORDO_PROVIDER_HTTP_CURL=${ORDO_PROVIDER_HTTP_CURL})" false '{"dependency":"curl"}'
    return $?
  fi
  local tok=""
  if [[ "$auth" != none ]]; then
    tok=$(ordo_provider_http_token "$privileged") || return $?
  fi
  local header_line
  header_line=$(_ordo_provider_http_auth_header "$auth" "$tok") || {
    ordo_provider_adapter_error internal_error "unknown auth style '${auth}'" false
    return $?
  }
  local tmp_in=""
  if [[ "$body_set" -eq 1 && -z "$body_file" ]]; then
    tmp_in=$(mktemp "${TMPDIR:-/tmp}/ordo_http_in.XXXXXX") || return 1
    printf '%s' "$body_inline" > "$tmp_in"
    body_file="$tmp_in"
  fi
  local timeout="$ORDO_PROVIDER_TIMEOUT_SEC"
  [[ "$mutation" -eq 1 ]] && timeout="$ORDO_PROVIDER_MUTATION_TIMEOUT_SEC"
  local retries="${ORDO_PROVIDER_HTTP_RETRIES:-0}"
  [[ "$mutation" -eq 1 ]] && retries=0
  local attempt=0 rc status hdr_file body_out start end
  hdr_file=$(mktemp "${TMPDIR:-/tmp}/ordo_http_hdr.XXXXXX") || { [[ -z "$tmp_in" ]] || rm -f "$tmp_in"; return 1; }
  body_out=$(mktemp "${TMPDIR:-/tmp}/ordo_http_body.XXXXXX") || { rm -f "$hdr_file"; [[ -z "$tmp_in" ]] || rm -f "$tmp_in"; return 1; }
  local -a curl_args=(
    --silent --show-error --globoff --no-buffer
    --max-time "$timeout" --connect-timeout "$timeout"
    --request "$method" --url "$url"
    --header "Accept: ${accept}"
    --header "User-Agent: ordo-provider-adapter/$(ordo_provider_adapter_name)"
    --output "$body_out" --dump-header "$hdr_file" --write-out '%{http_code}'
    --config -
  )
  if [[ -n "$body_file" ]]; then
    curl_args+=(--header "Content-Type: application/json" --data-binary "@${body_file}")
  fi
  local config="" errf
  [[ -z "$header_line" ]] || config="header = \"$(_ordo_provider_http_curl_config_escape "$header_line")\""
  errf=$(mktemp "${TMPDIR:-/tmp}/ordo_http_err.XXXXXX") || errf=/dev/null
  while :; do
    attempt=$((attempt + 1))
    rc=0
    : > "$hdr_file"; : > "$body_out"
    start=$(date +%s%N 2>/dev/null || date +%s)
    # The token reaches curl only through this stdin config document.
    status=$(printf '%s\n' "$config" | "$ORDO_PROVIDER_HTTP_CURL" "${curl_args[@]}" 2> "$errf") || rc=$?
    end=$(date +%s%N 2>/dev/null || date +%s)
    [[ "$status" =~ ^[0-9]{3}$ ]] || status="000"
    _ordo_provider_http_log "$method" "$url" "$status" "$(( (end - start) / 1000000 ))"
    local cls code retryable category
    cls=$(_ordo_provider_http_classify "$rc" "$status" "$mutation")
    read -r code retryable category <<< "$cls"
    if [[ "$code" == ok ]] || [[ "$attempt" -gt "$retries" ]] || [[ "$retryable" != true ]]; then
      break
    fi
    local sleep_s
    sleep_s=$(tr -d '\r' < "$hdr_file" | awk 'BEGIN{IGNORECASE=1} tolower($1)=="retry-after:" {print $2}' | tail -n 1)
    [[ "$sleep_s" =~ ^[0-9]+$ ]] || sleep_s=1
    (( sleep_s > ORDO_PROVIDER_HTTP_RETRY_MAX_SLEEP )) && sleep_s="$ORDO_PROVIDER_HTTP_RETRY_MAX_SLEEP"
    sleep "$sleep_s"
  done
  ORDO_HTTP_STATUS="$status"
  ORDO_HTTP_HEADERS=$(cat "$hdr_file")
  ORDO_HTTP_BODY=$(cat "$body_out")
  # shellcheck disable=SC2034 # read by backends that inspect transport failures
  ORDO_HTTP_CURL_RC="$rc"
  local curl_err
  curl_err=$(ordo_provider_http_mask "$(head -c 300 "$errf" 2>/dev/null | tr '\n' ' ')")
  rm -f "$hdr_file" "$body_out" "$errf"
  [[ -z "$tmp_in" ]] || rm -f "$tmp_in"
  if [[ "$code" == ok ]]; then
    return 0
  fi
  if [[ "$allow_404" -eq 1 && "$status" == 404 ]]; then
    return 0
  fi
  local path="${url#*://}"
  path="/${path#*/}"
  path="${path%%\?*}"
  local msg retry_after
  if [[ "$rc" -ne 0 ]]; then
    msg="curl exit ${rc}${curl_err:+: $curl_err}"
  else
    msg=$(_ordo_provider_http_error_message "$ORDO_HTTP_BODY")
  fi
  retry_after=$(ordo_provider_http_header Retry-After)
  local human
  case "$category" in
    timeout) human="timed out after ${timeout}s" ;;
    rate_limited) human="rate limited (HTTP 429${retry_after:+, retry after ${retry_after}s})" ;;
    *) human="HTTP ${status}" ;;
  esac
  [[ "$rc" -eq 0 ]] || human="transport failure"
  local hint=""
  [[ "$mutation" -eq 1 && "$category" == timeout ]] && hint="; the mutation may or may not have been applied — read the forge state before retrying"
  ordo_provider_adapter_error "$code" "$(ordo_provider_adapter_name) ${op} failed (${category}): ${human}${msg:+: $msg}${hint}" "$retryable" \
    "$(jq -cn --arg op "$op" --arg method "$method" --arg path "$path" --arg category "$category" --arg msg "$msg" \
        --argjson status "${status#0}" --argjson rc "$rc" --arg ra "$retry_after" --argjson attempts "$attempt" --argjson mutation "$([[ "$mutation" -eq 1 ]] && echo true || echo false)" \
        '{"op": $op, "backend": "rest", "method": $method, "path": $path, "http_status": (if $status == "" then 0 else $status end),
          "curl_exit": $rc, "category": $category, "message": $msg, "attempts": $attempts, "mutation": $mutation}
         + (if $ra != "" then {"retry_after": $ra} else {} end)')"
}

# ordo_provider_http_get_all <op> <auth-style> <url-with-optional-query> <page-param> <size-param> [jq-items-expr]
#   Follows pagination (Link/X-Next-Page or "fewer than a page" fallback) up to
#   ORDO_PROVIDER_HTTP_MAX_PAGES pages and prints ONE JSON array of items.
#   jq-items-expr (default ".") extracts the array from each page body.
ordo_provider_http_get_all() {
  local op="$1" auth="$2" url="$3" page_param="$4" size_param="$5" items_expr="${6:-.}"
  local sep="?" page=1 all='[]' size="${ORDO_PROVIDER_HTTP_PAGE_SIZE:-50}"
  [[ "$url" == *\?* ]] && sep="&"
  while :; do
    ordo_provider_http_request "$op" "$auth" GET "${url}${sep}${page_param}=${page}&${size_param}=${size}" || return $?
    local body items n
    body=$(ordo_provider_http_json) || return $?
    items=$(printf '%s' "$body" | jq -c "${items_expr} // [] | if type == \"array\" then . else [] end") || items='[]'
    all=$(jq -cn --argjson a "$all" --argjson b "$items" '$a + $b')
    n=$(printf '%s' "$items" | jq 'length')
    if ordo_provider_http_has_next; then
      :
    elif [[ -n "$(ordo_provider_http_header Link)" || -n "$(ordo_provider_http_header X-Total-Count)" || -n "$(ordo_provider_http_header X-Total)" ]]; then
      break
    elif [[ "$n" -lt "$size" ]]; then
      break
    fi
    page=$((page + 1))
    [[ "$page" -le "${ORDO_PROVIDER_HTTP_MAX_PAGES:-20}" ]] || break
  done
  printf '%s\n' "$all"
}

# ordo_provider_http_tail_lines <text> [n]: last n lines (default
# ORDO_PROVIDER_ANNOTATION_TAIL_LINES, 20), masked.
ordo_provider_http_tail_lines() {
  local n="${2:-${ORDO_PROVIDER_ANNOTATION_TAIL_LINES:-20}}"
  ordo_provider_http_mask "$(printf '%s\n' "${1-}" | sed '/^[[:space:]]*$/d' | tail -n "$n")"
}

# Local slice of an already-fetched array into the list shape
# {"items","count","page","limit","has_more"} (exact has_more).
ordo_provider_http_paginate_local() {
  # <json-array> <page> <limit>
  printf '%s' "$1" | jq -c --argjson page "$2" --argjson limit "$3" \
    '{"items": .[(($page - 1) * $limit):($page * $limit)], "page": $page, "limit": $limit, "has_more": (length > ($page * $limit))} | .count = (.items | length)'
}

# Server-side page into the list shape: <items-json> <page> <limit> [has_more:true|false] [total]
ordo_provider_http_page_shape() {
  local items="$1" page="$2" limit="$3" has_more="${4:-false}"
  printf '%s' "$items" | jq -c --argjson page "$page" --argjson limit "$limit" --argjson more "$has_more" \
    '{"items": ., "page": $page, "limit": $limit, "has_more": $more} | .count = (.items | length)'
}

# Scope implied by a native REST mutation (method + path) so `mutate` can be
# refused when the declared --scope does not match what the path does —
# the REST counterpart of the gh-argument re-classification of the github
# backend. Prints the scope or "" when the path is not classifiable.
ordo_provider_http_classify_native() {
  local method="$1" path="$2"
  path="${path%%\?*}"
  case "$method" in
    GET|HEAD) printf 'read\n'; return 0 ;;
  esac
  case "$path" in
    */pulls/*/merge|*/merge_requests/*/merge|*/merge_requests/*/rebase) printf 'pr_merge\n' ;;
    */pulls/*/reviews*|*/merge_requests/*/approve|*/merge_requests/*/unapprove|*/merge_requests/*/approvals*|*/pulls/*/requested_reviewers*|*/merge_requests/*/reviewers*) printf 'pr_review\n' ;;
    */pulls/*/labels*|*/issues/*/labels*) printf 'issue_labels\n' ;;
    */issues/*/comments*|*/issues/*/notes*|*/merge_requests/*/notes*|*/issues/*/discussions*|*/merge_requests/*/discussions*) printf 'issue_comment\n' ;;
    */pulls/*/update*|*/merge_requests/*/cancel_merge_when_pipeline_succeeds) printf 'pr_merge\n' ;;
    */pulls/[0-9]*|*/merge_requests/[0-9]*) printf 'pr_edit\n' ;;
    */issues/[0-9]*) printf 'issue_edit\n' ;;
    */pulls|*/merge_requests) printf 'pr_state\n' ;;
    */issues) printf 'issue_create\n' ;;
    *) printf '\n' ;;
  esac
}

# Scopes that are compatible with an implied scope (a declared scope in the
# list satisfies the implied one).
ordo_provider_http_scope_compatible() {
  # <declared> <implied>
  local declared="$1" implied="$2"
  [[ -z "$implied" || "$declared" == "$implied" ]] && return 0
  case "$implied" in
    pr_edit) [[ "$declared" =~ ^(pr_edit|pr_labels|pr_assignees|pr_close|pr_reopen|pr_ready|pr_state)$ ]] && return 0 ;;
    issue_edit) [[ "$declared" =~ ^(issue_edit|issue_labels|issue_assignees|issue_close|issue_reopen)$ ]] && return 0 ;;
    issue_labels) [[ "$declared" =~ ^(issue_labels|pr_labels)$ ]] && return 0 ;;
    issue_comment) [[ "$declared" =~ ^(issue_comment|pr_comment|issue_pack_notify)$ ]] && return 0 ;;
  esac
  return 1
}

# ---------------------------------------------------------------------------
# Native REST passthrough shared by the REST backends:
#   ordo_provider mutate --scope S -k K -- --method M --path P [--body JSON | --body-file F]
# ordo_provider_http_native_mutate <adapter> <api-suffix> <auth-style>
#   P is relative to the API base (repos/...) or absolute (/api/vN/...). The
#   method+path are classified and must be compatible with the declared
#   scope (the REST counterpart of the gh-argument double gate).
ordo_provider_http_native_mutate() {
  local adapter="$1" api_suffix="$2" auth="$3"
  local method="" path="" body="" body_file="" body_set=0
  local -a rest=("${ORDO_PV_NATIVE[@]}")
  local i=0
  while [[ $i -lt ${#rest[@]} ]]; do
    case "${rest[$i]}" in
      --method|-X) method="${rest[$((i+1))]:-}"; i=$((i+2)) ;;
      --path) path="${rest[$((i+1))]:-}"; i=$((i+2)) ;;
      --body) body="${rest[$((i+1))]:-}"; body_set=1; i=$((i+2)) ;;
      --body-file) body_file="${rest[$((i+1))]:-}"; body_set=1; i=$((i+2)) ;;
      *)
        ordo_provider_adapter_error bad_argument "mutate (${adapter}): unknown native argument '${rest[$i]}' (expected --method M --path P [--body JSON|--body-file F])" false \
          "$(jq -cn --arg a "${rest[$i]}" '{"argument": $a}')"
        return $?
        ;;
    esac
  done
  method=$(printf '%s' "$method" | tr '[:lower:]' '[:upper:]')
  case "$method" in
    POST|PUT|PATCH|DELETE) ;;
    *)
      ordo_provider_adapter_error bad_argument "mutate (${adapter}): --method must be POST, PUT, PATCH or DELETE (got '${method:-none}')" false \
        "$(jq -cn --arg m "$method" '{"method": $m}')"
      return $?
      ;;
  esac
  if [[ -z "$path" ]]; then
    ordo_provider_adapter_error bad_argument "mutate (${adapter}): --path is required" false '{"missing":"path"}'
    return $?
  fi
  if [[ "$path" == *"access_token="* || "$path" == *"private_token="* ]]; then
    ordo_provider_adapter_error bad_argument "mutate (${adapter}): credentials in --path are refused" false '{"reason":"token_in_url"}'
    return $?
  fi
  local implied
  implied=$(ordo_provider_http_classify_native "$method" "$path")
  if ! ordo_provider_http_scope_compatible "${ORDO_PV_SCOPE_RESOLVED:-$ORDO_PV_SCOPE}" "$implied"; then
    ordo_provider_adapter_error policy_refused "mutate (${adapter}): ${method} ${path} implies scope '${implied}', which the declared scope '${ORDO_PV_SCOPE}' does not cover" false \
      "$(jq -cn --arg declared "$ORDO_PV_SCOPE" --arg implied "$implied" --arg m "$method" --arg p "$path" \
          '{"declared_scope": $declared, "implied_scope": $implied, "method": $m, "path": $p, "authorize_via": "ORCH_EXTERNAL_PR_MUTATIONS"}')"
    return $?
  fi
  local base url
  base=$(ordo_provider_http_base_url "$api_suffix") || return $?
  if [[ "$path" == /api/* ]]; then
    url="$(ordo_provider_http_web_root)${path}"
  else
    url="${base}/${path#/}"
  fi
  local -a opts=(--mutation)
  if [[ -n "$body_file" ]]; then
    if [[ ! -r "$body_file" ]]; then
      ordo_provider_adapter_error not_found "mutate (${adapter}): body file not readable: ${body_file}" false "$(jq -cn --arg f "$body_file" '{"body_file": $f}')"
      return $?
    fi
    opts+=(--body-file "$body_file")
  elif [[ "$body_set" -eq 1 ]]; then
    opts+=(--body "$body")
  fi
  ordo_provider_http_request mutate "$auth" "$method" "$url" "${opts[@]}" || return $?
  local parsed
  parsed=$(ordo_provider_http_json 2>/dev/null) || parsed=$(jq -cn --arg raw "$(ordo_provider_http_mask "$ORDO_HTTP_BODY")" '$raw')
  jq -cn --arg m "$method" --arg p "$path" --argjson status "${ORDO_HTTP_STATUS#0}" --argjson body "$parsed" \
    --argjson args "$(printf '%s\n' "${ORDO_PV_NATIVE[@]}" | jq -R . | jq -sc .)" --arg stdout "$(ordo_provider_http_mask "$(printf '%s' "$ORDO_HTTP_BODY" | head -c 4000)")" \
    '{"backend": "rest", "args": $args, "stdout": $stdout, "method": $m, "path": $p, "status": $status, "body": $body}'
}
