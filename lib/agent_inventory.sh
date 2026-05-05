#!/usr/bin/env bash
# agent_inventory.sh — unified fleet resolution for explicit labels and legacy configs.

agent_inventory_entries() {
  local entry label pane workdir remainder

  if [[ -n "${AGENT_PANES+x}" && "${#AGENT_PANES[@]}" -gt 0 ]]; then
    for entry in "${AGENT_PANES[@]}"; do
      IFS='|' read -r label pane workdir remainder <<< "$entry"
      if [[ -n "$remainder" ]]; then
        printf 'AGENT_PANES entry malformed (too many fields): %s\n' "$entry" >&2
        return 1
      fi

      if [[ -n "$workdir" ]]; then
        :
      elif [[ -n "$pane" ]]; then
        workdir=$pane
        pane=$label
        label=$(basename "$workdir")
      else
        printf 'AGENT_PANES entry malformed (need \"pane|workdir\" or \"label|pane|workdir\"): %s\n' "$entry" >&2
        return 1
      fi

      printf '%s|%s|%s\n' "$label" "$pane" "$workdir"
    done
    return 0
  fi

  [[ -n "${AGENTS+x}" && "${#AGENTS[@]}" -gt 0 ]] || return 1
  for label in "${AGENTS[@]}"; do
    if [[ -n "${AGENT_WORKDIR_TEMPLATE:-}" ]]; then
      # shellcheck disable=SC2059
      workdir=$(printf "$AGENT_WORKDIR_TEMPLATE" "$label")
    else
      workdir="${AGENT_REPO_PREFIX:-}${label}"
    fi
    pane="${AGENT_SESSION_PREFIX:-}${label}:${AGENT_WINDOW_INDEX:-0}.0"
    printf '%s|%s|%s\n' "$label" "$pane" "$workdir"
  done
}

agent_inventory_find() {
  local needle=${1:?usage: agent_inventory_find <label|pane|session|basename>}
  local label pane workdir

  while IFS='|' read -r label pane workdir; do
    if [[ "$needle" == "$label" || "$needle" == "$pane" || "$needle" == "${pane%%:*}" || "$needle" == "$(basename "$workdir")" ]]; then
      printf '%s|%s|%s\n' "$label" "$pane" "$workdir"
      return 0
    fi
  done < <(agent_inventory_entries)

  return 1
}
