#!/usr/bin/env bash
# recover.sh — re-dispatch an agent whose pane died or got stuck.
#
# Behavior:
#   1. Verify the agent's tmux session exists; if not, recreate it
#      (respawn-pane in the right working dir with `claude`).
#   2. If the agent had an active assignment but no progress in the pane,
#      re-send the dispatch brief.
#   3. Optional: --reset-state clears the assignment so cycle.sh treats
#      the agent as free again.
#
# Inspired by Overstory's --recover flag.
#
# Usage:
#   source examples/<project>.config.sh
#   bash scripts/recover.sh <agent> [--reset-state]

set -euo pipefail
TK="${TK:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# shellcheck disable=SC1091
source "$TK/lib/dry_run.sh"
# shellcheck disable=SC1091
source "$TK/lib/audit_log.sh"
# shellcheck disable=SC1091
source "$TK/lib/tmux_helpers.sh"
# shellcheck disable=SC1091
source "$TK/lib/state_persist.sh"
# shellcheck disable=SC1091
source "$TK/lib/worktree_helpers.sh"

dry_run_parse_args "$@"
set -- "${DRY_RUN_ARGS[@]}"

agent=${1:?usage: recover.sh <agent> [--reset-state] [--dry-run]}
reset_state=false
shift
while [[ $# -gt 0 ]]; do
  case $1 in
    --reset-state) reset_state=true; shift;;
    *) die "unknown arg: $1";;
  esac
done

session="${AGENT_SESSION_PREFIX}${agent}"
target=$(agent_target "$agent")
issue=$(state_get assignments | jq -r --arg a "$agent" '.[$a].issue // ""')
workdir=$(state_get assignments | jq -r --arg a "$agent" '.[$a].workdir // ""')
if [[ -z "$workdir" || "$workdir" == "null" ]]; then
  workdir=$(agent_effective_workdir "$agent")
fi
if worktree_enabled && [[ -n "$issue" && "$issue" != "null" ]] && [[ ! -d "$workdir" ]]; then
  workdir=$(worktree_create "$agent" "$issue")
fi

audit "RECOVER agent=$agent session=$session workdir=$workdir reset_state=$reset_state"

if ! tmux has-session -t "$session" 2>/dev/null; then
  audit "RECOVER tmux session missing — creating $session"
  launch_cmd=$(agent_launch_command "$target")
  dry_run_exec "tmux new-session -d -s $session -c $workdir $launch_cmd" \
    tmux new-session -d -s "$session" -c "$workdir" "$launch_cmd"
  if ! dry_run_enabled; then
    sleep 3
  fi
fi

if [[ "$reset_state" == "true" ]]; then
  if dry_run_enabled; then
    dry_run_note "state_update assignments del(.\"$agent\")"
  else
    state_update assignments ". | del(.\"$agent\")"
  fi
  audit "RECOVER cleared assignment for $agent"
  exit 0
fi

# Re-dispatch if there's an open assignment
if [[ -n "$issue" && "$issue" != "null" ]]; then
  audit "RECOVER re-dispatching agent=$agent ticket=#$issue"
  prompt_file=$(state_get assignments | jq -r --arg a "$agent" '.[$a].prompt_file // ""')
  if [[ -z "$prompt_file" || "$prompt_file" == "null" ]]; then
    prompt_file="/tmp/dispatch-${agent}-${issue}.md"
  fi
  if [[ ! -f "$prompt_file" ]]; then
    audit "RECOVER prompt missing for agent=$agent ticket=#$issue path=$prompt_file"
    exit 1
  fi

  dispatch_args=("$PROJECT" "$agent" "$issue" "$prompt_file")
  if dry_run_enabled; then
    dispatch_args+=(--dry-run)
  fi
  bash "$TK/scripts/dispatch_ticket.sh" "${dispatch_args[@]}"
else
  audit "RECOVER agent=$agent has no active assignment, just verified pane alive"
fi
