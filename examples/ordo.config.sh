#!/usr/bin/env bash
# examples/ordo.config.sh - dogfooding config loader.
#
# Keep live repository names, tmux labels, host paths, and credentials outside
# the repository. Point ORDO_PROJECT_PROFILE at an operator-owned config file
# that defines PROJECT, GH_REPO, AGENT_PANES, and related topology values.

ordo_external_profile_error() {
  printf 'ordo.config.sh requires ORDO_PROJECT_PROFILE to point at an external project config\n' >&2
  return 2 2>/dev/null || exit 2
}

if [[ -z "${ORDO_PROJECT_PROFILE:-}" ]]; then
  ordo_external_profile_error
fi

if [[ ! -f "$ORDO_PROJECT_PROFILE" ]]; then
  printf 'external project config not found: %s\n' "$ORDO_PROJECT_PROFILE" >&2
  return 2 2>/dev/null || exit 2
fi

# shellcheck source=/dev/null
source "$ORDO_PROJECT_PROFILE"

missing=()
for required_name in PROJECT GH_REPO DEFAULT_BRANCH GH_CONFIG_DIR AGENT_REPO_PREFIX AGENT_WORKDIR_TEMPLATE; do
  if [[ -z "${!required_name:-}" ]]; then
    missing+=("$required_name")
  fi
done

if [[ ! -v AGENT_PANES || "${#AGENT_PANES[@]}" -eq 0 ]]; then
  missing+=("AGENT_PANES")
fi

if [[ "${#missing[@]}" -gt 0 ]]; then
  printf 'external project config missing required values: %s\n' "${missing[*]}" >&2
  return 2 2>/dev/null || exit 2
fi
