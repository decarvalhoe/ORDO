#!/usr/bin/env bash
# lib/file_hotspots.sh — coordination-surface (file hotspot) defaults and helpers.
#
# Coordination surfaces are paths that multi-agent waves should not modify in
# parallel without explicit sequencing: README, PRODUCT, docs index, package
# metadata, CI workflow files, and central bootstrap scripts. dispatch_plan.sh
# consumes these helpers in --hotspots mode to emit a per-coordination-surface
# matrix before dispatch.
#
# Helpers are dependency-light so the existing test runner can sanitize this
# file alongside the rest of the toolkit and so each function is callable from
# direct unit tests.

# Default coordination-surface patterns. Patterns use bash glob syntax in `case`
# (so * matches any sequence, including /). Operators can override the full set
# by exporting ORDO_FILE_HOTSPOT_PATTERNS as a bash array, or extend the
# defaults by exporting ORDO_FILE_HOTSPOT_EXTRA.
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

# Test if a single repo-relative path matches a single glob pattern. Patterns
# ending with `/` are treated as directory prefixes; everything else uses the
# bash `case` glob semantics (so `*` and `?` are wildcards).
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

# Return 0 if a path matches any configured hotspot pattern.
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

# Read a newline-delimited list of paths from stdin and emit only those that
# match a configured hotspot pattern, preserving order.
file_hotspots_filter_paths() {
  local path
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    if file_hotspots_match_path "$path"; then
      printf '%s\n' "$path"
    fi
  done
}

# Resolve a PR's effective agent label. Order:
#   1. The first matching `agent:<name>` PR label (case-insensitive).
#   2. The PR author login with the configured ORDO_FILE_HOTSPOT_LOGIN_PREFIX
#      stripped (default "RBOKCLI").
#   3. The raw author login.
#   4. "unknown" when nothing else resolves.
#
# Inputs are passed as arguments to keep this function pure.
file_hotspots_pr_agent() {
  local author=${1:-}
  local labels_csv=${2:-}
  local prefix=${ORDO_FILE_HOTSPOT_LOGIN_PREFIX:-RBOKCLI}
  local label
  if [ -n "$labels_csv" ]; then
    while IFS= read -r label; do
      [ -n "$label" ] || continue
      local lower=${label,,}
      case "$lower" in
        agent:*)
          printf '%s' "${label#agent:}"
          return 0 ;;
      esac
    done < <(printf '%s' "$labels_csv" | tr ',' '\n')
  fi
  if [ -n "$author" ]; then
    if [ -n "$prefix" ] && [[ "$author" == "$prefix"* ]]; then
      printf '%s' "${author#"$prefix"}"
    else
      printf '%s' "$author"
    fi
    return 0
  fi
  printf '%s' "unknown"
}

# Classify a hotspot row given the number of touching PRs and unique agents,
# plus an "accepted" flag. Emits one of:
#   single_owner    — one PR or one unique agent (no parallel risk).
#   accepted_risk   — multiple agents, but operator opted in.
#   blocker         — multiple agents, no operator opt-in.
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

# Recommend a remediation sentence for a classification.
file_hotspots_recommendation() {
  local classification=${1:?usage: file_hotspots_recommendation <classification>}
  case "$classification" in
    single_owner) printf 'ok-single-owner\n' ;;
    accepted_risk) printf 'operator-accepted-sequence\n' ;;
    blocker) printf 'sequence-or-reassign\n' ;;
    *) printf 'unknown\n' ;;
  esac
}
