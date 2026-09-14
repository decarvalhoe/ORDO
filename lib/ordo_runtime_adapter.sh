#!/usr/bin/env bash
# lib/ordo_runtime_adapter.sh — runtime adapter boundary (#811, epic #806).
#
# One generic entry point, `ordo_runtime <op> [args]`, dispatching on
# ORDO_RUNTIME_ADAPTER=tmux|ssh|fake to a backend that implements the six
# runtime operations:
#
#   start            submit text (a dispatch brief) to an agent runtime target
#   inspect          read the live state of a target (alive, idle, cwd, tail)
#   signal           deliver a control signal (interrupt, escape, enter, clear, key)
#   stop             interrupt the running command (or --kill the target)
#   collect_evidence persist the target's recent output as a redacted artifact
#   recover          bring a dead/missing target back (create/respawn)
#
# Backends live in lib/ordo_runtime_adapter_<name>.sh and define
# `ordo_runtime_adapter_<name>_<op>`. `tmux` wraps lib/tmux_helpers.sh
# (send_to_pane, capture_pane, agent_is_idle, terminal_dispatch_*,
# tmux_pane_values_batch, pane_acceptance_proof) — it never re-implements
# them. `ssh` ships the same tmux commands to a remote host through the
# CRLF-safe transport of scripts/windows_ssh_dispatch.sh
# (`ssh <host> "tr -d '\r' | bash -s"`). `fake` reads/writes JSON files
# under $ORDO_FAKE_ADAPTER_DIR for tests and for the eval harness (#813).
#
# Every op prints exactly ONE JSON object on stdout (shapes documented in
# docs/architecture/adapters.md). Every failure prints ONE error object on
# stderr through ordo_contracts_error with module "runtime_adapter" and
# `details.retryable` set, and returns the mapped exit code:
#   usage/bad_argument 2, not_found 4, missing_dependency 6,
#   runtime_error 1 (retryable when the failure was a timeout/transport hiccup).
#
# Public API:
#   ordo_runtime <op> [args...]
#   ordo_runtime_adapter_name              # resolved adapter name
#   ordo_runtime_adapter_ops               # one op per line
#   ordo_runtime_adapter_names             # one registered adapter per line
#   ordo_runtime_adapter_result <op> <json-fields>   # helper for backends
#   ordo_runtime_adapter_error <code> <message> <retryable> [details-json]
#
# Dependencies: bash >= 4, jq, coreutils. tmux/ssh only for those backends.

if [[ -n "${ORDO_RUNTIME_ADAPTER_LIB_LOADED:-}" ]]; then
  return 0
fi
ORDO_RUNTIME_ADAPTER_LIB_LOADED=1

_ORDO_RUNTIME_ADAPTER_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/ordo_contracts.sh
source "$_ORDO_RUNTIME_ADAPTER_LIB_DIR/ordo_contracts.sh"

ORDO_RUNTIME_ADAPTER_MODULE="runtime_adapter"
ORDO_RUNTIME_ADAPTER_OPS="start inspect signal stop collect_evidence recover"
# Registry: <name>|<status>. status = implemented | stub(<issue>).
ORDO_RUNTIME_ADAPTER_REGISTRY="tmux|implemented ssh|implemented fake|implemented"
: "${ORDO_RUNTIME_ADAPTER:=tmux}"
: "${ORDO_RUNTIME_EVIDENCE_LINES:=200}"
: "${ORDO_RUNTIME_INSPECT_LINES:=30}"

ordo_runtime_adapter_ops() {
  local op
  for op in $ORDO_RUNTIME_ADAPTER_OPS; do
    printf '%s\n' "$op"
  done
}

ordo_runtime_adapter_names() {
  local entry
  for entry in $ORDO_RUNTIME_ADAPTER_REGISTRY; do
    printf '%s\n' "${entry%%|*}"
  done
}

ordo_runtime_adapter_name() {
  printf '%s\n' "${ORDO_RUNTIME_ADAPTER:-tmux}"
}

_ordo_runtime_adapter_is_op() {
  local op="${1-}" o
  for o in $ORDO_RUNTIME_ADAPTER_OPS; do
    [[ "$o" == "$op" ]] && return 0
  done
  return 1
}

_ordo_runtime_adapter_registered() {
  local name="${1-}" entry
  for entry in $ORDO_RUNTIME_ADAPTER_REGISTRY; do
    [[ "${entry%%|*}" == "$name" ]] && return 0
  done
  return 1
}

# ordo_runtime_adapter_error <code> <message> <retryable:true|false> [details-json]
ordo_runtime_adapter_error() {
  local code="${1:?}" message="${2:?}" retryable="${3:-false}" details="${4:-{\}}"
  local merged
  merged=$(printf '%s' "$details" | jq -c --arg r "$retryable" --arg a "$(ordo_runtime_adapter_name)" \
    '(if type == "object" then . else {"value": .} end) + {"retryable": ($r == "true"), "adapter": $a}' 2>/dev/null) \
    || merged=$(jq -cn --arg r "$retryable" --arg a "$(ordo_runtime_adapter_name)" '{"retryable": ($r == "true"), "adapter": $a}')
  ordo_contracts_error "$ORDO_RUNTIME_ADAPTER_MODULE" "$code" "$message" "$merged"
}

# ordo_runtime_adapter_result <op> <json-object>
#   Prints the normalised envelope: {"op","adapter","ts", ...fields}.
ordo_runtime_adapter_result() {
  local op="${1:?}" fields="${2:-{\}}"
  jq -cn --arg op "$op" --arg adapter "$(ordo_runtime_adapter_name)" --arg ts "$(ordo_contracts_now)" \
    --argjson fields "$fields" '{"op": $op, "adapter": $adapter, "ts": $ts} + $fields'
}

# Mask token-looking values in free text (pane captures) with the same
# patterns ordo_contracts_redact applies to JSON strings.
ordo_runtime_adapter_redact_text() {
  sed -E "s/${ORDO_CONTRACTS_REDACT_VALUE_RE}/${ORDO_CONTRACTS_REDACT_MASK}/g"
}

# Filesystem-safe form of a target such as "fleet-001:0.0".
ordo_runtime_adapter_safe_name() {
  printf '%s' "${1:-target}" | tr -c 'A-Za-z0-9._-' '_'
}

# Evidence directory: <state_dir>/runtime-evidence (state_dir from
# lib/audit_log.sh when sourced, otherwise the same layout under
# ORCH_STATE_BASE) or ORDO_RUNTIME_EVIDENCE_DIR when set.
ordo_runtime_adapter_evidence_dir() {
  local dir
  if [[ -n "${ORDO_RUNTIME_EVIDENCE_DIR:-}" ]]; then
    dir="$ORDO_RUNTIME_EVIDENCE_DIR"
  elif declare -F state_dir >/dev/null 2>&1; then
    dir="$(state_dir)/runtime-evidence"
  else
    dir="${ORCH_STATE_BASE:-${XDG_DATA_HOME:-$HOME/.local/share}/orch-state}/${PROJECT:-default}/runtime-evidence"
  fi
  mkdir -p "$dir" 2>/dev/null || true
  printf '%s\n' "$dir"
}

# ordo_runtime_adapter_write_evidence <target> <label> <content-file>
#   Redacts, stores, and prints {"path","lines","sha256","bytes","redacted":true}.
ordo_runtime_adapter_write_evidence() {
  local target="${1:?}" label="${2:-capture}" src="${3:?}"
  local dir path stamp
  dir=$(ordo_runtime_adapter_evidence_dir)
  stamp=$(date -u +%Y%m%dT%H%M%SZ)
  path="$dir/$(ordo_runtime_adapter_safe_name "$target")-${stamp}-$(ordo_runtime_adapter_safe_name "$label")-$$.txt"
  ordo_runtime_adapter_redact_text < "$src" > "$path"
  local lines bytes sum
  lines=$(wc -l < "$path" | tr -d ' ')
  bytes=$(wc -c < "$path" | tr -d ' ')
  sum=$(sha256sum "$path" | awk '{print $1}')
  jq -cn --arg path "$path" --argjson lines "$lines" --argjson bytes "$bytes" --arg sum "$sum" \
    '{"path": $path, "lines": $lines, "bytes": $bytes, "sha256": $sum, "redacted": true}'
}

_ordo_runtime_adapter_load() {
  local name="$1"
  local file="$_ORDO_RUNTIME_ADAPTER_LIB_DIR/ordo_runtime_adapter_${name}.sh"
  if declare -F "ordo_runtime_adapter_${name}_inspect" >/dev/null 2>&1; then
    return 0
  fi
  if [[ -f "$file" ]]; then
    # shellcheck disable=SC1090 # adapter file selected at runtime
    source "$file"
    return 0
  fi
  return 1
}

# ordo_runtime <op> [args...]
ordo_runtime() {
  local op="${1-}"
  if [[ -z "$op" ]]; then
    ordo_runtime_adapter_error usage "usage: ordo_runtime <op> [args] (ops: ${ORDO_RUNTIME_ADAPTER_OPS})" false
    return $?
  fi
  shift
  case "$op" in
    ops) ordo_runtime_adapter_ops; return 0 ;;
    adapters) ordo_runtime_adapter_names; return 0 ;;
  esac
  if ! _ordo_runtime_adapter_is_op "$op"; then
    ordo_runtime_adapter_error unknown_command "unknown runtime op: '${op}'" false \
      "$(jq -cn --arg op "$op" --arg ops "$ORDO_RUNTIME_ADAPTER_OPS" '{"op": $op, "known": ($ops | split(" "))}')"
    return $?
  fi
  local name
  name=$(ordo_runtime_adapter_name)
  if ! _ordo_runtime_adapter_registered "$name"; then
    ordo_runtime_adapter_error bad_argument "unknown runtime adapter: '${name}' (ORDO_RUNTIME_ADAPTER)" false \
      "$(jq -cn --arg name "$name" --arg known "$(ordo_runtime_adapter_names | paste -sd' ' -)" '{"adapter": $name, "known": ($known | split(" "))}')"
    return $?
  fi
  if ! _ordo_runtime_adapter_load "$name"; then
    ordo_runtime_adapter_error provider_not_available "runtime adapter '${name}' is registered but not implemented" false \
      "$(jq -cn --arg name "$name" '{"adapter": $name}')"
    return $?
  fi
  local fn="ordo_runtime_adapter_${name}_${op}"
  if ! declare -F "$fn" >/dev/null 2>&1; then
    ordo_runtime_adapter_error not_implemented "runtime adapter '${name}' does not implement op '${op}'" false \
      "$(jq -cn --arg name "$name" --arg op "$op" '{"adapter": $name, "op": $op}')"
    return $?
  fi
  "$fn" "$@"
}

# ---------------------------------------------------------------------------
# Shared argument parsing so every backend accepts the same flags.
# Sets ORDO_RT_TARGET, ORDO_RT_TEXT, ORDO_RT_TEXT_FILE, ORDO_RT_WORKDIR,
# ORDO_RT_LINES, ORDO_RT_OUT, ORDO_RT_LABEL, ORDO_RT_COMMAND, ORDO_RT_KILL,
# ORDO_RT_SIGNAL, ORDO_RT_HOST, ORDO_RT_AGENT, ORDO_RT_TICKET,
# ORDO_RT_ACCEPT_TIMEOUT. Returns 2 (after printing an error) on bad input.
# ---------------------------------------------------------------------------
# shellcheck disable=SC2034 # ORDO_RT_* are consumed by the backend files
ordo_runtime_adapter_parse_args() {
  local op="${1:?}"
  shift
  ORDO_RT_TARGET="" ORDO_RT_TEXT="" ORDO_RT_TEXT_FILE="" ORDO_RT_WORKDIR="" ORDO_RT_LINES=""
  ORDO_RT_OUT="" ORDO_RT_LABEL="" ORDO_RT_COMMAND="" ORDO_RT_KILL=0 ORDO_RT_SIGNAL="" ORDO_RT_HOST=""
  ORDO_RT_AGENT="" ORDO_RT_TICKET="" ORDO_RT_ACCEPT_TIMEOUT=""
  local -a positional=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --text) ORDO_RT_TEXT="${2-}"; shift 2 ;;
      --text-file) ORDO_RT_TEXT_FILE="${2-}"; shift 2 ;;
      --workdir) ORDO_RT_WORKDIR="${2-}"; shift 2 ;;
      --lines) ORDO_RT_LINES="${2-}"; shift 2 ;;
      --out) ORDO_RT_OUT="${2-}"; shift 2 ;;
      --label) ORDO_RT_LABEL="${2-}"; shift 2 ;;
      --command) ORDO_RT_COMMAND="${2-}"; shift 2 ;;
      --host) ORDO_RT_HOST="${2-}"; shift 2 ;;
      --agent) ORDO_RT_AGENT="${2-}"; shift 2 ;;
      --ticket) ORDO_RT_TICKET="${2-}"; shift 2 ;;
      --acceptance-timeout) ORDO_RT_ACCEPT_TIMEOUT="${2-}"; shift 2 ;;
      --kill) ORDO_RT_KILL=1; shift ;;
      --) shift; positional+=("$@"); break ;;
      -*)
        ordo_runtime_adapter_error bad_argument "unknown argument for ${op}: $1" false \
          "$(jq -cn --arg op "$op" --arg arg "$1" '{"op": $op, "argument": $arg}')"
        return $?
        ;;
      *) positional+=("$1"); shift ;;
    esac
  done
  ORDO_RT_TARGET="${positional[0]:-}"
  if [[ -z "$ORDO_RT_TARGET" ]]; then
    ordo_runtime_adapter_error usage "usage: ordo_runtime ${op} <target> [flags]" false \
      "$(jq -cn --arg op "$op" '{"op": $op, "missing": "target"}')"
    return $?
  fi
  case "$op" in
    signal)
      ORDO_RT_SIGNAL="${positional[1]:-}"
      if [[ -z "$ORDO_RT_SIGNAL" ]]; then
        ordo_runtime_adapter_error usage "usage: ordo_runtime signal <target> <interrupt|escape|enter|clear|KEY>" false \
          "$(jq -cn '{"op": "signal", "missing": "signal"}')"
        return $?
      fi
      ;;
    start)
      if [[ -n "$ORDO_RT_TEXT_FILE" ]]; then
        if [[ ! -r "$ORDO_RT_TEXT_FILE" ]]; then
          ordo_runtime_adapter_error not_found "text file not readable: ${ORDO_RT_TEXT_FILE}" false \
            "$(jq -cn --arg f "$ORDO_RT_TEXT_FILE" '{"op": "start", "text_file": $f}')"
          return $?
        fi
        ORDO_RT_TEXT=$(cat "$ORDO_RT_TEXT_FILE")
      fi
      if [[ -z "$ORDO_RT_TEXT" ]]; then
        ordo_runtime_adapter_error usage "usage: ordo_runtime start <target> (--text T | --text-file F) [--workdir D]" false \
          "$(jq -cn '{"op": "start", "missing": "text"}')"
        return $?
      fi
      ;;
  esac
  if [[ -n "$ORDO_RT_LINES" && ! "$ORDO_RT_LINES" =~ ^[0-9]+$ ]]; then
    ordo_runtime_adapter_error bad_argument "--lines must be an integer" false \
      "$(jq -cn --arg v "$ORDO_RT_LINES" '{"lines": $v}')"
    return $?
  fi
  return 0
}

# Map a neutral signal name to a tmux key name (shared by tmux and ssh).
ordo_runtime_adapter_signal_keys() {
  case "${1:?}" in
    interrupt) printf 'C-c\n' ;;
    escape) printf 'Escape\n' ;;
    enter) printf 'Enter\n' ;;
    clear) printf 'Escape\nC-u\n' ;;
    *) printf '%s\n' "$1" ;;
  esac
}
