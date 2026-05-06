#!/usr/bin/env bash
# scripts/portfolio_session_start.sh - start-of-session portfolio clone readiness audit.
#
# Usage:
#   portfolio_session_start.sh <portfolio-config> [--tsv|--json] [--apply] [--dry-run]
#
# The default mode is diagnostic: it fetches origin/default to detect drift,
# reports missing or unsafe clones, and suggests remediations. --apply only runs
# remediations that are safe and deterministic: clone a missing workdir, or
# fast-forward a clean default-branch clone that is behind origin/default.
set -euo pipefail
TK=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

source "$TK/lib/dry_run.sh"
source "$TK/lib/portfolio_config.sh"

dry_run_parse_args "$@"
set -- "${DRY_RUN_ARGS[@]}"

PORTFOLIO_ARG=${1:?usage: portfolio_session_start.sh <portfolio-config> [--tsv|--json] [--apply] [--dry-run]}
FORMAT="tsv"
APPLY=0
FETCH=1
shift
while [ "$#" -gt 0 ]; do
  case "$1" in
    --tsv)
      FORMAT="tsv"
      shift
      ;;
    --json)
      FORMAT="json"
      shift
      ;;
    --apply)
      APPLY=1
      shift
      ;;
    --no-fetch)
      FETCH=0
      shift
      ;;
    *)
      echo "unknown arg: $1" >&2
      exit 2
      ;;
  esac
done

load_portfolio_config "$PORTFOLIO_ARG"

: "${PORTFOLIO_SESSION_GIT_TIMEOUT_SEC:=20}"

run_timeout() {
  local seconds=$1
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$seconds" "$@"
  else
    "$@"
  fi
}

git_value() {
  local repo=$1
  shift
  run_timeout "$PORTFOLIO_SESSION_GIT_TIMEOUT_SEC" git -C "$repo" "$@" 2>/dev/null || true
}

git_quiet() {
  local repo=$1
  shift
  run_timeout "$PORTFOLIO_SESSION_GIT_TIMEOUT_SEC" git -C "$repo" "$@" >/dev/null 2>&1
}

dry_note() {
  if dry_run_enabled; then
    printf 'DRY-RUN: %s\n' "$*" >&2
  fi
}

project_inventory_json() {
  local alias=${1:?usage: project_inventory_json <alias> <config>}
  local cfg=${2:?usage: project_inventory_json <alias> <config>}
  bash -c '
    set -euo pipefail
    alias=$1
    cfg=$2
    tk=$3
    # shellcheck disable=SC1090
    source "$cfg"
    # shellcheck source=lib/agent_inventory.sh
    source "$tk/lib/agent_inventory.sh"
    default_branch=${DEFAULT_BRANCH:-main}
    gh_repo=${GH_REPO:-}
    gh_config_dir=${GH_CONFIG_DIR:-}
    clone_url=${GIT_REMOTE_URL:-${REPO_URL:-}}
    if [[ -z "$clone_url" && -n "$gh_repo" ]]; then
      clone_url="https://github.com/${gh_repo}.git"
    fi
    while IFS="|" read -r label pane workdir; do
      [[ -n "$label$pane$workdir" ]] || continue
      jq -nc \
        --arg alias "$alias" \
        --arg project "${PROJECT:-$alias}" \
        --arg label "$label" \
        --arg pane "$pane" \
        --arg workdir "$workdir" \
        --arg default_branch "$default_branch" \
        --arg gh_repo "$gh_repo" \
        --arg gh_config_dir "$gh_config_dir" \
        --arg clone_url "$clone_url" \
        --arg config "$cfg" \
        "{
          alias:\$alias,
          project:\$project,
          label:\$label,
          pane:\$pane,
          workdir:\$workdir,
          default_branch:\$default_branch,
          gh_repo:\$gh_repo,
          gh_config_dir:\$gh_config_dir,
          clone_url:\$clone_url,
          config:\$config
        }"
    done < <(agent_inventory_entries)
  ' _ "$alias" "$cfg" "$TK"
}

clone_missing_workdir() {
  local gh_repo=$1 gh_config_dir=$2 clone_url=$3 workdir=$4
  mkdir -p "$(dirname "$workdir")"
  if dry_run_enabled; then
    if [[ -n "$gh_repo" && "$clone_url" == https://github.com/* && -n "$(command -v gh 2>/dev/null || true)" ]]; then
      dry_note "gh repo clone $gh_repo $workdir"
    else
      dry_note "git clone $clone_url $workdir"
    fi
    return 0
  fi
  if [[ -n "$gh_repo" && "$clone_url" == https://github.com/* && -n "$(command -v gh 2>/dev/null || true)" ]]; then
    GH_CONFIG_DIR="$gh_config_dir" gh repo clone "$gh_repo" "$workdir" >/dev/null
  else
    git clone --quiet "$clone_url" "$workdir"
  fi
}

pull_default_ff() {
  local workdir=$1 default_branch=$2
  if dry_run_enabled; then
    dry_note "git -C $workdir pull --ff-only origin $default_branch"
    return 0
  fi
  run_timeout "$PORTFOLIO_SESSION_GIT_TIMEOUT_SEC" \
    git -C "$workdir" pull --ff-only origin "$default_branch" >/dev/null 2>&1
}

inspect_entry() {
  local entry=$1
  local alias project label pane workdir default_branch gh_repo gh_config_dir clone_url
  local exists=0 git_repo=0 branch="" head="" dirty="" fetch_status="" ahead="" behind=""
  local remote_default=0 base_current="" status="" remediation="" applied="" ready=0
  local counts

  alias=$(printf '%s' "$entry" | jq -r '.alias')
  project=$(printf '%s' "$entry" | jq -r '.project')
  label=$(printf '%s' "$entry" | jq -r '.label')
  pane=$(printf '%s' "$entry" | jq -r '.pane')
  workdir=$(printf '%s' "$entry" | jq -r '.workdir')
  default_branch=$(printf '%s' "$entry" | jq -r '.default_branch')
  gh_repo=$(printf '%s' "$entry" | jq -r '.gh_repo')
  gh_config_dir=$(printf '%s' "$entry" | jq -r '.gh_config_dir')
  clone_url=$(printf '%s' "$entry" | jq -r '.clone_url')

  if [[ ! -e "$workdir" ]]; then
    status="missing_clone"
    remediation="Clone the repository into the configured workdir."
    if [[ "$APPLY" -eq 1 && -n "$clone_url" ]]; then
      if clone_missing_workdir "$gh_repo" "$gh_config_dir" "$clone_url" "$workdir"; then
        applied="clone"
      else
        status="clone_failed"
        remediation="Retry clone manually and verify repository access."
      fi
    fi
  fi

  if [[ -e "$workdir" ]]; then
    exists=1
  fi
  if [[ -d "$workdir/.git" ]]; then
    git_repo=1
  elif [[ -z "$status" ]]; then
    status="not_git_repo"
    remediation="Move or clean the path, then clone the expected repository there."
  fi

  if [[ "$git_repo" -eq 1 ]]; then
    branch=$(git_value "$workdir" branch --show-current)
    head=$(git_value "$workdir" rev-parse --short HEAD)
    dirty=$(git_value "$workdir" status --porcelain | wc -l | tr -d ' ')

    if [[ "$FETCH" -eq 1 ]]; then
      if git_quiet "$workdir" fetch origin "$default_branch"; then
        fetch_status="ok"
      else
        fetch_status="failed"
      fi
    else
      fetch_status="skipped"
    fi

    if git_quiet "$workdir" rev-parse --verify "origin/$default_branch"; then
      remote_default=1
      counts=$(git_value "$workdir" rev-list --left-right --count "HEAD...origin/$default_branch")
      ahead=${counts%%[[:space:]]*}
      behind=${counts##*[[:space:]]}
    fi

    if [[ "${dirty:-0}" != "0" ]]; then
      status="dirty_worktree"
      remediation="Review, commit, stash, or clean local changes before assigning work."
    elif [[ -z "$branch" ]]; then
      status="detached_head"
      remediation="Checkout the default branch or a tracked work branch explicitly."
    elif [[ "$branch" != "$default_branch" ]]; then
      if [[ "$remote_default" -eq 1 ]]; then
        if git_quiet "$workdir" merge-base --is-ancestor "origin/$default_branch" HEAD; then
          base_current=1
          status="local_work_branch"
          remediation="Ensure the branch has a PR or park it before switching products."
        else
          base_current=0
          status="branch_needs_rebase"
          remediation="Rebase the branch on origin/$default_branch before parking or dispatching."
        fi
      else
        status="missing_origin_default"
        remediation="Fetch or configure origin/$default_branch before assessing this clone."
      fi
    elif [[ "$remote_default" -ne 1 ]]; then
      status="missing_origin_default"
      remediation="Fetch or configure origin/$default_branch before assigning work."
    elif [[ "${ahead:-0}" != "0" && "${behind:-0}" != "0" ]]; then
      status="diverged_default"
      remediation="Reconcile local default branch with origin/$default_branch manually."
    elif [[ "${ahead:-0}" != "0" ]]; then
      status="ahead_default"
      remediation="Push or inspect local default-branch commits; do not overwrite them automatically."
    elif [[ "${behind:-0}" != "0" ]]; then
      status="behind_default"
      remediation="Fast-forward the clean default branch from origin/$default_branch."
    else
      status="ready"
      remediation=""
      ready=1
    fi

    if [[ "$APPLY" -eq 1 && "$status" == "behind_default" ]]; then
      if pull_default_ff "$workdir" "$default_branch"; then
        applied="${applied:+$applied,}pull-ff-only"
        head=$(git_value "$workdir" rev-parse --short HEAD)
        ahead=0
        behind=0
        status="ready"
        remediation=""
        ready=1
      else
        status="pull_failed"
        remediation="Run git pull --ff-only manually and inspect the failure."
      fi
    fi
  fi

  jq -nc \
    --arg alias "$alias" \
    --arg project "$project" \
    --arg label "$label" \
    --arg pane "$pane" \
    --arg workdir "$workdir" \
    --arg default_branch "$default_branch" \
    --arg gh_repo "$gh_repo" \
    --arg clone_url "$clone_url" \
    --arg branch "$branch" \
    --arg head "$head" \
    --arg fetch_status "$fetch_status" \
    --arg ahead "$ahead" \
    --arg behind "$behind" \
    --arg dirty "$dirty" \
    --arg base_current "$base_current" \
    --arg status "$status" \
    --arg remediation "$remediation" \
    --arg applied "$applied" \
    --argjson exists "$exists" \
    --argjson git_repo "$git_repo" \
    --argjson remote_default "$remote_default" \
    --argjson ready "$ready" \
    '{
      alias:$alias,
      project:$project,
      label:$label,
      pane:$pane,
      workdir:$workdir,
      default_branch:$default_branch,
      gh_repo:$gh_repo,
      clone_url:$clone_url,
      exists:$exists,
      git_repo:$git_repo,
      branch:$branch,
      head:$head,
      fetch:$fetch_status,
      remote_default:$remote_default,
      ahead:(if $ahead == "" then null else ($ahead | tonumber) end),
      behind:(if $behind == "" then null else ($behind | tonumber) end),
      dirty:(if $dirty == "" then null else ($dirty | tonumber) end),
      base_current:(if $base_current == "" then null else ($base_current | tonumber) end),
      status:$status,
      ready:$ready,
      remediation:$remediation,
      applied:(if $applied == "" then null else $applied end)
    }'
}

json_items=()
while IFS='|' read -r alias cfg; do
  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    json_items+=("$(inspect_entry "$entry")")
  done < <(project_inventory_json "$alias" "$cfg")
done < <(portfolio_project_entries)

json_report=$(printf '%s\n' "${json_items[@]}" | jq -s '.')

if ! dry_run_enabled; then
  state_dir=$(portfolio_state_dir)
  mkdir -p "$state_dir"
  printf '%s\n' "$json_report" > "$state_dir/session_start.json"
fi

if [[ "$FORMAT" == "json" ]]; then
  printf '%s\n' "$json_report"
else
  printf 'alias\tproject\tlabel\tworkdir\tstatus\tready\tbranch\tahead\tbehind\tdirty\tfetch\tapplied\tremediation\n'
  printf '%s\n' "$json_report" | jq -r '.[] | [
    .alias,
    .project,
    .label,
    .workdir,
    .status,
    .ready,
    .branch,
    (.ahead // ""),
    (.behind // ""),
    (.dirty // ""),
    .fetch,
    (.applied // ""),
    .remediation
  ] | @tsv'
fi
