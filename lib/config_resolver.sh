#!/usr/bin/env bash
# config_resolver.sh — shared project config + agent login resolution.

_ORCH_CFG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_ORCH_CFG_ROOT="$(cd "$_ORCH_CFG_DIR/.." && pwd)"
_ORCH_CFG_EXAMPLES="$_ORCH_CFG_ROOT/examples"

_orch_operator_config_dirs() {
  local xdg_config_home=${XDG_CONFIG_HOME:-}
  local home=${HOME:-}

  if [[ -n "${ORCH_CONFIG_DIR:-}" ]]; then
    printf '%s\n' "$ORCH_CONFIG_DIR"
  fi
  if [[ -n "${ORCH_CONFIG_HOME:-}" ]]; then
    printf '%s\n' "$ORCH_CONFIG_HOME"
  fi
  if [[ -n "$xdg_config_home" ]]; then
    printf '%s\n' "$xdg_config_home/ordo"
  fi
  if [[ -n "$home" ]]; then
    printf '%s\n' "$home/.config/ordo"
  fi
}

_orch_config_add_unique() {
  local candidate=${1:-}
  local array_name=${2:?usage: _orch_config_add_unique <candidate> <array-name>}
  local existing
  local -n candidates_ref=$array_name

  [[ -n "$candidate" ]] || return 0
  for existing in "${candidates_ref[@]}"; do
    [[ "$existing" == "$candidate" ]] && return 0
  done
  candidates_ref+=("$candidate")
}

config_arg_is_explicit() {
  local raw=${1:-}
  local operator_dir
  [[ -n "$raw" ]] || return 1

  case "$raw" in
    */*|*.config.sh)
      return 0
      ;;
  esac

  [[ -f "$raw" ]] && return 0
  [[ -f "$_ORCH_CFG_ROOT/$raw" ]] && return 0
  while IFS= read -r operator_dir; do
    [[ -n "$operator_dir" ]] || continue
    [[ -f "$operator_dir/$raw" ]] && return 0
    [[ -f "$operator_dir/$raw.config.sh" ]] && return 0
  done < <(_orch_operator_config_dirs)
  [[ -f "$_ORCH_CFG_EXAMPLES/$raw" ]] && return 0
  [[ -f "$_ORCH_CFG_EXAMPLES/$raw.config.sh" ]] && return 0
  return 1
}

resolve_config_path() {
  local raw=${1:?usage: resolve_config_path <project_short|config_path>}
  local -a candidates=()
  local candidate operator_dir

  case "$raw" in
    wp)
      _orch_config_add_unique "$_ORCH_CFG_EXAMPLES/web.config.sh" candidates
      ;;
    42t|42-training)
      _orch_config_add_unique "$_ORCH_CFG_EXAMPLES/42t.config.sh" candidates
      ;;
  esac

  _orch_config_add_unique "$raw" candidates
  _orch_config_add_unique "$_ORCH_CFG_ROOT/$raw" candidates

  if [[ "$raw" != */* ]]; then
    while IFS= read -r operator_dir; do
      [[ -n "$operator_dir" ]] || continue
      _orch_config_add_unique "$operator_dir/$raw" candidates
      _orch_config_add_unique "$operator_dir/$raw.config.sh" candidates
    done < <(_orch_operator_config_dirs)
  fi

  _orch_config_add_unique "$_ORCH_CFG_EXAMPLES/$raw" candidates
  _orch_config_add_unique "$_ORCH_CFG_EXAMPLES/$raw.config.sh" candidates

  if [[ "$raw" == *.config.sh ]]; then
    _orch_config_add_unique "$_ORCH_CFG_EXAMPLES/$raw" candidates
  fi

  for candidate in "${candidates[@]}"; do
    if [[ -f "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  printf 'config not found: %s\n' "$raw" >&2
  return 1
}

_source_resolved_config() {
  local cfg=${1:?usage: _source_resolved_config <config-path>}
  # shellcheck disable=SC1090
  source "$cfg"
  # shellcheck disable=SC2034
  ORCH_CONFIG_PATH="$cfg"
}

load_project_config() {
  local raw=${1:-}
  local cfg
  ORCH_CONFIG_CONSUMED=0

  if [[ -z "$raw" ]]; then
    [[ -n "${PROJECT:-}" ]] || {
      printf 'project config required\n' >&2
      return 1
    }
    return 0
  fi

  cfg=$(resolve_config_path "$raw")
  _source_resolved_config "$cfg"
  # shellcheck disable=SC2034
  ORCH_CONFIG_CONSUMED=1
}

maybe_load_project_config() {
  local raw=${1:-}
  local cfg
  ORCH_CONFIG_CONSUMED=0

  if [[ -z "$raw" ]]; then
    [[ -n "${PROJECT:-}" ]] || {
      printf 'project config required\n' >&2
      return 1
    }
    return 0
  fi

  if [[ -n "${PROJECT:-}" ]] && ! config_arg_is_explicit "$raw"; then
    return 0
  fi

  if cfg=$(resolve_config_path "$raw" 2>/dev/null); then
    _source_resolved_config "$cfg"
    # shellcheck disable=SC2034
    ORCH_CONFIG_CONSUMED=1
    return 0
  fi

  if [[ -n "${PROJECT:-}" ]]; then
    return 0
  fi

  printf 'config not found: %s\n' "$raw" >&2
  return 1
}

_orch_agent_candidate_add() {
  local value=${1:-}
  local array_name=${2:?usage: _orch_agent_candidate_add <value> <array-name>}
  local existing
  local -n values_ref=$array_name

  [[ -n "$value" ]] || return 0
  for existing in "${values_ref[@]}"; do
    [[ "$existing" == "$value" ]] && return 0
  done
  values_ref+=("$value")
}

_orch_config_key_value() {
  local entry=${1:-}
  case "$entry" in
    *=*)
      printf '%s|%s\n' "${entry%%=*}" "${entry#*=}"
      ;;
    *'|'*)
      printf '%s|%s\n' "${entry%%|*}" "${entry#*|}"
      ;;
    *)
      return 1
      ;;
  esac
}

agent_github_label_candidates() {
  local agent=${1:?usage: agent_github_label_candidates <agent-label>}
  local entry key value prefix stripped candidate delimiter
  local -a candidates=()

  _orch_agent_candidate_add "$agent" candidates

  if [[ -n "${AGENT_GH_LABEL_ALIASES+x}" && "${#AGENT_GH_LABEL_ALIASES[@]}" -gt 0 ]]; then
    for entry in "${AGENT_GH_LABEL_ALIASES[@]}"; do
      IFS='|' read -r key value <<< "$(_orch_config_key_value "$entry" || true)"
      [[ -n "$key$value" ]] || continue
      if [[ "$key" == "$agent" ]]; then
        _orch_agent_candidate_add "$value" candidates
      fi
    done
  fi

  if [[ -n "${AGENT_GH_LABEL_PREFIXES+x}" && "${#AGENT_GH_LABEL_PREFIXES[@]}" -gt 0 ]]; then
    for prefix in "${AGENT_GH_LABEL_PREFIXES[@]}"; do
      [[ -n "$prefix" ]] || continue
      if [[ "$agent" == "$prefix"* ]]; then
        stripped=${agent#"$prefix"}
        _orch_agent_candidate_add "$stripped" candidates
      fi
    done
  fi

  for delimiter in - _ / :; do
    candidate=$agent
    while [[ "$candidate" == *"$delimiter"* ]]; do
      candidate=${candidate#*"$delimiter"}
      _orch_agent_candidate_add "$candidate" candidates
    done
  done

  printf '%s\n' "${candidates[@]}"
}

_orch_agent_login_mapping_lookup() {
  local needle=${1:?usage: _orch_agent_login_mapping_lookup <label>}
  local entry key value

  if [[ -n "${AGENT_GH_LOGINS+x}" && "${#AGENT_GH_LOGINS[@]}" -gt 0 ]]; then
    for entry in "${AGENT_GH_LOGINS[@]}"; do
      IFS='|' read -r key value <<< "$(_orch_config_key_value "$entry" || true)"
      [[ -n "$key$value" ]] || continue

      if [[ "$key" == "$needle" ]]; then
        printf '%s\n' "$value"
        return 0
      fi
    done
  fi

  return 1
}

resolve_agent_github_login() {
  local agent=${1:?usage: resolve_agent_github_login <agent-label>}
  local candidate login_label
  local -a candidates=()

  mapfile -t candidates < <(agent_github_label_candidates "$agent")

  for candidate in "${candidates[@]}"; do
    if _orch_agent_login_mapping_lookup "$candidate"; then
      return 0
    fi
  done

  login_label=${candidates[1]:-${candidates[0]:-$agent}}
  if [[ -n "${AGENT_GH_LOGIN_PREFIX:-}" ]]; then
    printf '%s%s\n' "$AGENT_GH_LOGIN_PREFIX" "$login_label"
    return 0
  fi

  if [[ -n "${AGENT_GH_LOGIN_FALLBACK_TEMPLATE:-}" ]]; then
    # shellcheck disable=SC2059
    printf "$AGENT_GH_LOGIN_FALLBACK_TEMPLATE" "$login_label"
    printf '\n'
    return 0
  fi

  printf '%s\n' "$agent"
}
