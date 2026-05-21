#!/usr/bin/env bash
# scripts/parked_decisions.sh — operator-facing CLI on top of
# `lib/parked_decisions.sh`. Wraps the ledger with four subcommands:
#
#   list           Compact TSV of parked items.
#   add            Idempotent insert/update keyed by id.
#   clear          Remove one entry by id.
#   reminders      Markdown bullet lines for trailing a status report.
#
# Storage and behavioral contract: see `lib/parked_decisions.sh` and
# `docs/dispatch.md` ("Parked decisions ledger"). Source ticket: rbok#725.

set -euo pipefail

TK="${TK:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# audit_log.sh is required for state_dir() in real deployments. In sanitized
# test sandboxes that pass PARKED_DECISIONS_FILE explicitly, the lib is
# usable without the audit machinery; guard the source so the CLI still
# parses when the helper is absent.
if [[ -f "$TK/lib/audit_log.sh" ]] && [[ -n "${PROJECT:-}" ]]; then
  # shellcheck source=../lib/audit_log.sh
  source "$TK/lib/audit_log.sh"
fi
if [[ -f "$TK/lib/state_persist.sh" ]] && [[ -n "${PROJECT:-}" ]]; then
  # shellcheck source=../lib/state_persist.sh
  source "$TK/lib/state_persist.sh"
fi
# shellcheck source=../lib/parked_decisions.sh
source "$TK/lib/parked_decisions.sh"

usage() {
  cat <<'EOF' >&2
usage: parked_decisions.sh <subcommand> [args]

subcommands:
  list
      Emit one TSV row per parked item:
          id<TAB>kind<TAB>source<TAB>agent<TAB>target<TAB>summary

  add --id <id> --kind <kind> --source <source>
      [--agent <agent>] [--target <ref>] [--summary <text>] [--options <text>]
      Idempotent: re-adding the same id updates the row in place; created_at
      from the first add is preserved.

  clear --id <id>
      Drop one entry. No-op when the id is absent.

  reminders
      Emit Markdown bullet lines suitable for trailing a status report.
      Empty stdout when no entries are parked.

environment:
  PARKED_DECISIONS_FILE   Explicit file path override (defaults to
                          state_dir()/parked_decisions.json).
  PROJECT, ORCH_STATE_BASE
                          Standard ORDO state-dir resolution.
EOF
}

cmd_list() {
  if [[ "$#" -gt 0 ]]; then
    usage
    exit 2
  fi
  parked_decisions_list
}

cmd_add() {
  local id="" kind="" source="" agent="" target="" summary="" options=""
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --id)        id=${2:?missing value for --id}; shift 2 ;;
      --id=*)      id=${1#--id=}; shift ;;
      --kind)      kind=${2:?missing value for --kind}; shift 2 ;;
      --kind=*)    kind=${1#--kind=}; shift ;;
      --source)    source=${2:?missing value for --source}; shift 2 ;;
      --source=*)  source=${1#--source=}; shift ;;
      --agent)     agent=${2:?missing value for --agent}; shift 2 ;;
      --agent=*)   agent=${1#--agent=}; shift ;;
      --target)    target=${2:?missing value for --target}; shift 2 ;;
      --target=*)  target=${1#--target=}; shift ;;
      --summary)   summary=${2:?missing value for --summary}; shift 2 ;;
      --summary=*) summary=${1#--summary=}; shift ;;
      --options)   options=${2:?missing value for --options}; shift 2 ;;
      --options=*) options=${1#--options=}; shift ;;
      *) printf 'parked_decisions: add: unknown arg %q\n' "$1" >&2; usage; exit 2 ;;
    esac
  done
  if [[ -z "$id" || -z "$kind" || -z "$source" ]]; then
    printf 'parked_decisions: add requires --id, --kind, --source\n' >&2
    usage
    exit 2
  fi
  parked_decisions_add "$id" "$kind" "$source" "$agent" "$target" "$summary" "$options"
}

cmd_clear() {
  local id=""
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --id)   id=${2:?missing value for --id}; shift 2 ;;
      --id=*) id=${1#--id=}; shift ;;
      *) printf 'parked_decisions: clear: unknown arg %q\n' "$1" >&2; usage; exit 2 ;;
    esac
  done
  if [[ -z "$id" ]]; then
    printf 'parked_decisions: clear requires --id\n' >&2
    usage
    exit 2
  fi
  parked_decisions_clear "$id"
}

cmd_reminders() {
  if [[ "$#" -gt 0 ]]; then
    usage
    exit 2
  fi
  parked_decisions_reminders
}

main() {
  if [[ "$#" -lt 1 ]]; then
    usage
    exit 2
  fi
  local sub=$1
  shift
  case "$sub" in
    list)      cmd_list "$@" ;;
    add)       cmd_add "$@" ;;
    clear)     cmd_clear "$@" ;;
    reminders) cmd_reminders "$@" ;;
    -h|--help|help) usage; exit 0 ;;
    *) printf 'parked_decisions: unknown subcommand %q\n' "$sub" >&2; usage; exit 2 ;;
  esac
}

main "$@"
