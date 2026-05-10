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
# shellcheck disable=SC1091
source "$TK/lib/prompt_integrity.sh"

recover_normalize_path() {
  local path=${1:?usage: recover_normalize_path <path>}
  local parent base resolved

  if [[ -e "$path" ]]; then
    readlink -f -- "$path" 2>/dev/null || printf '%s\n' "${path%/}"
    return 0
  fi

  parent=$(dirname -- "$path")
  base=$(basename -- "$path")
  if [[ -e "$parent" ]]; then
    resolved=$(readlink -f -- "$parent" 2>/dev/null || printf '%s' "$parent")
    printf '%s/%s\n' "${resolved%/}" "$base"
    return 0
  fi

  printf '%s\n' "${path%/}"
}

recover_paths_equal() {
  local left=${1:?usage: recover_paths_equal <left> <right>}
  local right=${2:?usage: recover_paths_equal <left> <right>}
  local normalized_left normalized_right

  normalized_left=$(recover_normalize_path "$left")
  normalized_right=$(recover_normalize_path "$right")
  [[ "${normalized_left%/}" == "${normalized_right%/}" ]]
}

recover_same_assignment_rehydrate() {
  local agent=${1:?usage: recover_same_assignment_rehydrate <agent> <issue> <workdir> <prompt-file> <target>}
  local issue=${2:?usage: recover_same_assignment_rehydrate <agent> <issue> <workdir> <prompt-file> <target>}
  local workdir=${3:?usage: recover_same_assignment_rehydrate <agent> <issue> <workdir> <prompt-file> <target>}
  local prompt_file=${4:?usage: recover_same_assignment_rehydrate <agent> <issue> <workdir> <prompt-file> <target>}
  local target=${5:?usage: recover_same_assignment_rehydrate <agent> <issue> <workdir> <prompt-file> <target>}
  local live_pane_cwd occupied_assignment occupied_project occupied_agent occupied_issue occupied_workdir
  local oneliner

  live_pane_cwd=$(tmux_pane_current_path "$target" 2>/dev/null) || return 1
  [[ -n "$live_pane_cwd" ]] || return 1
  occupied_assignment=$(worktree_active_assignment_for_path "$live_pane_cwd" 2>/dev/null) || return 1
  IFS=$'\t' read -r occupied_project occupied_agent occupied_issue occupied_workdir <<< "$occupied_assignment"

  [[ "$occupied_project" == "$PROJECT" ]] || return 1
  [[ "$occupied_agent" == "$agent" ]] || return 1
  [[ "$occupied_issue" == "$issue" ]] || return 1
  recover_paths_equal "$occupied_workdir" "$workdir" || return 1
  recover_paths_equal "$live_pane_cwd" "$workdir" || return 1

  if ! validate_prompt_integrity "$prompt_file"; then
    audit "RECOVER SAME_ASSIGNMENT_REHYDRATE_REFUSED agent=$agent ticket=#$issue pane=$target workdir=$workdir prompt=$prompt_file reason=prompt_integrity"
    return 2
  fi

  audit "RECOVER SAME_ASSIGNMENT_REHYDRATE agent=$agent ticket=#$issue pane=$target workdir=$workdir prompt=$prompt_file"
  oneliner="Read $prompt_file and execute it end-to-end. Stay strictly in scope. Verify your git identity matches the agent name before commit. Report final status."

  if dry_run_enabled; then
    dry_run_note "tmux load-buffer -b orch_send <recover-dispatch-text>"
    dry_run_note "tmux paste-buffer -b orch_send -t $target -d"
    dry_run_note "tmux send-keys -t $target Enter"
    return 0
  fi

  if ! terminal_dispatch_submit "$target" "$oneliner"; then
    audit "RECOVER SAME_ASSIGNMENT_REHYDRATE_FAILED agent=$agent ticket=#$issue pane=$target reason=${DISPATCH_SUBMIT_LAST_REASON:-not-consumed} attempts=${DISPATCH_SUBMIT_ATTEMPT:-0}"
    printf 'recover-rehydrate-not-consumed: agent=%s ticket=#%s pane=%s reason=%s detail=%s\n' \
      "$agent" "$issue" "$target" \
      "${DISPATCH_SUBMIT_LAST_REASON:-not-consumed}" \
      "${DISPATCH_SUBMIT_LAST_DETAIL:-}" >&2
    return "${ORCH_DISPATCH_NOT_CONSUMED_EXIT_CODE:-79}"
  fi

  audit "RECOVER SAME_ASSIGNMENT_REHYDRATE_OK agent=$agent ticket=#$issue pane=$target attempts=${DISPATCH_SUBMIT_ATTEMPT:-1}"
  return 0
}

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

  rehydrate_rc=0
  if recover_same_assignment_rehydrate "$agent" "$issue" "$workdir" "$prompt_file" "$target"; then
    exit 0
  else
    rehydrate_rc=$?
    if [[ "$rehydrate_rc" -ne 1 ]]; then
      exit "$rehydrate_rc"
    fi
  fi

  dispatch_args=("$PROJECT" "$agent" "$issue" "$prompt_file")
  if dry_run_enabled; then
    dispatch_args+=(--dry-run)
  fi
  bash "$TK/scripts/dispatch_ticket.sh" "${dispatch_args[@]}"
else
  audit "RECOVER agent=$agent has no active assignment, just verified pane alive"
fi
