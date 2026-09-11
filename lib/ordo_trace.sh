#!/usr/bin/env bash
# lib/ordo_trace.sh — OpenTelemetry-compatible trace spans for the agentic
# control plane (#812, epic #806).
#
# Spans are appended as JSON lines under <state_dir>/traces/<trace_id>.jsonl
# (override: ORDO_TRACE_DIR). The file is append-only: a span produces one
# `start` line, zero or more `event` lines and one `end` line, every line
# carrying the same field set (trace_id, span_id, parent_span_id, name, kind,
# start_time_unix_nano, end_time_unix_nano, status{code,message},
# attributes{...}, resource{service.name, ordo.project, ordo.run_id}).
# `ordo_trace_span` / `ordo_trace_export` fold those lines into complete spans,
# and `--format otlp-json` produces an OTLP/JSON ResourceSpans document that
# any OTLP HTTP collector accepts (docs/otel-export.md).
#
# Redaction guarantee: EVERY attribute value, span name, event name, status
# message and wrapped command line goes through ordo_contracts_redact (secret
# key names -> "[REDACTED]", token-looking values masked) PLUS the literal
# values of every environment variable whose name looks like a secret PLUS the
# optional extra regex ORDO_TRACE_REDACT_RE. Nothing is written before that.
#
# Public API:
#   ordo_trace_start <name> [--kind agent|model|tool|policy|approval|retry|provider|internal]
#                    [--parent SPAN_ID] [--trace TRACE_ID] [--attr k=v ...]   # prints span_id
#   ordo_trace_end <span_id> [--status ok|error|unset] [--message M] [--attr k=v ...]
#   ordo_trace_event <span_id> <name> [--attr k=v ...]
#   ordo_trace_wrap <name> [--kind K] [--parent ID] [--trace ID] [--attr k=v ...] -- <command...>
#                                     # runs the command inside a span; exit code passes through
#   ordo_trace_span <span_id>                          # folded span JSON
#   ordo_trace_spans <trace_id>                        # folded spans, JSON lines
#   ordo_trace_export <trace_id> [--format otlp-json|jsonl]
#   ordo_trace_id                                      # current trace id (ORDO_TRACE_ID, or derived from ORDO_RUN_ID)
#   ordo_trace_new_id trace|span [seed]                # random (or seed-derived) id
#   ordo_trace_dir                                     # where the files live
#   ordo_trace_redact <json>                           # the full redaction pipeline
#
# Context propagation: ORDO_TRACE_ID (current trace) and ORDO_TRACE_PARENT_SPAN
# (default parent) are read by start/wrap; ordo_trace_wrap exports both to the
# wrapped command so nested spans link without any hard dependency on this
# library. ORDO_TRACE_ENABLED=0 turns every call into a no-op (ids are still
# printed so callers never branch).
#
# Errors: ONE JSON line on stderr {"error":{"code","message","module":"trace","details"}}
# and the contract exit code (2 usage, 4 not_found). Clock: ORDO_TRACE_NOW_NS,
# else ORDO_JOURNAL_NOW (tests), else date +%s%N.
#
# Dependencies: bash >= 4, jq, coreutils (date, od, sha256sum, flock).

if [[ -n "${ORDO_TRACE_LIB_LOADED:-}" ]]; then
  return 0
fi
ORDO_TRACE_LIB_LOADED=1

_ORDO_TRACE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! declare -F ordo_contracts_redact >/dev/null 2>&1; then
  # shellcheck source=lib/ordo_contracts.sh
  source "$_ORDO_TRACE_LIB_DIR/ordo_contracts.sh"
fi

ORDO_TRACE_MODULE="trace"
ORDO_TRACE_KINDS="agent model tool policy approval retry provider internal"
: "${ORDO_TRACE_ENABLED:=1}"
: "${ORDO_TRACE_SERVICE_NAME:=${ORCH_OTEL_SERVICE_NAME:-ordo}}"
: "${ORDO_TRACE_SCOPE_NAME:=ordo.trace}"
: "${ORDO_TRACE_REDACT_RE:=}"
: "${ORDO_TRACE_NOW_NS:=}"

_ordo_trace_fail() {
  ordo_contracts_error "$ORDO_TRACE_MODULE" "$@"
}

ordo_trace_dir() {
  local dir
  if [[ -n "${ORDO_TRACE_DIR:-}" ]]; then
    dir="$ORDO_TRACE_DIR"
  elif declare -F state_dir >/dev/null 2>&1; then
    dir="$(state_dir)/traces"
  else
    dir="${ORCH_STATE_BASE:-${XDG_DATA_HOME:-$HOME/.local/share}/orch-state}/${PROJECT:-default}/traces"
  fi
  [[ -d "$dir" ]] || mkdir -p "$dir" 2>/dev/null || true
  printf '%s\n' "$dir"
}

# _ordo_trace_epoch_var <rfc3339-utc> : sets _OT_EPOCH to the epoch seconds of a canonical
# `YYYY-MM-DDTHH:MM:SS[.fff]Z` timestamp in pure bash (days-from-civil), the
# same value GNU `date -u -d` gives; returns 1 for any other format so the
# caller falls back to date. No process spawned (#817).
_ordo_trace_epoch_var() {
  local ts="$1"
  [[ "$ts" =~ ^([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2})(\.[0-9]+)?Z$ ]] || return 1
  local y=$((10#${BASH_REMATCH[1]})) m=$((10#${BASH_REMATCH[2]})) d=$((10#${BASH_REMATCH[3]}))
  local hh=$((10#${BASH_REMATCH[4]})) mm=$((10#${BASH_REMATCH[5]})) ss=$((10#${BASH_REMATCH[6]}))
  (( m >= 1 && m <= 12 && d >= 1 && d <= 31 && hh < 24 && mm < 60 && ss < 62 )) || return 1
  local yy=$(( m <= 2 ? y - 1 : y )) era yoe doy doe
  era=$(( (yy >= 0 ? yy : yy - 399) / 400 ))
  yoe=$(( yy - era * 400 ))
  doy=$(( (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1 ))
  doe=$(( yoe * 365 + yoe / 4 - yoe / 100 + doy ))
  _OT_EPOCH=$(( (era * 146097 + doe - 719468) * 86400 + hh * 3600 + mm * 60 + ss ))
}

ordo_trace_now_ns() {
  if [[ -n "${ORDO_TRACE_NOW_NS:-}" ]]; then
    printf '%s\n' "$ORDO_TRACE_NOW_NS"
  elif [[ -n "${ORDO_JOURNAL_NOW:-}" ]]; then
    local s
    if _ordo_trace_epoch_var "$ORDO_JOURNAL_NOW"; then
      s="$_OT_EPOCH"
    else
      s=$(date -u -d "$ORDO_JOURNAL_NOW" +%s 2>/dev/null) || s=$(date -u +%s)
    fi
    printf '%s000000000\n' "$s"
  else
    date +%s%N
  fi
}

# ordo_trace_new_id trace|span [seed]
#   trace ids are 32 hex chars, span ids 16 (OTLP sizes). With a seed the id is
#   derived from sha256(seed) so one run always maps to the same trace id.
ordo_trace_new_id() {
  local what="${1-}" seed="${2-}" len hex
  case "$what" in
    trace) len=32 ;;
    span) len=16 ;;
    *)
      _ordo_trace_fail usage "usage: ordo_trace_new_id trace|span [seed]"
      return $?
      ;;
  esac
  if [[ -n "$seed" ]]; then
    hex=$(printf '%s' "$seed" | sha256sum | cut -c1-"$len")
  else
    hex=$(od -An -N"$((len / 2))" -tx1 /dev/urandom | tr -d ' \n')
  fi
  printf '%s\n' "$hex"
}

# Current trace id: ORDO_TRACE_ID, else derived from ORDO_RUN_ID, else random.
ordo_trace_id() {
  if [[ -n "${ORDO_TRACE_ID:-}" ]]; then
    printf '%s\n' "$ORDO_TRACE_ID"
  elif [[ -n "${ORDO_RUN_ID:-}" ]]; then
    ordo_trace_new_id trace "$ORDO_RUN_ID"
  else
    ordo_trace_new_id trace
  fi
}

_ordo_trace_is_kind() {
  local kind="${1-}"
  [[ -n "$kind" && "$kind" != *[[:space:]]* && " $ORDO_TRACE_KINDS " == *" $kind "* ]]
}

_ordo_trace_index_file() {
  printf '%s/spans.index\n' "$(ordo_trace_dir)"
}

_ordo_trace_lookup_trace() {
  # <span_id> -> trace id from the index (4 when unknown)
  local span_id="$1" idx
  idx=$(_ordo_trace_index_file)
  [[ -f "$idx" ]] || return 4
  local found
  found=$(awk -v s="$span_id" '$1 == s { print $2; exit }' "$idx")
  [[ -n "$found" ]] || return 4
  printf '%s\n' "$found"
}

# Literal secret values taken from the environment (names matching the
# contracts secret-key regex, values of 8+ chars). Fills the array
# _OT_SECRETS (no process spawned: bash ERE with nocasematch, #817).
_OT_SECRETS=()
_ordo_trace_env_secret_values() {
  local names name value restore
  _OT_SECRETS=()
  # All exported names on one line; only the secret-looking ones are visited
  # (one regex match per hit instead of one test per variable).
  names=" $(compgen -e | tr '\n' ' ') "
  restore=$(shopt -p nocasematch)
  shopt -s nocasematch
  while [[ "$names" =~ \ ([^\ ]*(${ORDO_CONTRACTS_REDACT_KEY_RE})[^\ ]*)\  ]]; do
    name="${BASH_REMATCH[1]}"
    names="${names/ ${name} / }"
    value="${!name-}"
    [[ ${#value} -ge 8 ]] && _OT_SECRETS+=("$value")
  done
  $restore
  return 0
}

# Same list as a JSON array (kept for callers of the old helper).
_ordo_trace_env_secrets() {
  _ordo_trace_env_secret_values
  if [[ ${#_OT_SECRETS[@]} -eq 0 ]]; then
    printf '[]\n'
  else
    jq -cn '$ARGS.positional' --args "${_OT_SECRETS[@]}"
  fi
}

# jq definitions shared by every trace writer: the contracts redaction
# (secret-looking keys -> mask, token-looking values masked), then the
# literal env secrets (the first $nsec positional args) and the optional
# extra regex, exactly as ordo_contracts_redact followed by the trace scrub.
# shellcheck disable=SC2016 # jq program
ORDO_TRACE_JQ_DEFS='
  def contracts_redact:
    walk(if type == "object" then with_entries(if (.key | test($key_re; "i")) then .value = $mask else . end)
         elif type == "string" then gsub($value_re; $mask) else . end);
  def scrub: reduce ($ARGS.positional[:$nsec][]) as $s (.; if ($s | length) > 0 then split($s) | join($mask) else . end)
             | if $extra == "" then . else gsub($extra; $mask) end;
  def trace_redact: contracts_redact | walk(if type == "string" then scrub else . end);
  def typed: if test("^-?[0-9]+$") then tonumber
             elif test("^-?[0-9]+\\.[0-9]+$") then tonumber
             elif . == "true" then true elif . == "false" then false else . end;
  def attrs_from($pairs):
    reduce $pairs[] as $pair ({};
      ($pair | index("=")) as $i
      | if $i == null or $i == 0 then . else .[$pair[:$i]] = ($pair[$i + 1:] | typed) end);
'

# _ordo_trace_jq <jq-args...> -- runs jq -cn with the redaction context bound:
# $key_re $value_re $mask $extra $nsec, the env secrets being the first $nsec
# positional args. Callers run _ordo_trace_env_secret_values BEFORE building
# their argument list (the list embeds _OT_SECRETS, so it must be current).
_ordo_trace_jq() {
  jq -cn --arg key_re "$ORDO_CONTRACTS_REDACT_KEY_RE" --arg value_re "$ORDO_CONTRACTS_REDACT_VALUE_RE" \
    --arg mask "$ORDO_CONTRACTS_REDACT_MASK" --arg extra "$ORDO_TRACE_REDACT_RE" --argjson nsec "${#_OT_SECRETS[@]}" \
    "$@"
}

# ordo_trace_redact <json>
#   contracts redaction + literal env secrets + ORDO_TRACE_REDACT_RE (one jq).
ordo_trace_redact() {
  local json="${1-}"
  if [[ $# -lt 1 ]]; then
    ordo_contracts_redact
    return $?
  fi
  local raw
  if ! raw=$(_ordo_contracts_read_json_arg "$json"); then
    ordo_contracts_redact "$json"      # emits the contracts not_found error
    return $?
  fi
  _ordo_trace_env_secret_values
  local out
  if ! out=$(printf '%s' "$raw" | jq -c --arg key_re "$ORDO_CONTRACTS_REDACT_KEY_RE" --arg value_re "$ORDO_CONTRACTS_REDACT_VALUE_RE" \
      --arg mask "$ORDO_CONTRACTS_REDACT_MASK" --arg extra "$ORDO_TRACE_REDACT_RE" --argjson nsec "${#_OT_SECRETS[@]}" \
      "${ORDO_TRACE_JQ_DEFS} trace_redact" --args "${_OT_SECRETS[@]+"${_OT_SECRETS[@]}"}" 2>/dev/null); then
    ordo_contracts_redact "$json"      # emits the contracts invalid_json error
    return $?
  fi
  printf '%s\n' "$out"
}

# _ordo_trace_attrs <k=v ...> -> redacted JSON object (numbers/booleans typed)
_ordo_trace_attrs() {
  _ordo_trace_env_secret_values
  _ordo_trace_jq --argjson npairs "$#" "${ORDO_TRACE_JQ_DEFS} attrs_from(\$ARGS.positional[\$nsec:]) | trace_redact" \
    --args "${_OT_SECRETS[@]+"${_OT_SECRETS[@]}"}" "$@"
}

_ordo_trace_resource() {
  jq -cn --arg svc "$ORDO_TRACE_SERVICE_NAME" --arg project "${PROJECT:-}" --arg run "${ORDO_RUN_ID:-}" \
    '{"service.name": $svc} + (if $project == "" then {} else {"ordo.project": $project} end)
     + (if $run == "" then {} else {"ordo.run_id": $run} end)'
}

_ordo_trace_write() {
  # <trace_id> <json-line>
  local file
  file="$(ordo_trace_dir)/$1.jsonl"
  (
    flock 9
    printf '%s\n' "$2" >&9
  ) 9>>"$file"
}

_ordo_trace_parse_opts() {
  # Sets _OT_KIND _OT_PARENT _OT_TRACE _OT_STATUS _OT_MESSAGE _OT_ATTRS (array) _OT_REST (array after --)
  local fn="$1"; shift
  _OT_KIND="" _OT_PARENT="" _OT_TRACE="" _OT_STATUS="" _OT_MESSAGE=""
  _OT_ATTRS=() _OT_REST=() _OT_HAS_REST=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --kind) _OT_KIND="${2-}"; shift 2 ;;
      --parent) _OT_PARENT="${2-}"; shift 2 ;;
      --trace) _OT_TRACE="${2-}"; shift 2 ;;
      --status) _OT_STATUS="${2-}"; shift 2 ;;
      --message) _OT_MESSAGE="${2-}"; shift 2 ;;
      --attr) _OT_ATTRS+=("${2-}"); shift 2 ;;
      --) shift; _OT_REST=("$@"); _OT_HAS_REST=1; break ;;
      *)
        _ordo_trace_fail usage "unknown option for ${fn}: ${1}" "$(jq -cn --arg opt "$1" '{"option": $opt}')"
        return $?
        ;;
    esac
  done
  if [[ -n "$_OT_KIND" ]] && ! _ordo_trace_is_kind "$_OT_KIND"; then
    _ordo_trace_fail bad_argument "unknown span kind '${_OT_KIND}' (known: ${ORDO_TRACE_KINDS})" \
      "$(jq -cn --arg kind "$_OT_KIND" --arg known "$ORDO_TRACE_KINDS" '{"kind": $kind, "known": ($known | split(" "))}')"
    return $?
  fi
  case "$_OT_STATUS" in
    ""|ok|error|unset) ;;
    *)
      _ordo_trace_fail bad_argument "--status must be ok, error or unset" "$(jq -cn --arg s "$_OT_STATUS" '{"status": $s}')"
      return $?
      ;;
  esac
}

_ordo_trace_status_json() {
  local status="${1:-unset}" message="${2-}" code
  case "$status" in
    ok) code=OK ;;
    error) code=ERROR ;;
    *) code=UNSET ;;
  esac
  ordo_trace_redact "$(jq -cn --arg code "$code" --arg m "$message" '{"code": $code, "message": $m}')"
}

# ordo_trace_start <name> [--kind K] [--parent ID] [--trace ID] [--attr k=v ...] -> span_id
ordo_trace_start() {
  local name="${1-}"
  if [[ -z "$name" ]]; then
    _ordo_trace_fail usage "usage: ordo_trace_start <name> [--kind K] [--parent SPAN_ID] [--trace TRACE_ID] [--attr k=v ...]"
    return $?
  fi
  shift
  _ordo_trace_parse_opts ordo_trace_start "$@" || return $?
  local span_id trace_id parent
  span_id=$(ordo_trace_new_id span)
  if [[ "${ORDO_TRACE_ENABLED:-1}" == 0 ]]; then
    printf '%s\n' "$span_id"
    return 0
  fi
  trace_id="${_OT_TRACE:-$(ordo_trace_id)}"
  parent="${_OT_PARENT:-${ORDO_TRACE_PARENT_SPAN:-}}"
  # One jq: typed attributes, name and status redacted together (the same
  # walk each got separately), then the line.
  _ordo_trace_env_secret_values
  local line
  # shellcheck disable=SC2016 # jq program
  line=$(_ordo_trace_jq --arg phase start --arg trace "$trace_id" --arg span "$span_id" --arg parent "$parent" \
    --arg name "$name" --arg kind "${_OT_KIND:-internal}" --arg now "$(ordo_trace_now_ns)" \
    --arg svc "$ORDO_TRACE_SERVICE_NAME" --arg project "${PROJECT:-}" --arg run "${ORDO_RUN_ID:-}" "${ORDO_TRACE_JQ_DEFS}"'
    ({"name": $name, "status": {"code": "UNSET", "message": ""}, "attributes": attrs_from($ARGS.positional[$nsec:])} | trace_redact) as $safe
    | {"phase": $phase, "trace_id": $trace, "span_id": $span,
       "parent_span_id": (if $parent == "" then null else $parent end),
       "name": $safe.name, "kind": $kind, "start_time_unix_nano": ($now | tonumber),
       "end_time_unix_nano": null, "status": $safe.status, "attributes": $safe.attributes,
       "resource": ({"service.name": $svc} + (if $project == "" then {} else {"ordo.project": $project} end)
                    + (if $run == "" then {} else {"ordo.run_id": $run} end))}' \
    --args "${_OT_SECRETS[@]+"${_OT_SECRETS[@]}"}" "${_OT_ATTRS[@]+"${_OT_ATTRS[@]}"}") || return $?
  _ordo_trace_write "$trace_id" "$line"
  printf '%s %s\n' "$span_id" "$trace_id" >> "$(_ordo_trace_index_file)"
  printf '%s\n' "$span_id"
}

# ordo_trace_end <span_id> [--status ok|error|unset] [--message M] [--attr k=v ...] [--trace ID]
ordo_trace_end() {
  local span_id="${1-}"
  if [[ -z "$span_id" ]]; then
    _ordo_trace_fail usage "usage: ordo_trace_end <span_id> [--status ok|error|unset] [--message M] [--attr k=v ...]"
    return $?
  fi
  shift
  _ordo_trace_parse_opts ordo_trace_end "$@" || return $?
  [[ "${ORDO_TRACE_ENABLED:-1}" == 0 ]] && return 0
  local trace_id
  if [[ -n "$_OT_TRACE" ]]; then
    trace_id="$_OT_TRACE"
  elif ! trace_id=$(_ordo_trace_lookup_trace "$span_id"); then
    _ordo_trace_fail not_found "unknown span ${span_id}" "$(jq -cn --arg s "$span_id" '{"span_id": $s}')"
    return $?
  fi
  local code line
  case "${_OT_STATUS:-unset}" in
    ok) code=OK ;;
    error) code=ERROR ;;
    *) code=UNSET ;;
  esac
  _ordo_trace_env_secret_values
  # shellcheck disable=SC2016 # jq program
  line=$(_ordo_trace_jq --arg trace "$trace_id" --arg span "$span_id" --arg now "$(ordo_trace_now_ns)" \
    --arg code "$code" --arg m "$_OT_MESSAGE" "${ORDO_TRACE_JQ_DEFS}"'
    ({"status": {"code": $code, "message": $m}, "attributes": attrs_from($ARGS.positional[$nsec:])} | trace_redact) as $safe
    | {"phase": "end", "trace_id": $trace, "span_id": $span, "parent_span_id": null, "name": null, "kind": null,
       "start_time_unix_nano": null, "end_time_unix_nano": ($now | tonumber), "status": $safe.status,
       "attributes": $safe.attributes, "resource": null}' \
    --args "${_OT_SECRETS[@]+"${_OT_SECRETS[@]}"}" "${_OT_ATTRS[@]+"${_OT_ATTRS[@]}"}") || return $?
  _ordo_trace_write "$trace_id" "$line"
}

# ordo_trace_event <span_id> <name> [--attr k=v ...] [--trace ID]
ordo_trace_event() {
  local span_id="${1-}" name="${2-}"
  if [[ -z "$span_id" || -z "$name" ]]; then
    _ordo_trace_fail usage "usage: ordo_trace_event <span_id> <name> [--attr k=v ...]"
    return $?
  fi
  shift 2
  _ordo_trace_parse_opts ordo_trace_event "$@" || return $?
  [[ "${ORDO_TRACE_ENABLED:-1}" == 0 ]] && return 0
  local trace_id
  if [[ -n "$_OT_TRACE" ]]; then
    trace_id="$_OT_TRACE"
  elif ! trace_id=$(_ordo_trace_lookup_trace "$span_id"); then
    _ordo_trace_fail not_found "unknown span ${span_id}" "$(jq -cn --arg s "$span_id" '{"span_id": $s}')"
    return $?
  fi
  _ordo_trace_env_secret_values
  local line
  # shellcheck disable=SC2016 # jq program
  line=$(_ordo_trace_jq --arg trace "$trace_id" --arg span "$span_id" --arg name "$name" --arg now "$(ordo_trace_now_ns)" \
    "${ORDO_TRACE_JQ_DEFS}"'
    ({"name": $name, "attributes": attrs_from($ARGS.positional[$nsec:])} | trace_redact) as $safe
    | {"phase": "event", "trace_id": $trace, "span_id": $span, "parent_span_id": null, "name": $safe.name, "kind": null,
       "start_time_unix_nano": null, "end_time_unix_nano": null, "time_unix_nano": ($now | tonumber),
       "status": null, "attributes": $safe.attributes, "resource": null}' \
    --args "${_OT_SECRETS[@]+"${_OT_SECRETS[@]}"}" "${_OT_ATTRS[@]+"${_OT_ATTRS[@]}"}") || return $?
  _ordo_trace_write "$trace_id" "$line"
}

# shellcheck disable=SC2016 # jq program
ORDO_TRACE_JQ_FOLD='
  group_by(.span_id) | map(
    (map(select(.phase == "start"))[0] // {}) as $s
    | (map(select(.phase == "end")) | last) as $e
    | select($s.span_id != null)
    | {"trace_id": $s.trace_id, "span_id": $s.span_id, "parent_span_id": $s.parent_span_id,
       "name": $s.name, "kind": $s.kind, "start_time_unix_nano": $s.start_time_unix_nano,
       "end_time_unix_nano": ($e.end_time_unix_nano // null),
       "status": ($e.status // $s.status // {"code": "UNSET", "message": ""}),
       "attributes": (($s.attributes // {}) + ($e.attributes // {})),
       "resource": $s.resource,
       "events": [ .[] | select(.phase == "event") | {"name": .name, "time_unix_nano": .time_unix_nano, "attributes": .attributes} ]})
  | sort_by(.start_time_unix_nano)'

_ordo_trace_fold_file() {
  local file="$1"
  [[ -f "$file" ]] || { printf '[]\n'; return 0; }
  jq -cs "$ORDO_TRACE_JQ_FOLD" "$file"
}

# ordo_trace_spans <trace_id>  -> folded spans, one JSON line each
ordo_trace_spans() {
  local trace_id="${1-}"
  if [[ -z "$trace_id" ]]; then
    _ordo_trace_fail usage "usage: ordo_trace_spans <trace_id>"
    return $?
  fi
  local file
  file="$(ordo_trace_dir)/$trace_id.jsonl"
  if [[ ! -f "$file" ]]; then
    _ordo_trace_fail not_found "unknown trace ${trace_id}" "$(jq -cn --arg t "$trace_id" --arg f "$file" '{"trace_id": $t, "file": $f}')"
    return $?
  fi
  _ordo_trace_fold_file "$file" | jq -c '.[]'
}

# ordo_trace_span <span_id>  -> folded span JSON
ordo_trace_span() {
  local span_id="${1-}"
  if [[ -z "$span_id" ]]; then
    _ordo_trace_fail usage "usage: ordo_trace_span <span_id>"
    return $?
  fi
  local trace_id
  if ! trace_id=$(_ordo_trace_lookup_trace "$span_id"); then
    _ordo_trace_fail not_found "unknown span ${span_id}" "$(jq -cn --arg s "$span_id" '{"span_id": $s}')"
    return $?
  fi
  ordo_trace_spans "$trace_id" | jq -c --arg s "$span_id" 'select(.span_id == $s)'
}

# shellcheck disable=SC2016 # jq program
ORDO_TRACE_JQ_OTLP='
  def kv: (. // {}) | to_entries | map({"key": .key, "value":
    (if (.value | type) == "number" then (if (.value | floor) == .value then {"intValue": (.value | tostring)} else {"doubleValue": .value} end)
     elif (.value | type) == "boolean" then {"boolValue": .value}
     elif (.value | type) == "string" then {"stringValue": .value}
     else {"stringValue": (.value | tojson)} end)});
  def otlp_kind: if . == "provider" then 3 else 1 end;
  def otlp_status: {"code": (if .code == "OK" then 1 elif .code == "ERROR" then 2 else 0 end), "message": (.message // "")};
  group_by(.resource) | map({
    "resource": {"attributes": (.[0].resource | kv)},
    "scopeSpans": [{
      "scope": {"name": $scope, "version": "1"},
      "spans": map({
        "traceId": .trace_id, "spanId": .span_id, "parentSpanId": (.parent_span_id // ""),
        "name": .name, "kind": (.kind | otlp_kind),
        "startTimeUnixNano": (.start_time_unix_nano | tostring),
        "endTimeUnixNano": ((.end_time_unix_nano // .start_time_unix_nano) | tostring),
        "attributes": ((.attributes + {"ordo.span.kind": .kind}) | kv),
        "status": (.status | otlp_status),
        "events": (.events | map({"name": .name, "timeUnixNano": (.time_unix_nano | tostring), "attributes": (.attributes | kv)}))
      })
    }]
  }) | {"resourceSpans": .}'

# ordo_trace_export <trace_id> [--format otlp-json|jsonl]
ordo_trace_export() {
  local trace_id="${1-}" format="otlp-json"
  if [[ -z "$trace_id" ]]; then
    _ordo_trace_fail usage "usage: ordo_trace_export <trace_id> [--format otlp-json|jsonl]"
    return $?
  fi
  shift
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --format) format="${2-}"; shift 2 ;;
      *)
        _ordo_trace_fail usage "unknown option for ordo_trace_export: ${1}" "$(jq -cn --arg opt "$1" '{"option": $opt}')"
        return $?
        ;;
    esac
  done
  case "$format" in
    jsonl) ordo_trace_spans "$trace_id" ;;
    otlp-json)
      local file
      file="$(ordo_trace_dir)/$trace_id.jsonl"
      if [[ ! -f "$file" ]]; then
        _ordo_trace_fail not_found "unknown trace ${trace_id}" "$(jq -cn --arg t "$trace_id" --arg f "$file" '{"trace_id": $t, "file": $f}')"
        return $?
      fi
      _ordo_trace_fold_file "$file" | jq -c --arg scope "$ORDO_TRACE_SCOPE_NAME" "$ORDO_TRACE_JQ_OTLP"
      ;;
    *)
      _ordo_trace_fail bad_argument "unknown export format '${format}' (otlp-json|jsonl)" "$(jq -cn --arg f "$format" '{"format": $f}')"
      return $?
      ;;
  esac
}

# ordo_trace_wrap <name> [--kind K] [--parent ID] [--trace ID] [--attr k=v ...] -- <command...>
#   Runs the command inside a span. Exit 0 -> status ok; anything else ->
#   status error with message "exit <rc>" and attribute ordo.exit_code. The
#   command's exit code is returned unchanged. ORDO_TRACE_ID and
#   ORDO_TRACE_PARENT_SPAN are exported to the command so nested spans link.
ordo_trace_wrap() {
  local name="${1-}"
  if [[ -z "$name" ]]; then
    _ordo_trace_fail usage "usage: ordo_trace_wrap <name> [--kind K] [--parent ID] [--trace ID] [--attr k=v ...] -- <command...>"
    return $?
  fi
  shift
  _ordo_trace_parse_opts ordo_trace_wrap "$@" || return $?
  if [[ "$_OT_HAS_REST" -ne 1 || "${#_OT_REST[@]}" -eq 0 ]]; then
    _ordo_trace_fail usage "ordo_trace_wrap needs a command after --" "$(jq -cn --arg n "$name" '{"name": $n}')"
    return $?
  fi
  local -a cmd=("${_OT_REST[@]}") attrs=("${_OT_ATTRS[@]+"${_OT_ATTRS[@]}"}")
  local kind="${_OT_KIND:-tool}" parent="$_OT_PARENT" trace_id="${_OT_TRACE:-$(ordo_trace_id)}"
  local cmdline
  cmdline=$(printf '%q ' "${cmd[@]}")
  cmdline="${cmdline% }"
  local -a start_args=(--kind "$kind" --trace "$trace_id" --attr "ordo.command=$cmdline" --attr "ordo.command.argv0=${cmd[0]}")
  [[ -n "$parent" ]] && start_args+=(--parent "$parent")
  local a
  for a in "${attrs[@]+"${attrs[@]}"}"; do start_args+=(--attr "$a"); done
  local span_id
  span_id=$(ordo_trace_start "$name" "${start_args[@]}") || return $?
  local rc=0
  ORDO_TRACE_ID="$trace_id" ORDO_TRACE_PARENT_SPAN="$span_id" "${cmd[@]}" || rc=$?
  if [[ "$rc" -eq 0 ]]; then
    ordo_trace_end "$span_id" --trace "$trace_id" --status ok --attr "ordo.exit_code=0" >/dev/null 2>&1 || true
  else
    ordo_trace_end "$span_id" --trace "$trace_id" --status error --message "exit ${rc}" --attr "ordo.exit_code=${rc}" >/dev/null 2>&1 || true
  fi
  return "$rc"
}
