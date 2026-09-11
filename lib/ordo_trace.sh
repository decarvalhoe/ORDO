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
  mkdir -p "$dir" 2>/dev/null || true
  printf '%s\n' "$dir"
}

ordo_trace_now_ns() {
  if [[ -n "${ORDO_TRACE_NOW_NS:-}" ]]; then
    printf '%s\n' "$ORDO_TRACE_NOW_NS"
  elif [[ -n "${ORDO_JOURNAL_NOW:-}" ]]; then
    local s
    s=$(date -u -d "$ORDO_JOURNAL_NOW" +%s 2>/dev/null) || s=$(date -u +%s)
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
    hex=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n' | cut -c1-"$len")
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
  local kind="${1-}" k
  for k in $ORDO_TRACE_KINDS; do
    [[ "$k" == "$kind" ]] && return 0
  done
  return 1
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
# contracts secret-key regex, values of 8+ chars), as a JSON array.
_ordo_trace_env_secrets() {
  local name value
  local -a values=()
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    if printf '%s' "$name" | grep -Eiq "$ORDO_CONTRACTS_REDACT_KEY_RE"; then
      value="${!name-}"
      [[ ${#value} -ge 8 ]] && values+=("$value")
    fi
  done < <(compgen -e)
  if [[ ${#values[@]} -eq 0 ]]; then
    printf '[]\n'
  else
    printf '%s\n' "${values[@]}" | jq -R . | jq -sc .
  fi
}

# ordo_trace_redact <json>
#   contracts redaction + literal env secrets + ORDO_TRACE_REDACT_RE.
ordo_trace_redact() {
  local json="${1-}" out
  out=$(ordo_contracts_redact "$json") || return $?
  local secrets
  secrets=$(_ordo_trace_env_secrets)
  printf '%s' "$out" | jq -c --argjson secrets "$secrets" --arg extra "$ORDO_TRACE_REDACT_RE" \
    --arg mask "$ORDO_CONTRACTS_REDACT_MASK" '
    def scrub: reduce $secrets[] as $s (.; if ($s | length) > 0 then split($s) | join($mask) else . end)
               | if $extra == "" then . else gsub($extra; $mask) end;
    walk(if type == "string" then scrub else . end)'
}

# _ordo_trace_attrs <k=v ...> -> redacted JSON object (numbers/booleans typed)
_ordo_trace_attrs() {
  local obj='{}' pair key value
  for pair in "$@"; do
    key="${pair%%=*}"
    value="${pair#*=}"
    [[ -n "$key" && "$pair" == *=* ]] || continue
    obj=$(printf '%s' "$obj" | jq -c --arg k "$key" --arg v "$value" \
      '.[$k] = (if ($v | test("^-?[0-9]+$")) then ($v | tonumber)
                elif ($v | test("^-?[0-9]+\\.[0-9]+$")) then ($v | tonumber)
                elif $v == "true" then true elif $v == "false" then false
                else $v end)')
  done
  ordo_trace_redact "$obj"
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
  local attrs status line safe_name
  attrs=$(_ordo_trace_attrs "${_OT_ATTRS[@]+"${_OT_ATTRS[@]}"}") || return $?
  status=$(_ordo_trace_status_json unset "")
  safe_name=$(ordo_trace_redact "$(jq -cn --arg n "$name" '{"n": $n}')" | jq -r '.n')
  line=$(jq -cn --arg phase start --arg trace "$trace_id" --arg span "$span_id" --arg parent "$parent" \
    --arg name "$safe_name" --arg kind "${_OT_KIND:-internal}" --arg now "$(ordo_trace_now_ns)" \
    --argjson attrs "$attrs" --argjson status "$status" --argjson resource "$(_ordo_trace_resource)" '
    {"phase": $phase, "trace_id": $trace, "span_id": $span,
     "parent_span_id": (if $parent == "" then null else $parent end),
     "name": $name, "kind": $kind, "start_time_unix_nano": ($now | tonumber),
     "end_time_unix_nano": null, "status": $status, "attributes": $attrs, "resource": $resource}')
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
  local attrs status line
  attrs=$(_ordo_trace_attrs "${_OT_ATTRS[@]+"${_OT_ATTRS[@]}"}") || return $?
  status=$(_ordo_trace_status_json "${_OT_STATUS:-unset}" "$_OT_MESSAGE")
  line=$(jq -cn --arg trace "$trace_id" --arg span "$span_id" --arg now "$(ordo_trace_now_ns)" \
    --argjson attrs "$attrs" --argjson status "$status" '
    {"phase": "end", "trace_id": $trace, "span_id": $span, "parent_span_id": null, "name": null, "kind": null,
     "start_time_unix_nano": null, "end_time_unix_nano": ($now | tonumber), "status": $status,
     "attributes": $attrs, "resource": null}')
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
  local attrs line safe_name
  attrs=$(_ordo_trace_attrs "${_OT_ATTRS[@]+"${_OT_ATTRS[@]}"}") || return $?
  safe_name=$(ordo_trace_redact "$(jq -cn --arg n "$name" '{"n": $n}')" | jq -r '.n')
  line=$(jq -cn --arg trace "$trace_id" --arg span "$span_id" --arg name "$safe_name" --arg now "$(ordo_trace_now_ns)" \
    --argjson attrs "$attrs" '
    {"phase": "event", "trace_id": $trace, "span_id": $span, "parent_span_id": null, "name": $name, "kind": null,
     "start_time_unix_nano": null, "end_time_unix_nano": null, "time_unix_nano": ($now | tonumber),
     "status": null, "attributes": $attrs, "resource": null}')
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
