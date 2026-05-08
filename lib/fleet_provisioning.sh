#!/usr/bin/env bash
# fleet_provisioning.sh - generated-profile provisioning helpers.

if [[ -n "${ORDO_FLEET_PROVISIONING_LIB_LOADED:-}" ]]; then
  return 0
fi
ORDO_FLEET_PROVISIONING_LIB_LOADED=1

: "${ORDO_PROVISION_REFUSAL_EXIT_CODE:=78}"
: "${ORDO_PROVISION_AGENT_LABEL_TEMPLATE:=agent-%03d}"

fleet_provision_shell_quote() {
  printf '%q' "$1"
}

fleet_provision_truthy() {
  case "${1:-}" in
    1|yes|true|on|apply|enabled) return 0 ;;
    *) return 1 ;;
  esac
}

fleet_provision_uint_or_default() {
  local value=${1:-}
  local fallback=${2:?usage: fleet_provision_uint_or_default <value> <fallback>}
  if [[ "$value" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$value"
  else
    printf '%s\n' "$fallback"
  fi
}

fleet_provision_format_template() {
  local template=${1:?usage: fleet_provision_format_template <template> <label> <index>}
  local label=${2:?usage: fleet_provision_format_template <template> <label> <index>}
  local index=${3:?usage: fleet_provision_format_template <template> <label> <index>}

  if [[ "$template" == *"%s"* ]]; then
    # shellcheck disable=SC2059
    printf "$template" "$label"
  elif [[ "$template" == *"%03d"* || "$template" == *"%d"* ]]; then
    # shellcheck disable=SC2059
    printf "$template" "$index"
  else
    printf '%s\n' "$template"
  fi
}

fleet_provision_generated_label() {
  local index=${1:?usage: fleet_provision_generated_label <index>}
  # shellcheck disable=SC2059
  printf "$ORDO_PROVISION_AGENT_LABEL_TEMPLATE" "$index"
  printf '\n'
}

fleet_provision_roles_json() {
  local fleet_json=${1:?usage: fleet_provision_roles_json <fleet-json>}
  jq -c '
    def role_rows:
      (.recommendation.role_mix // .provisioning.role_mix // [])
      | map({role:(.role // "generalist"), count:(.count // 0)});
    [role_rows[] as $row | range(0; ($row.count | tonumber)) | $row.role]
  ' <<< "$fleet_json"
}

fleet_provision_profile_text() {
  local profile_json=${1:?usage: fleet_provision_profile_text <profile-json>}
  local repository default_branch bootstrap_workdir
  local label role workdir terminal_target identity

  repository=$(jq -r '.repository // ""' <<< "$profile_json")
  default_branch=$(jq -r '.default_branch // ""' <<< "$profile_json")
  bootstrap_workdir=$(jq -r '.bootstrap_workdir // ""' <<< "$profile_json")

  printf '# Generated ORDO fleet profile. Review before sourcing.\n'
  printf 'ORDO_GENERATED_PROFILE_SCHEMA=%s\n' "$(fleet_provision_shell_quote "ordo.generated_fleet_profile.v1")"
  printf 'ORDO_GENERATED_PROFILE_SOURCE=%s\n' "$(fleet_provision_shell_quote "fleet_provisioning")"
  if [[ -n "$default_branch" ]]; then
    printf 'DEFAULT_BRANCH=%s\n' "$(fleet_provision_shell_quote "$default_branch")"
  fi
  if [[ -n "$repository" ]]; then
    printf 'REPOSITORY_PLATFORM_REPOSITORY=%s\n' "$(fleet_provision_shell_quote "$repository")"
  fi
  if [[ -n "$bootstrap_workdir" ]]; then
    printf 'PROJECT_REPO_ROOT=%s\n' "$(fleet_provision_shell_quote "$bootstrap_workdir")"
    printf 'SUPERVISOR_REPO=%s\n' "$(fleet_provision_shell_quote "$bootstrap_workdir")"
  fi

  printf 'AGENT_PANES=(\n'
  while IFS=$'\t' read -r label role workdir terminal_target identity; do
    [[ -n "$label" ]] || continue
    printf '  %s\n' "$(fleet_provision_shell_quote "$label|$terminal_target|$workdir")"
  done < <(jq -r '.agents[] | [.label,.role,.workdir,.terminal_target,(.identity // "")] | @tsv' <<< "$profile_json")
  printf ')\n'

  printf 'AGENT_REPOSITORY_PLATFORM_IDENTITIES=(\n'
  while IFS=$'\t' read -r label role workdir terminal_target identity; do
    [[ -n "$label" && -n "$identity" ]] || continue
    printf '  %s\n' "$(fleet_provision_shell_quote "$label=$identity")"
  done < <(jq -r '.agents[] | [.label,.role,.workdir,.terminal_target,(.identity // "")] | @tsv' <<< "$profile_json")
  printf ')\n'

  printf 'ORDO_GENERATED_AGENT_ROLES=(\n'
  while IFS=$'\t' read -r label role _workdir _terminal_target _identity; do
    [[ -n "$label" ]] || continue
    printf '  %s\n' "$(fleet_provision_shell_quote "$label=$role")"
  done < <(jq -r '.agents[] | [.label,.role,.workdir,.terminal_target,(.identity // "")] | @tsv' <<< "$profile_json")
  printf ')\n'
}
