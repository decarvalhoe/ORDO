#!/usr/bin/env bash
# scripts/ordo_approve.sh — operator entry point for approval-safe actions (#812, epic #806).
#
# Usage:
#   ordo_approve.sh <project_short|config_path> <command> [args...] [--json]
#
# Commands:
#   request <run_id> <action> --principal P --idempotency-key K
#           [--policy-version V] [--ttl S] [--payload JSON]
#                             persist a typed approval (pending) for one action of a run
#   grant <approval_id> [--by ACTOR] [--reason R]
#                             pending -> granted; ACTOR must be an operator or
#                             system actor (models never grant)
#   deny <approval_id> [--by ACTOR] [--reason R]
#                             pending -> denied
#   get <approval_id>         print one approval (with its pinned payload)
#   list <run_id> [--state S] approvals of a run, one JSON line each
#   sweep [--run-id R]        expire pending/granted approvals past expires_at
#   authorize-and-run <approval_id> -- <provider op> [args...]
#                             re-authorize immediately before execution, then run the
#                             provider op with the approval's idempotency key
#   policy-version            print the policy version approvals are pinned to
#
# ACTOR is a JSON actor object, "type:id", or a bare id (=> operator). Without
# --by the actor is ORDO_ACTOR, else operator ${ORDO_OPERATOR:-$USER}.
#
# The command word may appear anywhere after the project: the unified CLI
# appends it (`ordo approve <project> <approval_id> --by eric` runs
# `ordo_approve.sh <project> <approval_id> --by eric grant`; `ordo approve
# --list <project> <run_id>` runs `... <run_id> list`; `ordo approve --deny ...`
# runs `... deny`).
#
# Output is JSON with --json (the `ordo` CLI passes it through); without it a
# short human summary is printed. Errors are ONE JSON line on stderr and the
# exit code follows the agentic-control-plane table (docs/exit-codes.md):
# 2 usage, 3 refused by policy, 4 not found, 5 invalid state / conflict.
# Reference: docs/architecture/approvals.md.
set -euo pipefail

TK="${TK:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
export TK

ORDO_APPROVE_COMMANDS="request grant deny get list sweep authorize-and-run policy-version"

usage() {
  sed -n '2,38p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

approve_error() {
  # approve_error <code> <message> [details-json] -> prints the error object, returns the exit code
  local code=$1 message=$2 details=${3:-{\}}
  if declare -F ordo_contracts_error >/dev/null 2>&1; then
    ordo_contracts_error approval "$code" "$message" "$details"
    return $?
  fi
  printf '{"error":{"code":"%s","message":"%s","module":"approval","details":%s}}\n' "$code" "$message" "$details" >&2
  case "$code" in
    usage|bad_argument|unknown_command) return 2 ;;
    not_found) return 4 ;;
    *) return 1 ;;
  esac
}

is_command() {
  local word=$1 c
  for c in $ORDO_APPROVE_COMMANDS; do
    [[ "$c" == "$word" ]] && return 0
  done
  return 1
}

PROJECT_ARG=""
COMMAND=""
JSON=0
ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --json)
      JSON=1
      shift
      ;;
    --)
      # Everything after the literal -- is the provider op and its arguments.
      ARGS+=("$@")
      break
      ;;
    --*)
      # Every other option takes a value; keep the pair together.
      if [[ $# -lt 2 ]]; then
        approve_error usage "option $1 requires a value" "$(printf '{"option":"%s"}' "$1")"
        exit $?
      fi
      ARGS+=("$1" "$2")
      shift 2
      ;;
    *)
      if [[ -z "$PROJECT_ARG" ]]; then
        PROJECT_ARG=$1
      elif [[ -z "$COMMAND" ]] && is_command "$1"; then
        COMMAND=$1
      else
        ARGS+=("$1")
      fi
      shift
      ;;
  esac
done

if [[ -z "$PROJECT_ARG" ]]; then
  usage >&2
  approve_error usage "missing <project>" '{"hint":"ordo_approve.sh <project> <command> [args]"}'
  exit $?
fi
if [[ -z "$COMMAND" ]]; then
  usage >&2
  approve_error usage "missing <command> (one of: ${ORDO_APPROVE_COMMANDS})" \
    "$(printf '{"known":"%s"}' "$ORDO_APPROVE_COMMANDS")"
  exit $?
fi

# shellcheck disable=SC1091
source "$TK/lib/config_resolver.sh"
if ! load_project_config "$PROJECT_ARG"; then
  approve_error not_found "project config not found: ${PROJECT_ARG}" "$(printf '{"project":"%s"}' "$PROJECT_ARG")"
  exit $?
fi
# shellcheck disable=SC1091
source "$TK/lib/audit_log.sh"
# shellcheck disable=SC1091
source "$TK/lib/state_persist.sh"
set +e
# shellcheck disable=SC1091
source "$TK/lib/ordo_approval.sh"
set -e

# Split "<positional...>" from "-- <op> <args>" for authorize-and-run.
positional=()
tail_args=()
seen_dd=0
for a in "${ARGS[@]+"${ARGS[@]}"}"; do
  if [[ "$seen_dd" -eq 1 ]]; then
    tail_args+=("$a")
  elif [[ "$a" == "--" ]]; then
    seen_dd=1
  else
    positional+=("$a")
  fi
done

first_positional() {
  local a
  for a in "${positional[@]+"${positional[@]}"}"; do
    if [[ "$a" != -* ]]; then
      printf '%s\n' "$a"
      return 0
    fi
  done
  return 1
}

# Human rendering of the JSON result. --json prints the object verbatim.
render() {
  local json=$1
  if [[ "$JSON" == 1 ]]; then
    printf '%s\n' "$json"
    return 0
  fi
  case "$COMMAND" in
    list)
      printf '%s\n' "$json" | jq -r '"\(.id) \(.state) action=\(.action) principal=\(.principal) policy=\(.policy_version) expires=\(.expires_at // "-")"'
      ;;
    sweep)
      printf '%s' "$json" | jq -r '"sweep now=\(.now) expired=\(.count)", (.expired[] | "expired \(.approval_id) run=\(.run_id) action=\(.action) was=\(.was)")'
      ;;
    authorize-and-run)
      printf '%s' "$json" | jq -r '"executed \(.op) via \(.adapter) approval=\(.approval_id) replayed=\(.details.replayed) key=\(.details.idempotency_key)"'
      ;;
    policy-version)
      printf '%s\n' "$json"
      ;;
    *)
      printf '%s' "$json" | jq -r '"\(.id) \(.state) action=\(.action) principal=\(.principal) run=\(.run_id) expires=\(.expires_at // "-")" + (if .decided_by then " by=\(.decided_by.type):\(.decided_by.id)" else "" end) + (if .reason then " reason=\(.reason)" else "" end)'
      ;;
  esac
}

result=""
rc=0
case "$COMMAND" in
  request)
    if [[ "${#positional[@]}" -lt 2 ]]; then
      approve_error usage "request needs <run_id> <action>" '{"command":"request"}'
      exit $?
    fi
    result=$(ordo_approval_request "${positional[@]}") || rc=$?
    ;;
  grant|deny)
    id=$(first_positional) || { approve_error usage "${COMMAND} needs an <approval_id>" "$(printf '{"command":"%s"}' "$COMMAND")"; exit $?; }
    rest=()
    for a in "${positional[@]}"; do [[ "$a" == "$id" ]] || rest+=("$a"); done
    result=$("ordo_approval_${COMMAND}" "$id" "${rest[@]+"${rest[@]}"}") || rc=$?
    ;;
  get)
    id=$(first_positional) || { approve_error usage "get needs an <approval_id>" '{"command":"get"}'; exit $?; }
    result=$(ordo_approval_get "$id") || rc=$?
    ;;
  list)
    id=$(first_positional) || { approve_error usage "list needs a <run_id>" '{"command":"list"}'; exit $?; }
    rest=()
    for a in "${positional[@]}"; do [[ "$a" == "$id" ]] || rest+=("$a"); done
    result=$(ordo_approval_list "$id" "${rest[@]+"${rest[@]}"}") || rc=$?
    ;;
  sweep)
    result=$(ordo_approval_sweep "${positional[@]+"${positional[@]}"}") || rc=$?
    ;;
  authorize-and-run)
    id=$(first_positional) || { approve_error usage "authorize-and-run needs an <approval_id> and -- <op> [args]" '{"command":"authorize-and-run"}'; exit $?; }
    rest=()
    for a in "${positional[@]}"; do [[ "$a" == "$id" ]] || rest+=("$a"); done
    result=$(ordo_approval_authorize_and_run "$id" "${rest[@]+"${rest[@]}"}" -- "${tail_args[@]+"${tail_args[@]}"}") || rc=$?
    ;;
  policy-version)
    result=$(ordo_approval_policy_version) || rc=$?
    if [[ "$JSON" == 1 ]]; then
      result=$(jq -cn --arg v "$result" '{"policy_version": $v}')
    fi
    ;;
esac

if [[ -n "$result" ]]; then
  render "$result"
fi
exit "$rc"
