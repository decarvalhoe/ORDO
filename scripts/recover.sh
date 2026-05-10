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
source "$TK/lib/config_resolver.sh"

recover_project_context_required() {
  printf 'recover.sh: project config required before agent recovery -- pass <project> first or set ORDO_PROJECT_PROFILE before sourcing examples/ordo.config.sh\n' >&2
  return 1
}

recover_source_env_profile_if_available() {
  [[ -z "${PROJECT:-}" ]] || return 0
  [[ -n "${ORDO_PROJECT_PROFILE:-}" ]] || return 0

  load_project_config "$ORDO_PROJECT_PROFILE" || return $?
  # The environment profile establishes context for the agent argument; it
  # was not itself consumed from argv, so the caller must not shift.
  ORCH_CONFIG_CONSUMED=0
}

recover_arg_is_configured_agent() {
  local raw=${1:-}
  local entry label pane workdir remainder workdir_basename
  [[ -n "$raw" ]] || return 1

  if [[ -n "${AGENT_PANES+x}" && "${#AGENT_PANES[@]}" -gt 0 ]]; then
    for entry in "${AGENT_PANES[@]}"; do
      IFS='|' read -r label pane workdir remainder <<< "$entry"

      if [[ -z "$workdir" && -n "$pane" ]]; then
        workdir=$pane
        pane=$label
        label=$(basename "$workdir")
      fi
      workdir_basename=""
      if [[ -n "$workdir" ]]; then
        workdir_basename=$(basename "$workdir")
      fi

      if [[ "$raw" == "$label" \
        || "$raw" == "$pane" \
        || "$raw" == "${pane%%:*}" \
        || ( -n "$workdir_basename" && "$raw" == "$workdir_basename" ) ]]; then
        return 0
      fi
    done
  fi

  if [[ -n "${AGENTS+x}" && "${#AGENTS[@]}" -gt 0 ]]; then
    for label in "${AGENTS[@]}"; do
      [[ "$raw" == "$label" ]] && return 0
    done
  fi

  return 1
}

recover_maybe_load_project_config() {
  local raw=${1:-}
  local cfg
  ORCH_CONFIG_CONSUMED=0

  recover_source_env_profile_if_available || return $?

  if [[ -z "$raw" ]]; then
    [[ -n "${PROJECT:-}" ]] || recover_project_context_required
    return $?
  fi

  if [[ -n "${PROJECT:-}" ]] && recover_arg_is_configured_agent "$raw"; then
    return 0
  fi

  if [[ -z "${PROJECT:-}" ]]; then
    if cfg=$(resolve_config_path "$raw" 2>/dev/null); then
      _source_resolved_config "$cfg"
      ORCH_CONFIG_CONSUMED=1
      return 0
    fi

    recover_project_context_required
    return 1
  fi

  maybe_load_project_config "$raw"
}

dry_run_parse_args "$@"
set -- "${DRY_RUN_ARGS[@]}"

recover_maybe_load_project_config "${1:-}"
if [[ "${ORCH_CONFIG_CONSUMED:-0}" == "1" ]]; then
  shift
fi

# shellcheck disable=SC1091
source "$TK/lib/audit_log.sh"
# shellcheck disable=SC1091
source "$TK/lib/tmux_helpers.sh"
# shellcheck disable=SC1091
source "$TK/lib/state_persist.sh"
# shellcheck disable=SC1091
source "$TK/lib/worktree_helpers.sh"

agent=${1:?usage: recover.sh <agent> [--reset-state] [--dry-run]}
reset_state=false
shift
while [[ $# -gt 0 ]]; do
  case $1 in
    --reset-state) reset_state=true; shift;;
    *) die "unknown arg: $1";;
  esac
done

target=$(agent_target "$agent")
# Strip the :window.pane suffix — tmux has-session / new-session expect a
# bare session name. agent_target now returns the full target so dispatch
# / send-keys hit the right pane in universal mode.
session="${target%%:*}"
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
