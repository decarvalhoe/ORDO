#!/usr/bin/env bash
# contracts/v1/emit.sh — CLI over lib/ordo_contracts.sh for the v1 contracts.
#
# The contract data (schemas, transition tables, exit-code map, redaction
# rules) lives in lib/ordo_contracts.sh so that the sanitized test runners can
# exercise it. This script only exposes that data to humans and tooling:
#
#   contracts/v1/emit.sh kinds                      # one kind per line
#   contracts/v1/emit.sh tables                     # one transition table per line
#   contracts/v1/emit.sh schema <kind>              # JSON schema of one kind
#   contracts/v1/emit.sh schemas                    # {"<kind>": schema, ...}
#   contracts/v1/emit.sh transitions <table>        # {"<from>": ["<to>", ...]}
#   contracts/v1/emit.sh exit-codes                 # {"<error code>": <exit>, ...}
#   contracts/v1/emit.sh validate <kind> <json|-|@path>
#   contracts/v1/emit.sh redact <json|-|@path>
#   contracts/v1/emit.sh new-id <kind>
#   contracts/v1/emit.sh now
#   contracts/v1/emit.sh write-schemas <dir>        # one <kind>.schema.json per kind
#
# Exit codes follow the shared table (0 ok, 2 usage, 5 invalid, ...); failures
# print one JSON error line on stderr. See contracts/README.md.
set -euo pipefail

CONTRACTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TK="$(cd "$CONTRACTS_DIR/../.." && pwd)"

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../lib/ordo_contracts.sh
source "$TK/lib/ordo_contracts.sh"

emit_usage() {
  sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
}

emit_schemas() {
  local kind first=1
  printf '{'
  for kind in $(ordo_contracts_kinds); do
    if [[ $first -eq 1 ]]; then first=0; else printf ','; fi
    printf '%s:' "$(jq -cn --arg k "$kind" '$k')"
    ordo_contracts_schema "$kind" | jq -c .
  done
  printf '}\n'
}

emit_write_schemas() {
  local dir="${1-}" kind
  if [[ -z "$dir" ]]; then
    ordo_contracts_error "$ORDO_CONTRACTS_MODULE" usage "usage: emit.sh write-schemas <dir>"
    return $?
  fi
  mkdir -p "$dir"
  for kind in $(ordo_contracts_kinds); do
    ordo_contracts_schema "$kind" > "$dir/$kind.schema.json"
    printf '%s\n' "$dir/$kind.schema.json"
  done
}

main() {
  local cmd="${1-}"
  shift || true
  case "$cmd" in
    kinds)         ordo_contracts_kinds ;;
    tables)        ordo_contracts_tables ;;
    schema)        ordo_contracts_schema "$@" ;;
    schemas)       emit_schemas | jq . ;;
    transitions)   ordo_contracts_transitions "$@" ;;
    exit-codes)    ordo_contracts_exit_codes ;;
    validate)      ordo_contracts_validate "$@" ;;
    redact)        ordo_contracts_redact "$@" ;;
    new-id)        ordo_contracts_new_id "$@" ;;
    now)           ordo_contracts_now ;;
    write-schemas) emit_write_schemas "$@" ;;
    help|-h|--help) emit_usage; return 0 ;;
    "")
      emit_usage
      ordo_contracts_error "$ORDO_CONTRACTS_MODULE" usage "missing command"
      ;;
    *)
      ordo_contracts_error "$ORDO_CONTRACTS_MODULE" unknown_command "unknown command: '${cmd}'" \
        "$(jq -cn --arg c "$cmd" '{"command": $c}')"
      ;;
  esac
}

main "$@"
