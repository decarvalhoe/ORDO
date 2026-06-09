#!/usr/bin/env bash
# scripts/pr_ops_controller.sh — centralized PR operations controller
# (#357 / #360).
#
# Universal entry point that authorizes (or refuses) a PR-mutating
# action against the project's PR ops mode. The controller does NOT
# execute the underlying gh / git mutation itself — it produces an
# auditable JSON decision and returns the policy exit code so the
# caller (orchestrator pane, CI step, downstream automation) can
# decide whether to proceed or stop. Subsequent issues in the #357
# epic wire actual mutation hooks on top of this contract.
#
# Usage:
#   pr_ops_controller.sh <project-config> <action> <pr-number>
#       [--gates <csv>]      gates already verified by caller
#       [--override <reason>] explicit operator override (must be
#                            allowed by profile via
#                            ORDO_PR_OPS_OVERRIDE_ENABLED=1)
#       [--actor <name>]     overrides ORDO_PR_OPS_ACTOR for this run
#       [--ledger <path>]    appends decision to a JSON-array ledger
#       [--dry-run]
#
# Exit codes (mirrored from lib/pr_ops_mode.sh):
#   0  decision=allowed
#   2  invalid action / mode / argument
#   90 unauthorized actor for the current mode
#   91 required policy gate not satisfied
#   92 operator override attempted while profile disables override
set -euo pipefail
TK=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

source "$TK/lib/dry_run.sh"
source "$TK/lib/config_resolver.sh"
source "$TK/lib/pr_ops_mode.sh"

dry_run_parse_args "$@"
set -- "${DRY_RUN_ARGS[@]}"

CFG_ARG=${1:?usage: pr_ops_controller.sh <project-config> <action> <pr-number> [opts]}
ACTION=${2:?usage: pr_ops_controller.sh <project-config> <action> <pr-number> [opts]}
PR=${3:?usage: pr_ops_controller.sh <project-config> <action> <pr-number> [opts]}
shift 3

GATES_PASSED=""
OVERRIDE_REASON=""
ACTOR_OVERRIDE=""
LEDGER_PATH="${ORDO_PR_OPS_LEDGER_PATH:-}"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --gates)
      GATES_PASSED=${2:?missing value for --gates}
      shift
      ;;
    --gates=*) GATES_PASSED=${1#--gates=} ;;
    --override)
      OVERRIDE_REASON=${2:?missing value for --override}
      shift
      ;;
    --override=*) OVERRIDE_REASON=${1#--override=} ;;
    --actor)
      ACTOR_OVERRIDE=${2:?missing value for --actor}
      shift
      ;;
    --actor=*) ACTOR_OVERRIDE=${1#--actor=} ;;
    --ledger)
      LEDGER_PATH=${2:?missing value for --ledger}
      shift
      ;;
    --ledger=*) LEDGER_PATH=${1#--ledger=} ;;
    --) shift; break ;;
    *)
      echo "unknown arg: $1" >&2
      exit 2
      ;;
  esac
  shift
done

load_project_config "$CFG_ARG"

source "$TK/lib/audit_log.sh"

if [ -n "$ACTOR_OVERRIDE" ]; then
  export ORDO_PR_OPS_ACTOR="$ACTOR_OVERRIDE"
fi

decision_json=""
rc=0
set +e
decision_json=$(pr_ops_check_authorization "$ACTION" "$GATES_PASSED" "$OVERRIDE_REASON")
rc=$?
set -e

# Augment the decision payload with PR + project context + a
# stable timestamp so the ledger entry stands on its own.
decision_json=$(printf '%s' "$decision_json" | jq -c \
  --arg pr "$PR" \
  --arg project "${PROJECT:-}" \
  --arg decided_at "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
  '
    . + {pr: $pr, project: $project, decided_at: $decided_at}
    | if .escalation == null then
        .
      else
        .escalation.project = $project
        | .escalation.pr = $pr
        | .escalation.dedupe_key = (
            "pr_ops:" + $project + ":pr:" + $pr + ":" + .action + ":" + .reason
          )
      end
  ')

printf '%s\n' "$decision_json"

decision_status=$(printf '%s' "$decision_json" | jq -r '.decision // "unknown"')
decision_reason=$(printf '%s' "$decision_json" | jq -r '.reason // "unknown"')
decision_mode=$(printf '%s' "$decision_json" | jq -r '.mode // "unknown"')
decision_actor=$(printf '%s' "$decision_json" | jq -r '.actor // "unknown"')

audit "PR_OPS_CONTROLLER project=${PROJECT:-} action=$ACTION pr=#$PR mode=$decision_mode actor=$decision_actor decision=$decision_status reason=$decision_reason"

if [ -n "$LEDGER_PATH" ]; then
  if dry_run_enabled; then
    dry_run_note "append decision to ledger $LEDGER_PATH"
  else
    mkdir -p "$(dirname "$LEDGER_PATH")"
    tmp="${LEDGER_PATH}.tmp.$$"
    if [ -s "$LEDGER_PATH" ]; then
      jq -c --argjson entry "$decision_json" '. + [$entry]' "$LEDGER_PATH" > "$tmp"
    else
      printf '%s\n' "[$decision_json]" | jq -c '.' > "$tmp"
    fi
    mv "$tmp" "$LEDGER_PATH"
  fi
fi

exit "$rc"
