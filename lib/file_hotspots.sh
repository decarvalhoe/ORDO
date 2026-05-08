#!/usr/bin/env bash
# lib/file_hotspots.sh — coordination-surface (file hotspot) helpers.
#
# Coordination surfaces are paths that multi-agent waves should not modify in
# parallel without explicit sequencing: README, PRODUCT, docs index, package
# metadata, CI workflow files, and central bootstrap scripts. The agent
# attribution helper resolves which agent owns a given pull request so the
# hotspot matrix can detect the same shared file being edited by multiple
# agents.
#
# Agent attribution (issue #292) MUST be profile-driven. ORDO is a general
# multi-agent toolkit — deployments without RBOKCLI-style author logins must
# not be misclassified as single-owner. Configuration sources, in priority
# order:
#
#   1. The first matching `agent:<name>` PR label (case-insensitive).
#   2. An explicit author -> agent map from
#      `ORDO_FILE_HOTSPOT_AUTHOR_AGENT_MAP` (bash array of "login=agent").
#   3. The first configured prefix from `ORDO_FILE_HOTSPOT_LOGIN_PREFIXES`
#      (bash array, multi-prefix) or `ORDO_FILE_HOTSPOT_LOGIN_PREFIX`
#      (single-prefix, retained for transitional compatibility) that the
#      author login starts with — the matched prefix is stripped.
#   4. The raw author login (no prefix stripping).
#   5. The literal string `unknown` when no author and no labels are present.
#
# There is no implicit `RBOKCLI` fallback: when none of the configured
# sources match, the raw author login is returned. Operators that want
# RBOKCLI stripping must opt in via the configuration above.

# Default coordination-surface patterns. Patterns use bash glob syntax in
# `case` (so `*` matches any sequence, including `/`). Operators can override
# the full set by exporting `ORDO_FILE_HOTSPOT_PATTERNS` as a bash array, or
# extend the defaults via `ORDO_FILE_HOTSPOT_EXTRA`.
file_hotspots_default_patterns() {
  cat <<'PATTERNS'
README.md
PRODUCT.md
docs/INDEX.md
docs/index.md
package.json
package-lock.json
pnpm-lock.yaml
yarn.lock
pyproject.toml
poetry.lock
requirements.txt
Cargo.toml
Cargo.lock
go.mod
go.sum
install.sh
.github/workflows/*.yml
.github/workflows/*.yaml
PATTERNS
}

# Emit the effective hotspot patterns, one per line:
#   1. ORDO_FILE_HOTSPOT_PATTERNS (full override) when the array is set.
#   2. Defaults otherwise.
#   3. ORDO_FILE_HOTSPOT_EXTRA always appended.
file_hotspots_patterns() {
  if declare -p ORDO_FILE_HOTSPOT_PATTERNS >/dev/null 2>&1 \
     && [ "${#ORDO_FILE_HOTSPOT_PATTERNS[@]}" -gt 0 ]; then
    printf '%s\n' "${ORDO_FILE_HOTSPOT_PATTERNS[@]}"
  else
    file_hotspots_default_patterns
  fi
  if declare -p ORDO_FILE_HOTSPOT_EXTRA >/dev/null 2>&1 \
     && [ "${#ORDO_FILE_HOTSPOT_EXTRA[@]}" -gt 0 ]; then
    printf '%s\n' "${ORDO_FILE_HOTSPOT_EXTRA[@]}"
  fi
}

file_hotspots_path_matches() {
  local path=$1 pattern=$2
  case "$pattern" in
    */)
      case "$path" in
        "${pattern}"*) return 0 ;;
      esac
      ;;
    *)
      # shellcheck disable=SC2254 # intentional glob expansion against $pattern
      case "$path" in
        $pattern) return 0 ;;
      esac
      ;;
  esac
  return 1
}

file_hotspots_match_path() {
  local path=$1 pattern
  while IFS= read -r pattern; do
    [ -n "$pattern" ] || continue
    case "$pattern" in
      \#*) continue ;;
    esac
    if file_hotspots_path_matches "$path" "$pattern"; then
      return 0
    fi
  done < <(file_hotspots_patterns)
  return 1
}

file_hotspots_filter_paths() {
  local path
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    if file_hotspots_match_path "$path"; then
      printf '%s\n' "$path"
    fi
  done
}

# Emit the configured login prefixes, one per line, in the order operators
# declared them. Resolution is:
#   1. ORDO_FILE_HOTSPOT_LOGIN_PREFIXES bash array (preferred, multi-value).
#   2. ORDO_FILE_HOTSPOT_LOGIN_PREFIX single value (transitional compat).
#   3. Empty (no prefix stripping).
file_hotspots_login_prefixes() {
  # shellcheck disable=SC2153 # PREFIXES (array) and PREFIX (singular) are both valid configs.
  if declare -p ORDO_FILE_HOTSPOT_LOGIN_PREFIXES >/dev/null 2>&1 \
     && [ "${#ORDO_FILE_HOTSPOT_LOGIN_PREFIXES[@]}" -gt 0 ]; then
    printf '%s\n' "${ORDO_FILE_HOTSPOT_LOGIN_PREFIXES[@]}"
    return 0
  fi
  if [ -n "${ORDO_FILE_HOTSPOT_LOGIN_PREFIX:-}" ]; then
    printf '%s\n' "$ORDO_FILE_HOTSPOT_LOGIN_PREFIX"
  fi
}

# Look up an explicit author -> agent mapping. Returns 0 and prints the
# mapped agent when a match is found; returns 1 otherwise.
#
# The map is read from ORDO_FILE_HOTSPOT_AUTHOR_AGENT_MAP, a bash array of
# "login=agent" entries. Whitespace around the `=` is tolerated.
file_hotspots_author_agent_lookup() {
  local author=${1:-}
  [ -n "$author" ] || return 1
  declare -p ORDO_FILE_HOTSPOT_AUTHOR_AGENT_MAP >/dev/null 2>&1 || return 1
  [ "${#ORDO_FILE_HOTSPOT_AUTHOR_AGENT_MAP[@]}" -gt 0 ] || return 1
  local entry login agent
  for entry in "${ORDO_FILE_HOTSPOT_AUTHOR_AGENT_MAP[@]}"; do
    [ -n "$entry" ] || continue
    login=${entry%%=*}
    agent=${entry#*=}
    # trim whitespace around login / agent
    login=${login#"${login%%[![:space:]]*}"}
    login=${login%"${login##*[![:space:]]}"}
    agent=${agent#"${agent%%[![:space:]]*}"}
    agent=${agent%"${agent##*[![:space:]]}"}
    if [ -n "$login" ] && [ "$login" = "$author" ]; then
      printf '%s' "$agent"
      return 0
    fi
  done
  return 1
}

# Resolve a PR's effective agent label. See the file header for the
# resolution order.
#
# Inputs are passed as arguments to keep this function pure.
file_hotspots_pr_agent() {
  local author=${1:-}
  local labels_csv=${2:-}
  local label

  # 1. agent:<name> label wins (case-insensitive prefix on the label name).
  #    Bare `agent:` labels (no name) are skipped so resolution continues
  #    rather than returning a useless empty agent.
  if [ -n "$labels_csv" ]; then
    while IFS= read -r label; do
      [ -n "$label" ] || continue
      local lower=${label,,}
      case "$lower" in
        agent:?*)
          # Extract by index (6 = length of "agent:") to preserve the
          # original case of the agent name while still matching labels
          # case-insensitively (Agent:foo, AGENT:foo, agent:foo all work).
          printf '%s' "${label:6}"
          return 0 ;;
      esac
    # The trailing newline is required: `read` returns 1 on EOF without a
    # newline, which would silently skip the last (or only) label.
    done < <(printf '%s\n' "$labels_csv" | tr ',' '\n')
  fi

  if [ -n "$author" ]; then
    # 2. Explicit author -> agent map.
    local mapped
    if mapped=$(file_hotspots_author_agent_lookup "$author"); then
      printf '%s' "$mapped"
      return 0
    fi

    # 3. First matching configured login prefix wins.
    local prefix
    while IFS= read -r prefix; do
      [ -n "$prefix" ] || continue
      if [[ "$author" == "$prefix"* ]]; then
        printf '%s' "${author#"$prefix"}"
        return 0
      fi
    done < <(file_hotspots_login_prefixes)

    # 4. Raw author login — no implicit RBOKCLI fallback.
    printf '%s' "$author"
    return 0
  fi

  # 5. No author and no labels — sentinel value the matrix can render.
  printf '%s' "unknown"
}

file_hotspots_classify() {
  local pr_count=${1:?usage: file_hotspots_classify <pr_count> <agent_count> <accepted>}
  local agent_count=${2:?missing agent_count}
  local accepted=${3:-0}
  if [ "$pr_count" -le 1 ] || [ "$agent_count" -le 1 ]; then
    printf 'single_owner\n'
    return 0
  fi
  if [ "$accepted" = "1" ]; then
    printf 'accepted_risk\n'
    return 0
  fi
  printf 'blocker\n'
}

file_hotspots_recommendation() {
  local classification=${1:?usage: file_hotspots_recommendation <classification>}
  case "$classification" in
    single_owner) printf 'ok-single-owner\n' ;;
    accepted_risk) printf 'operator-accepted-sequence\n' ;;
    blocker) printf 'sequence-or-reassign\n' ;;
    *) printf 'unknown\n' ;;
  esac
}
