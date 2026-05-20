#!/usr/bin/env bash
# lib/sixsigma_config.sh — project opt-in configuration helpers for the
# Six Sigma Level 2 project DMAIC module (#240).
#
# The Level 2 project Six Sigma module is opt-in and disabled by default.
# This file provides three pure validators that callers (the docs
# generator, the project-module CLI, the dispatch brief renderer) can
# share so that opt-in is resolved consistently and unsafe dossier paths
# never reach the filesystem.
#
# Hard boundary: this helper resolves *configuration intent only*. It
# does not approve a release, waive a control, validate a system, or
# mark a DMAIC phase complete; absent or malformed configuration always
# resolves to "disabled" rather than "enabled".
#
# Public functions:
#
#   sixsigma_config_project_enabled <value>
#     Validates the SIXSIGMA_PROJECT_ENABLED knob. Exit 0 when the value
#     is enabled, 1 when disabled (including empty/absent), 2 when the
#     value is non-empty but unrecognized.
#
#   sixsigma_config_by_design_default <value>
#     Validates the SIXSIGMA_BY_DESIGN_DEFAULT knob with the same rules
#     and the same exit-code contract.
#
#   sixsigma_config_safe_dossier_path <relative_path>
#     Validates that <relative_path> is a safe project-relative dossier
#     path. Exit 0 when safe, non-zero with a stderr reason otherwise.
#
#   sixsigma_config_resolve_layer
#     Reads SIXSIGMA_PROJECT_ENABLED from the environment and prints
#     "enabled" or "disabled". Unknown values resolve to "disabled" and
#     produce exit code 2 so callers can distinguish a misconfiguration
#     from a clean opt-out.

set -euo pipefail

# Recognized truthy / falsy spellings. Kept narrow on purpose: configuration
# files should opt in explicitly, not by accident.
# shellcheck disable=SC2034  # consumed by _sixsigma_config_match_value via nameref (local -n)
readonly SIXSIGMA_CONFIG_TRUE_VALUES=(1 true TRUE True yes YES Yes on ON On)
# shellcheck disable=SC2034  # consumed by _sixsigma_config_match_value via nameref (local -n)
readonly SIXSIGMA_CONFIG_FALSE_VALUES=(0 false FALSE False no NO No off OFF Off "")

# _sixsigma_config_match_value <candidate> <name-of-array>
#
# Returns 0 if <candidate> appears in the named array, 1 otherwise.
_sixsigma_config_match_value() {
  local candidate=${1-}
  local -n _haystack=$2
  local entry
  for entry in "${_haystack[@]}"; do
    [[ "$candidate" == "$entry" ]] && return 0
  done
  return 1
}

# sixsigma_config_project_enabled <value>
#
# Exit 0 if <value> means "enabled", 1 if "disabled" (including the
# empty / unset case), 2 if the value is non-empty but unrecognized.
sixsigma_config_project_enabled() {
  local value=${1-}
  if _sixsigma_config_match_value "$value" SIXSIGMA_CONFIG_TRUE_VALUES; then
    return 0
  fi
  if _sixsigma_config_match_value "$value" SIXSIGMA_CONFIG_FALSE_VALUES; then
    return 1
  fi
  printf 'sixsigma_config_project_enabled: unrecognized SIXSIGMA_PROJECT_ENABLED value %q; expected true/false-like token\n' \
    "$value" >&2
  return 2
}

# sixsigma_config_by_design_default <value>
#
# Same contract as sixsigma_config_project_enabled, applied to the
# SIXSIGMA_BY_DESIGN_DEFAULT knob that selects whether a Six Sigma-enabled
# project enters the by-design run mode by default.
sixsigma_config_by_design_default() {
  local value=${1-}
  if _sixsigma_config_match_value "$value" SIXSIGMA_CONFIG_TRUE_VALUES; then
    return 0
  fi
  if _sixsigma_config_match_value "$value" SIXSIGMA_CONFIG_FALSE_VALUES; then
    return 1
  fi
  printf 'sixsigma_config_by_design_default: unrecognized SIXSIGMA_BY_DESIGN_DEFAULT value %q; expected true/false-like token\n' \
    "$value" >&2
  return 2
}

# sixsigma_config_safe_dossier_path <relative_path>
#
# A "safe" Six Sigma dossier path is a non-empty, project-relative POSIX
# path that stays inside the project tree. Rejected:
#   - empty string
#   - absolute paths (leading "/")
#   - any "~" prefix (home expansion)
#   - any ".." segment (parent traversal)
#   - any "." segment (current-dir noise)
#   - leading "./" prefix
#   - any character outside [A-Za-z0-9._/-]
#   - whitespace anywhere in the path
#   - trailing slash
#   - empty segment (e.g. "a//b")
#
# Exit codes: 0 safe, 1 unsafe (with a one-line reason on stderr).
sixsigma_config_safe_dossier_path() {
  local candidate=${1-}

  if [[ -z "$candidate" ]]; then
    printf 'sixsigma_config_safe_dossier_path: path is empty\n' >&2
    return 1
  fi

  if [[ "$candidate" == /* ]]; then
    printf 'sixsigma_config_safe_dossier_path: path %q is absolute\n' "$candidate" >&2
    return 1
  fi

  if [[ "$candidate" == "~"* ]]; then
    printf 'sixsigma_config_safe_dossier_path: path %q starts with ~\n' "$candidate" >&2
    return 1
  fi

  if [[ "$candidate" == ./* || "$candidate" == "." ]]; then
    printf 'sixsigma_config_safe_dossier_path: path %q has a leading ./ or is "."\n' "$candidate" >&2
    return 1
  fi

  if [[ "$candidate" == */ ]]; then
    printf 'sixsigma_config_safe_dossier_path: path %q has a trailing slash\n' "$candidate" >&2
    return 1
  fi

  if [[ "$candidate" =~ [[:space:]] ]]; then
    printf 'sixsigma_config_safe_dossier_path: path %q contains whitespace\n' "$candidate" >&2
    return 1
  fi

  if [[ ! "$candidate" =~ ^[A-Za-z0-9._/-]+$ ]]; then
    printf 'sixsigma_config_safe_dossier_path: path %q contains characters outside [A-Za-z0-9._/-]\n' \
      "$candidate" >&2
    return 1
  fi

  local IFS='/'
  local -a segments
  read -r -a segments <<<"$candidate"
  local seg
  for seg in "${segments[@]}"; do
    if [[ -z "$seg" ]]; then
      printf 'sixsigma_config_safe_dossier_path: path %q has an empty segment\n' "$candidate" >&2
      return 1
    fi
    if [[ "$seg" == ".." ]]; then
      printf 'sixsigma_config_safe_dossier_path: path %q contains a .. segment\n' "$candidate" >&2
      return 1
    fi
    if [[ "$seg" == "." ]]; then
      printf 'sixsigma_config_safe_dossier_path: path %q contains a . segment\n' "$candidate" >&2
      return 1
    fi
  done

  return 0
}

# sixsigma_config_resolve_layer
#
# Resolves the project-profile opt-in to a layer decision printed on
# stdout: "enabled" when SIXSIGMA_PROJECT_ENABLED is truthy, "disabled"
# otherwise. Unknown values print "disabled" and exit 2 so the caller
# can distinguish a misconfigured profile from a clean opt-out.
sixsigma_config_resolve_layer() {
  local value=${SIXSIGMA_PROJECT_ENABLED-}
  if _sixsigma_config_match_value "$value" SIXSIGMA_CONFIG_TRUE_VALUES; then
    printf 'enabled\n'
    return 0
  fi
  if _sixsigma_config_match_value "$value" SIXSIGMA_CONFIG_FALSE_VALUES; then
    printf 'disabled\n'
    return 0
  fi
  printf 'disabled\n'
  printf 'sixsigma_config_resolve_layer: unrecognized SIXSIGMA_PROJECT_ENABLED value %q; resolving to disabled\n' \
    "$value" >&2
  return 2
}
