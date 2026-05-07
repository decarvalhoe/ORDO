#!/usr/bin/env bash
# portfolio_config.sh - resolve multi-product portfolio configs.

_ORCH_PORTFOLIO_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/config_resolver.sh
source "$_ORCH_PORTFOLIO_LIB_DIR/config_resolver.sh"

load_portfolio_config() {
  local raw=${1:?usage: load_portfolio_config <portfolio-config>}
  local cfg
  cfg=$(resolve_config_path "$raw")
  # shellcheck disable=SC1090
  source "$cfg"
  # shellcheck disable=SC2034
  ORCH_PORTFOLIO_CONFIG_PATH="$cfg"
  if [[ -z "${PORTFOLIO_PROJECTS+x}" || "${#PORTFOLIO_PROJECTS[@]}" -eq 0 ]]; then
    printf 'portfolio config must define PORTFOLIO_PROJECTS\n' >&2
    return 1
  fi
}

portfolio_yolo_priority_enabled() {
  case "${PORTFOLIO_YOLO_PRIORITY:-0}" in
    1|true|TRUE|yes|YES|on|ON)
      return 0
      ;;
  esac
  return 1
}

portfolio_priority_lookup() {
  local needle=${1:?usage: portfolio_priority_lookup <project>}
  local entry project priority

  if [[ -z "${PORTFOLIO_PRIORITIES+x}" || "${#PORTFOLIO_PRIORITIES[@]}" -eq 0 ]]; then
    return 1
  fi

  for entry in "${PORTFOLIO_PRIORITIES[@]}"; do
    if [[ "$entry" == *"="* ]]; then
      IFS='=' read -r project priority <<< "$entry"
    else
      IFS='|' read -r project priority _ <<< "$entry"
    fi
    if [[ "$project" == "$needle" && "$priority" =~ ^[0-9]+$ ]]; then
      printf '%s\n' "$priority"
      return 0
    fi
  done

  return 1
}

portfolio_project_priority() {
  local needle=${1:?usage: portfolio_project_priority <project>}
  local priority total index entry project

  if priority=$(portfolio_priority_lookup "$needle"); then
    printf '%s\n' "$priority"
    return 0
  fi

  if portfolio_yolo_priority_enabled; then
    total=${#PORTFOLIO_PROJECTS[@]}
    index=0
    for entry in "${PORTFOLIO_PROJECTS[@]}"; do
      IFS='|' read -r project _ <<< "$entry"
      if [[ "$project" == "$needle" ]]; then
        printf '%s\n' $(((total - index) * 10))
        return 0
      fi
      index=$((index + 1))
    done
  fi

  printf '0\n'
}

portfolio_priority_mode() {
  if [[ -n "${PORTFOLIO_PRIORITIES+x}" && "${#PORTFOLIO_PRIORITIES[@]}" -gt 0 ]]; then
    printf 'explicit\n'
  elif portfolio_yolo_priority_enabled; then
    printf 'yolo\n'
  else
    printf 'missing\n'
  fi
}

portfolio_require_priorities() {
  local entry project missing=0

  if portfolio_yolo_priority_enabled; then
    return 0
  fi

  if [[ -z "${PORTFOLIO_PRIORITIES+x}" || "${#PORTFOLIO_PRIORITIES[@]}" -eq 0 ]]; then
    printf 'portfolio priorities are required. Define PORTFOLIO_PRIORITIES in the portfolio config, for example:\n' >&2
    printf '  PORTFOLIO_PRIORITIES=("rbok=100" "ordo=90" "praxis=50")\n' >&2
    printf 'Or rerun with --yolo-priority to let ORDO choose priorities from portfolio order.\n' >&2
    return 14
  fi

  for entry in "${PORTFOLIO_PROJECTS[@]}"; do
    IFS='|' read -r project _ <<< "$entry"
    if ! portfolio_priority_lookup "$project" >/dev/null; then
      printf 'portfolio priority missing or invalid for project: %s\n' "$project" >&2
      missing=1
    fi
  done

  if [[ "$missing" -ne 0 ]]; then
    printf 'Add every project to PORTFOLIO_PRIORITIES or rerun with --yolo-priority.\n' >&2
    return 14
  fi
}

portfolio_project_entries() {
  local entry project cfg resolved
  for entry in "${PORTFOLIO_PROJECTS[@]}"; do
    IFS='|' read -r project cfg _ <<< "$entry"
    if [[ -z "$project" || -z "$cfg" ]]; then
      printf 'PORTFOLIO_PROJECTS entry malformed (need "project|config"): %s\n' "$entry" >&2
      return 1
    fi
    resolved=$(resolve_config_path "$cfg")
    printf '%s|%s\n' "$project" "$resolved"
  done
}

portfolio_find_project() {
  local needle=${1:?usage: portfolio_find_project <project>}
  local project cfg
  while IFS='|' read -r project cfg; do
    if [[ "$project" == "$needle" ]]; then
      printf '%s\n' "$cfg"
      return 0
    fi
  done < <(portfolio_project_entries)
  printf 'portfolio project not found: %s\n' "$needle" >&2
  return 1
}

portfolio_state_dir() {
  local base
  base="${ORCH_STATE_BASE:-${XDG_DATA_HOME:-/root/.local/share}/orch-state}"
  printf '%s/_portfolio\n' "$base"
}

portfolio_fleet_spec() {
  if [[ -n "${PORTFOLIO_FLEET_AGENTS+x}" && "${#PORTFOLIO_FLEET_AGENTS[@]}" -gt 0 ]]; then
    printf '%s\n' "${PORTFOLIO_FLEET_AGENTS[@]}"
  fi
}

portfolio_agent_matrix_enabled() {
  local matrix_spec=${1:-}
  local ensure_matrix=${2:-${PORTFOLIO_ENSURE_AGENT_MATRIX:-}}

  if [[ -z "$ensure_matrix" ]]; then
    if [[ -n "$matrix_spec" ]]; then
      ensure_matrix=1
    else
      ensure_matrix=0
    fi
  fi

  [[ "$ensure_matrix" == "1" ]]
}

portfolio_matrix_workdir_for_label() {
  local label=${1:?usage: portfolio_matrix_workdir_for_label <label>}

  if [[ -n "${AGENT_WORKDIR_TEMPLATE:-}" ]]; then
    # shellcheck disable=SC2059
    printf "$AGENT_WORKDIR_TEMPLATE" "$label"
  elif [[ -n "${AGENT_REPO_PREFIX:-}" ]]; then
    printf '%s%s\n' "$AGENT_REPO_PREFIX" "$label"
  else
    return 1
  fi
}

portfolio_matrix_entry_from_loaded_project() {
  local selector=${1:?usage: portfolio_matrix_entry_from_loaded_project <selector> <matrix-spec> [ensure-matrix]}
  local matrix_spec=${2:-}
  local ensure_matrix=${3:-}
  local matrix_label matrix_pane extra matrix_workdir

  portfolio_agent_matrix_enabled "$matrix_spec" "$ensure_matrix" || return 1
  [[ -n "$matrix_spec" ]] || return 1

  while IFS='|' read -r matrix_label matrix_pane extra; do
    [[ -n "$matrix_label$matrix_pane$extra" ]] || continue
    if [[ -n "$extra" ]]; then
      printf 'PORTFOLIO_FLEET_AGENTS entry malformed (need label or label|pane): %s|%s|%s\n' \
        "$matrix_label" "$matrix_pane" "$extra" >&2
      return 2
    fi
    [[ -n "$matrix_label" ]] || continue

    if [[ "$selector" != "$matrix_label" \
      && "$selector" != "$matrix_pane" \
      && "$selector" != "${matrix_pane%%:*}" ]]; then
      continue
    fi

    [[ -n "$matrix_pane" ]] || return 1
    matrix_workdir=$(portfolio_matrix_workdir_for_label "$matrix_label") || return 1
    printf '%s|%s|%s\n' "$matrix_label" "$matrix_pane" "$matrix_workdir"
    return 0
  done <<< "$matrix_spec"

  return 1
}

# Normalize a git remote URL for comparison: strip .git suffix and trailing
# slashes, and convert ssh form (git@host:path) to https-equivalent
# (https://host/path) so a clone whose origin is git@github.com:org/repo.git
# matches a portfolio config that records https://github.com/org/repo.
portfolio_normalize_remote_url() {
  local url=${1:-}
  url="${url%.git}"
  url="${url%/}"
  if [[ "$url" == git@*:* ]]; then
    local host_path="${url#git@}"
    url="https://${host_path/:/\/}"
  fi
  printf '%s\n' "$url"
}

# Resolve the canonical remote URL for a portfolio project alias by sourcing
# its project config in a subshell. Honours GIT_REMOTE_URL > REPO_URL >
# https://github.com/<GH_REPO>.git (matches portfolio_session_start.sh).
# Prints empty output and returns 1 when the alias is unknown or the
# project config exposes no remote.
portfolio_project_remote() {
  local alias=${1:?usage: portfolio_project_remote <alias>}
  local cfg
  cfg=$(portfolio_find_project "$alias") || return 1
  bash -c '
    set -euo pipefail
    cfg=$1
    # shellcheck disable=SC1090
    source "$cfg"
    if [[ -n "${GIT_REMOTE_URL:-}" ]]; then
      printf "%s\n" "$GIT_REMOTE_URL"
    elif [[ -n "${REPO_URL:-}" ]]; then
      printf "%s\n" "$REPO_URL"
    elif [[ -n "${GH_REPO:-}" ]]; then
      printf "https://github.com/%s.git\n" "$GH_REPO"
    fi
  ' _ "$cfg"
}

# Refuse when a workdir's origin remote does not match the expected portfolio
# project remote. Closes the duplicate-clone context-mismatch class of
# findings (F-021/F-029): two clones on disk pointing at different products,
# dispatch picking the wrong one.
portfolio_assert_workdir_remote_match() {
  local workdir=${1:?usage: portfolio_assert_workdir_remote_match <workdir> <expected-remote>}
  local expected=${2:?usage: portfolio_assert_workdir_remote_match <workdir> <expected-remote>}
  local actual norm_expected norm_actual
  actual=$(git -C "$workdir" remote get-url origin 2>/dev/null || true)
  if [[ -z "$actual" ]]; then
    printf 'matrix workdir has no origin remote: %s\n' "$workdir" >&2
    return 1
  fi
  norm_expected=$(portfolio_normalize_remote_url "$expected")
  norm_actual=$(portfolio_normalize_remote_url "$actual")
  if [[ "$norm_expected" != "$norm_actual" ]]; then
    printf 'duplicate-clone context mismatch: workdir %s has origin=%s but portfolio expects %s\n' \
      "$workdir" "$norm_actual" "$norm_expected" >&2
    return 1
  fi
}

# Refuse when a matrix workdir is not in a state that can safely receive a
# fresh dispatch. Required state: clone exists with .git, no uncommitted
# changes, on the project's default branch synced with origin, or on a
# feature branch whose tip descends from origin/<default>. Closes the
# matrix-readiness gate findings (F-023/F-024/F-030/F-031).
portfolio_assert_workdir_ready() {
  local workdir=${1:?usage: portfolio_assert_workdir_ready <workdir> <default-branch>}
  local default_branch=${2:?usage: portfolio_assert_workdir_ready <workdir> <default-branch>}
  if [[ ! -d "$workdir/.git" ]]; then
    printf 'matrix workdir is not a git clone: %s\n' "$workdir" >&2
    return 1
  fi
  local dirty branch counts ahead behind
  dirty=$(git -C "$workdir" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
  if [[ "${dirty:-0}" != "0" ]]; then
    printf 'matrix workdir has %s uncommitted change(s): %s\n' "$dirty" "$workdir" >&2
    return 1
  fi
  branch=$(git -C "$workdir" branch --show-current 2>/dev/null || true)
  if [[ -z "$branch" ]]; then
    printf 'matrix workdir is in detached HEAD state: %s\n' "$workdir" >&2
    return 1
  fi
  if ! git -C "$workdir" rev-parse --verify "origin/$default_branch" >/dev/null 2>&1; then
    printf 'matrix workdir has no origin/%s ref: %s\n' "$default_branch" "$workdir" >&2
    return 1
  fi
  if [[ "$branch" == "$default_branch" ]]; then
    counts=$(git -C "$workdir" rev-list --left-right --count "HEAD...origin/$default_branch" 2>/dev/null || true)
    ahead=${counts%%[[:space:]]*}
    behind=${counts##*[[:space:]]}
    if [[ "${ahead:-0}" != "0" || "${behind:-0}" != "0" ]]; then
      printf 'matrix workdir default branch out of sync (ahead=%s behind=%s): %s\n' \
        "${ahead:-0}" "${behind:-0}" "$workdir" >&2
      return 1
    fi
  else
    if ! git -C "$workdir" merge-base --is-ancestor "origin/$default_branch" HEAD 2>/dev/null; then
      printf 'matrix workdir branch %s is not based on origin/%s: %s\n' \
        "$branch" "$default_branch" "$workdir" >&2
      return 1
    fi
  fi
}

portfolio_expand_matrix_agent_pane() {
  local selector=${1:?usage: portfolio_expand_matrix_agent_pane <selector> <matrix-spec> [ensure-matrix]}
  local matrix_spec=${2:-}
  local ensure_matrix=${3:-}
  local entry label pane workdir

  if declare -F agent_inventory_find >/dev/null 2>&1 \
    && [[ -n "${AGENT_PANES+x}" && "${#AGENT_PANES[@]}" -gt 0 ]]; then
    if entry=$(agent_inventory_find "$selector" 2>/dev/null); then
      printf '%s\n' "$entry"
      return 0
    fi
  fi

  entry=$(portfolio_matrix_entry_from_loaded_project "$selector" "$matrix_spec" "$ensure_matrix") || return 1
  IFS='|' read -r label pane workdir <<< "$entry"
  if [[ ! -d "$workdir/.git" ]]; then
    printf 'portfolio matrix target workdir is not a git repo: %s\n' "$workdir" >&2
    return 4
  fi

  if [[ -z "${AGENT_PANES+x}" ]]; then
    declare -ga AGENT_PANES=()
  fi
  AGENT_PANES+=("$label|$pane|$workdir")
  printf '%s\n' "$entry"
}
