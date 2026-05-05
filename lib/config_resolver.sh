#!/usr/bin/env bash
# config_resolver.sh — shared project config + agent login resolution.

_ORCH_CFG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_ORCH_CFG_ROOT="$(cd "$_ORCH_CFG_DIR/.." && pwd)"
_ORCH_CFG_EXAMPLES="$_ORCH_CFG_ROOT/examples"

config_arg_is_explicit() {
  local raw=${1:-}
  [[ -n "$raw" ]] || return 1

  case "$raw" in
    */*|*.config.sh)
      return 0
      ;;
  esac

  [[ -f "$raw" ]] && return 0
  [[ -f "$_ORCH_CFG_ROOT/$raw" ]] && return 0
  [[ -f "$_ORCH_CFG_EXAMPLES/$raw" ]] && return 0
  [[ -f "$_ORCH_CFG_EXAMPLES/$raw.config.sh" ]] && return 0
  return 1
}

resolve_config_path() {
  local raw=${1:?usage: resolve_config_path <project_short|config_path>}
  local -a candidates=()
  local candidate

  case "$raw" in
    wp)
      candidates+=("$_ORCH_CFG_EXAMPLES/realisons-wp.config.sh")
      ;;
    42t|42-training)
      candidates+=("$_ORCH_CFG_EXAMPLES/42t.config.sh")
      ;;
  esac

  candidates+=(
    "$raw"
    "$_ORCH_CFG_ROOT/$raw"
    "$_ORCH_CFG_EXAMPLES/$raw"
    "$_ORCH_CFG_EXAMPLES/$raw.config.sh"
  )

  if [[ "$raw" == *.config.sh ]]; then
    candidates+=("$_ORCH_CFG_EXAMPLES/$raw")
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

resolve_agent_github_login() {
  local agent=${1:?usage: resolve_agent_github_login <agent-label>}
  local entry key value

  if [[ -n "${AGENT_GH_LOGINS+x}" && "${#AGENT_GH_LOGINS[@]}" -gt 0 ]]; then
    for entry in "${AGENT_GH_LOGINS[@]}"; do
      case "$entry" in
        *=*)
          key=${entry%%=*}
          value=${entry#*=}
          ;;
        *'|'*)
          key=${entry%%|*}
          value=${entry#*|}
          ;;
        *)
          continue
          ;;
      esac

      if [[ "$key" == "$agent" ]]; then
        printf '%s\n' "$value"
        return 0
      fi
    done
  fi

  if [[ -n "${AGENT_GH_LOGIN_PREFIX:-}" ]]; then
    printf '%s%s\n' "$AGENT_GH_LOGIN_PREFIX" "$agent"
    return 0
  fi

  printf 'RBOKCLI%s\n' "$agent"
}
