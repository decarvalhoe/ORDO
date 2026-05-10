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

ordo_git_identity_alias_reason() {
  local left_label="$1"
  local right_label="$2"
  local entry alias_label canonical_label reason extra

  if [[ ! -v AGENT_GIT_IDENTITY_ALIASES || "${#AGENT_GIT_IDENTITY_ALIASES[@]}" -eq 0 ]]; then
    return 1
  fi

  for entry in "${AGENT_GIT_IDENTITY_ALIASES[@]}"; do
    IFS='|' read -r alias_label canonical_label reason extra <<<"$entry"
    if [[ -z "$alias_label" || -z "$canonical_label" || -z "$reason" || -n "$extra" ]]; then
      printf 'AGENT_GIT_IDENTITY_ALIASES entry malformed (need alias|canonical|reason): %s\n' "$entry" >&2
      return 2
    fi

    if [[ "$alias_label" == "$left_label" && "$canonical_label" == "$right_label" ]] ||
      [[ "$alias_label" == "$right_label" && "$canonical_label" == "$left_label" ]]; then
      printf '%s' "$reason"
      return 0
    fi
  done

  return 1
}

ordo_validate_git_identity_aliases() {
  local pane label entry identity_label identity_name identity_email extra
  local name email key previous reason alias_rc
  local -a labels=()
  declare -A explicit_names=()
  declare -A explicit_emails=()
  declare -A seen_identity_labels=()

  for pane in "${AGENT_PANES[@]}"; do
    label="${pane%%|*}"
    [[ -n "$label" ]] && labels+=("$label")
  done

  if [[ -v AGENT_GIT_IDENTITIES && "${#AGENT_GIT_IDENTITIES[@]}" -gt 0 ]]; then
    for entry in "${AGENT_GIT_IDENTITIES[@]}"; do
      IFS='|' read -r identity_label identity_name identity_email extra <<<"$entry"
      if [[ -z "$identity_label" || -z "$identity_name" || -z "$identity_email" || -n "$extra" ]]; then
        printf 'AGENT_GIT_IDENTITIES entry malformed (need label|name|email): %s\n' "$entry" >&2
        return 2
      fi
      explicit_names["$identity_label"]="$identity_name"
      explicit_emails["$identity_label"]="$identity_email"
    done
  fi

  for label in "${labels[@]}"; do
    if [[ -n "${explicit_names[$label]+x}" ]]; then
      name="${explicit_names[$label]}"
      email="${explicit_emails[$label]}"
    elif [[ -n "${AGENT_GIT_IDENTITY_NAME_TEMPLATE:-}" &&
      -n "${AGENT_GIT_IDENTITY_EMAIL_TEMPLATE:-}" ]]; then
      printf -v name "$AGENT_GIT_IDENTITY_NAME_TEMPLATE" "$label"
      printf -v email "$AGENT_GIT_IDENTITY_EMAIL_TEMPLATE" "$label"
    else
      continue
    fi

    key="${name}"$'\034'"${email}"
    if [[ -n "${seen_identity_labels[$key]+x}" ]]; then
      previous="${seen_identity_labels[$key]}"
      if reason="$(ordo_git_identity_alias_reason "$label" "$previous")"; then
        alias_rc=0
      else
        alias_rc=$?
      fi
      if [[ "$alias_rc" -eq 0 ]]; then
        printf 'documented git identity alias: %s shares identity with %s (%s)\n' \
          "$label" "$previous" "$reason" >&2
      elif [[ "$alias_rc" -eq 1 ]]; then
        printf 'shared git identity requires AGENT_GIT_IDENTITY_ALIASES: %s and %s both resolve to %s <%s>\n' \
          "$previous" "$label" "$name" "$email" >&2
        return 2
      else
        return 2
      fi
    else
      seen_identity_labels["$key"]="$label"
    fi
  done

  return 0
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

if ! ordo_validate_git_identity_aliases; then
  return 2 2>/dev/null || exit 2
fi
