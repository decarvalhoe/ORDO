#!/usr/bin/env bash
# repository_platform.sh — generic repository-platform readiness helpers.

repository_platform_repo_identifier() {
  printf '%s\n' "${REPOSITORY_PLATFORM_REPOSITORY:-${REPOSITORY_PLATFORM_REPO:-}}"
}

repository_platform_config_dir() {
  printf '%s\n' "${REPOSITORY_PLATFORM_CONFIG_DIR:-}"
}

repository_platform_cli_bin() {
  local configured=${REPOSITORY_PLATFORM_CLI_BIN:-${ORCH_REPOSITORY_PLATFORM_CLI_BIN:-}}
  if [[ -n "$configured" ]]; then
    printf '%s\n' "$configured"
    return 0
  fi
  return 1
}

repository_platform_expected_identity() {
  printf '%s\n' "${REPOSITORY_PLATFORM_EXPECTED_IDENTITY:-${ORCH_EXPECTED_REPOSITORY_PLATFORM_IDENTITY:-}}"
}

repository_platform_run() {
  local timeout_sec=${REPOSITORY_PLATFORM_TIMEOUT_SEC:-${ORCH_REPOSITORY_PLATFORM_TIMEOUT_SEC:-5}}
  local cli_bin config_dir
  local -a env_args=()

  cli_bin=$(repository_platform_cli_bin) || return 127
  config_dir=$(repository_platform_config_dir)
  if [[ -n "$config_dir" ]]; then
    env_args+=("REPOSITORY_PLATFORM_CONFIG_DIR=$config_dir")
  fi

  if declare -F orch_run_timeout >/dev/null 2>&1; then
    orch_run_timeout "$timeout_sec" env "${env_args[@]}" "$cli_bin" "$@"
  else
    env "${env_args[@]}" "$cli_bin" "$@"
  fi
}

repository_platform_active_identity() {
  repository_platform_run identity current
}

repository_platform_repo_metadata() {
  local repo=${1:?usage: repository_platform_repo_metadata <repo>}
  repository_platform_run repository metadata "$repo"
}

repository_platform_ci_status_visible() {
  local repo=${1:?usage: repository_platform_ci_status_visible <repo>}
  repository_platform_run ci status-check "$repo" >/dev/null
}

repository_platform_pr_review_capable() {
  local repo=${1:?usage: repository_platform_pr_review_capable <repo> <identity>}
  local identity=${2:?usage: repository_platform_pr_review_capable <repo> <identity>}
  repository_platform_run pull-request review-check "$repo" "$identity" >/dev/null
}

repository_platform_issue_assignment_capable() {
  local repo=${1:?usage: repository_platform_issue_assignment_capable <repo> <identity>}
  local identity=${2:?usage: repository_platform_issue_assignment_capable <repo> <identity>}
  repository_platform_run issue assignment-check "$repo" "$identity" >/dev/null
}

repository_platform_permission_allows_write() {
  local permission=${1:-}
  permission=${permission^^}
  case "$permission" in
    ADMIN|MAINTAIN|MAINTAINER|WRITE|OWNER)
      return 0
      ;;
  esac
  return 1
}

_repository_platform_key_value() {
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

_repository_platform_candidate_add() {
  local value=${1:-}
  local array_name=${2:?usage: _repository_platform_candidate_add <value> <array-name>}
  local existing
  local -n values_ref=$array_name

  [[ -n "$value" ]] || return 0
  for existing in "${values_ref[@]}"; do
    [[ "$existing" == "$value" ]] && return 0
  done
  values_ref+=("$value")
}

repository_platform_label_candidates() {
  local agent=${1:?usage: repository_platform_label_candidates <agent-label>}
  local entry key value prefix stripped candidate delimiter
  local -a candidates=()

  _repository_platform_candidate_add "$agent" candidates

  if [[ -n "${AGENT_REPOSITORY_PLATFORM_LABEL_ALIASES+x}" && "${#AGENT_REPOSITORY_PLATFORM_LABEL_ALIASES[@]}" -gt 0 ]]; then
    for entry in "${AGENT_REPOSITORY_PLATFORM_LABEL_ALIASES[@]}"; do
      IFS='|' read -r key value <<< "$(_repository_platform_key_value "$entry" || true)"
      [[ -n "$key$value" ]] || continue
      if [[ "$key" == "$agent" ]]; then
        _repository_platform_candidate_add "$value" candidates
      fi
    done
  fi

  if [[ -n "${AGENT_REPOSITORY_PLATFORM_LABEL_PREFIXES+x}" && "${#AGENT_REPOSITORY_PLATFORM_LABEL_PREFIXES[@]}" -gt 0 ]]; then
    for prefix in "${AGENT_REPOSITORY_PLATFORM_LABEL_PREFIXES[@]}"; do
      [[ -n "$prefix" ]] || continue
      if [[ "$agent" == "$prefix"* ]]; then
        stripped=${agent#"$prefix"}
        _repository_platform_candidate_add "$stripped" candidates
      fi
    done
  fi

  for delimiter in - _ / :; do
    candidate=$agent
    while [[ "$candidate" == *"$delimiter"* ]]; do
      candidate=${candidate#*"$delimiter"}
      _repository_platform_candidate_add "$candidate" candidates
    done
  done

  printf '%s\n' "${candidates[@]}"
}

_repository_platform_identity_mapping_lookup() {
  local needle=${1:?usage: _repository_platform_identity_mapping_lookup <label>}
  local entry key value

  if [[ -n "${AGENT_REPOSITORY_PLATFORM_IDENTITIES+x}" && "${#AGENT_REPOSITORY_PLATFORM_IDENTITIES[@]}" -gt 0 ]]; then
    for entry in "${AGENT_REPOSITORY_PLATFORM_IDENTITIES[@]}"; do
      IFS='|' read -r key value <<< "$(_repository_platform_key_value "$entry" || true)"
      [[ -n "$key$value" ]] || continue
      if [[ "$key" == "$needle" ]]; then
        printf '%s\n' "$value"
        return 0
      fi
    done
  fi

  return 1
}

resolve_agent_repository_platform_identity() {
  local agent=${1:?usage: resolve_agent_repository_platform_identity <agent-label>}
  local candidate identity_label
  local -a candidates=()

  mapfile -t candidates < <(repository_platform_label_candidates "$agent")
  for candidate in "${candidates[@]}"; do
    if _repository_platform_identity_mapping_lookup "$candidate"; then
      return 0
    fi
  done

  identity_label=${candidates[1]:-${candidates[0]:-$agent}}
  if [[ -n "${AGENT_REPOSITORY_PLATFORM_IDENTITY_PREFIX:-}" ]]; then
    printf '%s%s\n' "$AGENT_REPOSITORY_PLATFORM_IDENTITY_PREFIX" "$identity_label"
    return 0
  fi

  if [[ -n "${AGENT_REPOSITORY_PLATFORM_IDENTITY_FALLBACK_TEMPLATE:-}" ]]; then
    # shellcheck disable=SC2059
    printf "$AGENT_REPOSITORY_PLATFORM_IDENTITY_FALLBACK_TEMPLATE" "$identity_label"
    printf '\n'
    return 0
  fi

  printf '%s\n' "$agent"
}
