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
source "$TK/lib/audit_log.sh"
# shellcheck disable=SC1091
source "$TK/lib/tmux_helpers.sh"
# shellcheck disable=SC1091
source "$TK/lib/state_persist.sh"

agent=${1:?usage: recover.sh <agent> [--reset-state]}
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
workdir=$(printf "$AGENT_WORKDIR_TEMPLATE" "$agent")

audit "RECOVER agent=$agent session=$session workdir=$workdir reset_state=$reset_state"

if ! tmux has-session -t "$session" 2>/dev/null; then
  audit "RECOVER tmux session missing — creating $session"
  tmux new-session -d -s "$session" -c "$workdir" "bash -lc claude"
  sleep 3
fi

if [[ "$reset_state" == "true" ]]; then
  state_update assignments ". | del(.\"$agent\")"
  audit "RECOVER cleared assignment for $agent"
  exit 0
fi

# Re-dispatch if there's an open assignment
issue=$(state_get assignments | jq -r --arg a "$agent" '.[$a].issue // ""')
if [[ -n "$issue" && "$issue" != "null" ]]; then
  audit "RECOVER re-dispatching agent=$agent ticket=#$issue"
  bash "$TK/scripts/dispatch_ticket.sh" "$agent" "$issue"
else
  audit "RECOVER agent=$agent has no active assignment, just verified pane alive"
fi
