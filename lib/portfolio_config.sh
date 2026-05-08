#!/usr/bin/env bash
# portfolio_config.sh - resolve multi-product portfolio configs.

_ORCH_PORTFOLIO_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/config_resolver.sh
source "$_ORCH_PORTFOLIO_LIB_DIR/config_resolver.sh"

portfolio_emit() {
  # shellcheck disable=SC2059
  printf "$@" 2>/dev/null || return 141
}

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
    printf '  PORTFOLIO_PRIORITIES=("product-a=100" "product-b=80" "product-c=60")\n' >&2
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
    portfolio_emit '%s|%s\n' "$project" "$resolved" || return 0
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
    portfolio_emit '%s\n' "${PORTFOLIO_FLEET_AGENTS[@]}" || return 0
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

# Derive the canonical clone URL of the currently-loaded project config from
# GH_REPO / REPO_URL / GIT_REMOTE_URL. Mirrors the inventory logic in
# scripts/portfolio_session_start.sh so dispatch and preflight agree on the
# project's source of truth.
portfolio_canonical_clone_url_for_loaded_project() {
  local clone_url=${GIT_REMOTE_URL:-${REPO_URL:-}}
  if [[ -z "$clone_url" && -n "${GH_REPO:-}" ]]; then
    clone_url="https://github.com/${GH_REPO}.git"
  fi
  printf '%s\n' "$clone_url"
}

# Normalize a clone URL for comparison: strip trailing .git, fold
# git@host:owner/repo to https://host/owner/repo, drop trailing slashes.
portfolio_normalize_clone_url() {
  local url=${1:-}
  url=${url#"${url%%[![:space:]]*}"}
  url=${url%"${url##*[![:space:]]}"}
  [[ -n "$url" ]] || return 1

  if [[ "$url" =~ ^git@([^:]+):(.+)$ ]]; then
    url="https://${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
  fi

  url=${url%.git}
  url=${url%/}

  printf '%s\n' "$url"
}

portfolio_workdir_origin_url() {
  local workdir=${1:?usage: portfolio_workdir_origin_url <workdir>}
  [[ -d "$workdir/.git" ]] || return 1
  git -C "$workdir" remote get-url origin 2>/dev/null
}

# Returns 0 when the workdir's origin URL canonicalizes to the same value as
# `canonical_url`. Returns 0 also when `canonical_url` is empty (nothing to
# verify against). Returns non-zero on actual mismatch or when the origin
# remote cannot be read.
portfolio_workdir_origin_matches_canonical() {
  local workdir=${1:?usage: portfolio_workdir_origin_matches_canonical <workdir> <canonical-url>}
  local canonical=${2:-}
  local origin_url normalized_canonical normalized_origin

  [[ -n "$canonical" ]] || return 0
  origin_url=$(portfolio_workdir_origin_url "$workdir") || return 2
  [[ -n "$origin_url" ]] || return 2

  normalized_canonical=$(portfolio_normalize_clone_url "$canonical") || return 3
  normalized_origin=$(portfolio_normalize_clone_url "$origin_url") || return 3

  [[ "$normalized_origin" == "$normalized_canonical" ]]
}

portfolio_preflight_report_path() {
  printf '%s/session_start.json\n' "$(portfolio_state_dir)"
}

portfolio_preflight_max_age_sec() {
  printf '%s\n' "${PORTFOLIO_PREFLIGHT_MAX_AGE_SEC:-3600}"
}

# Echoes one of: ok | missing | stale | not_found | not_ready | jq_missing.
# Returns 0 only on `ok`. Reflects whether a fresh portfolio preflight covers
# `label` with `ready=1`, scoped by PORTFOLIO_PREFLIGHT_MAX_AGE_SEC.
portfolio_preflight_target_status() {
  local label=${1:?usage: portfolio_preflight_target_status <label>}
  local report_path now mtime age max_age labels ready_labels

  report_path=$(portfolio_preflight_report_path)
  if [[ ! -s "$report_path" ]]; then
    printf 'missing\n'
    return 1
  fi
  if ! command -v jq >/dev/null 2>&1; then
    printf 'jq_missing\n'
    return 1
  fi

  now=$(date +%s)
  if mtime=$(stat -c %Y "$report_path" 2>/dev/null); then
    :
  elif mtime=$(stat -f %m "$report_path" 2>/dev/null); then
    :
  else
    mtime="$now"
  fi
  age=$((now - mtime))
  max_age=$(portfolio_preflight_max_age_sec)
  if (( age > max_age )); then
    printf 'stale\n'
    return 1
  fi

  labels=$(jq -r '.[]? | .label // empty' "$report_path" 2>/dev/null || true)
  if ! grep -Fxq "$label" <<< "$labels"; then
    printf 'not_found\n'
    return 1
  fi
  ready_labels=$(jq -r '.[]? | select((.ready == 1) or (.ready == true) or (.ready == "1") or (.status == "ready")) | .label // empty' "$report_path" 2>/dev/null || true)
  if ! grep -Fxq "$label" <<< "$ready_labels"; then
    printf 'not_ready\n'
    return 1
  fi

  printf 'ok\n'
  return 0
}

# Walk the configured projects and emit one JSON line per assignment that
# refers to an agent label which is no longer present in the project's
# configured agents OR in the active portfolio matrix. Assignments without a
# state file produce no output. Used by portfolio_session_start to surface
# stale matrix assignments alongside configured/matrix entries.
portfolio_stale_matrix_assignments_json() {
  local matrix_spec=${1:-}
  local ensure_matrix=${2:-}
  local alias cfg priority
  : "${ORCH_STATE_BASE:=${XDG_DATA_HOME:-/root/.local/share}/orch-state}"

  command -v jq >/dev/null 2>&1 || return 0

  while IFS='|' read -r alias cfg; do
    [[ -n "$alias" && -n "$cfg" ]] || continue
    priority=$(portfolio_project_priority "$alias")

    bash -c '
      set -euo pipefail
      alias=$1
      cfg=$2
      tk=$3
      priority=$4
      matrix_spec=$5
      ensure_matrix=$6
      state_base=$7
      # shellcheck disable=SC1090
      source "$cfg"
      # shellcheck source=lib/agent_inventory.sh
      source "$tk/lib/agent_inventory.sh"

      project_name=${PROJECT:-$alias}
      assignments_path="$state_base/$project_name/assignments.json"
      [[ -s "$assignments_path" ]] || exit 0

      declare -A known_labels=()
      while IFS="|" read -r label pane workdir; do
        [[ -n "$label" ]] || continue
        known_labels[$label]=1
      done < <(agent_inventory_entries || true)

      if [[ "$ensure_matrix" == "1" && -n "$matrix_spec" ]]; then
        while IFS="|" read -r matrix_label _ _; do
          [[ -n "$matrix_label" ]] || continue
          known_labels[$matrix_label]=1
        done <<< "$matrix_spec"
      fi

      while IFS= read -r entry; do
        [[ -n "$entry" ]] || continue
        label=$(printf "%s" "$entry" | jq -r ".key")
        [[ -n "$label" ]] || continue
        [[ -n "${known_labels[$label]:-}" ]] && continue
        ticket=$(printf "%s" "$entry" | jq -r ".value.ticket // .value.issue // \"\"")
        branch=$(printf "%s" "$entry" | jq -r ".value.branch // \"\"")
        workdir=$(printf "%s" "$entry" | jq -r ".value.workdir // \"\"")
        dispatched_at=$(printf "%s" "$entry" | jq -r ".value.dispatched_at // \"\"")
        jq -nc \
          --arg alias "$alias" \
          --arg project "$project_name" \
          --arg agent_label "$label" \
          --arg priority "$priority" \
          --arg ticket "$ticket" \
          --arg branch "$branch" \
          --arg workdir "$workdir" \
          --arg dispatched_at "$dispatched_at" \
          "{
            alias:\$alias,
            project:\$project,
            label:\$agent_label,
            priority:(\$priority | tonumber),
            ticket:\$ticket,
            branch:\$branch,
            workdir:\$workdir,
            dispatched_at:\$dispatched_at
          }"
      done < <(jq -c "to_entries[]" "$assignments_path")
    ' _ "$alias" "$cfg" "$_ORCH_PORTFOLIO_LIB_DIR/.." "$priority" "$matrix_spec" "$ensure_matrix" "$ORCH_STATE_BASE"
  done < <(portfolio_project_entries)
}
